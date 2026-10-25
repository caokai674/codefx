#!/bin/sh

set -eu

RELEASE="${CODEX_RELEASE:-latest}"
NON_INTERACTIVE="${CODEX_NON_INTERACTIVE:-false}"
DAEMON_ONLY="${CODEX_INSTALL_DAEMON_ONLY:-0}"
CODEFX_GITHUB_REPO="${CODEFX_GITHUB_REPO:-hitmux/codefx}"
CODEFX_REPLACE_OFFICIAL="${CODEFX_REPLACE_OFFICIAL:-0}"
DEFAULT_PREFER_RELEASES_OPENAI_COM="false"
PREFER_RELEASES_OPENAI_COM="${CODEX_INSTALLER_USE_RELEASES_OPENAI_COM:-$DEFAULT_PREFER_RELEASES_OPENAI_COM}"
RELEASES_BASE_URL="https://releases.openai.com/codex"
RELEASES_CONNECT_TIMEOUT=10
RELEASES_METADATA_TIMEOUT=30
RELEASES_ASSET_TIMEOUT=300
release_source="github"

BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/codex"
CODE_MODE_HOST_BIN_PATH="$BIN_DIR/codex-code-mode-host"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"
if [ "$DAEMON_ONLY" = "1" ]; then
  STANDALONE_ROOT="$CODEX_HOME_DIR/packages/app-server-daemon"
fi
RELEASES_DIR="$STANDALONE_ROOT/releases"
CURRENT_LINK="$STANDALONE_ROOT/current"
if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" = "1" ]; then
  if [ "$DAEMON_ONLY" != "1" ]; then
    echo "Deferred selection requires a daemon-only installation." >&2
    exit 1
  fi
  CURRENT_LINK="$STANDALONE_ROOT/.migration-current"
fi
AUTO_UPDATE_VERSION="$STANDALONE_ROOT/auto-update-version"
LOCK_FILE="$STANDALONE_ROOT/install.lock"
LOCK_DIR="$STANDALONE_ROOT/install.lock.d"
LOCK_STALE_AFTER_SECS=600

path_action="already"
path_profile=""
conflict_manager=""
conflict_path=""
lock_kind=""
tmp_dir=""
CF_STOP_RUNNING="${CODEFX_STOP_RUNNING:-0}"
CF_DRY_RUN=0
CF_DAEMON_POLICY="${CODEFX_DAEMON_POLICY:-auto}"
CF_TIMEOUT="${CODEFX_PROCESS_TIMEOUT:-30}"
cf_prepared=0
cf_tx=""
cf_committed=0

step() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

normalize_version() {
  case "$1" in
    "" | latest)
      printf 'latest\n'
      ;;
    rust-v*)
      printf '%s\n' "${1#rust-v}"
      ;;
    v*)
      printf '%s\n' "${1#v}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

validate_version() {
  version="$1"

  if [ "$version" = "latest" ]; then
    return
  fi

  if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-alpha(\.[0-9]+){0,2}|-beta(\.[0-9]+)?)?$'; then
    echo "Invalid Codefx release version: $version. Expected latest or x.y.z[-alpha[.N[.M]]|-beta[.N]]." >&2
    return 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stop-running) CF_STOP_RUNNING=1 ;;
      --dry-run) CF_DRY_RUN=1 ;;
      --keep-daemon) CF_DAEMON_POLICY=keep ;;
      --release)
        if [ "$#" -lt 2 ]; then
          echo "--release requires a value." >&2
          exit 1
        fi
        RELEASE="$2"
        shift
        ;;
      --help | -h)
        cat <<EOF
Usage: install.sh [--release VERSION] [--dry-run] [--stop-running] [--keep-daemon]

Default: keep package-manager registrations; refuse active Codex sessions.
--stop-running  Request normal exit (SIGTERM); never force-kill sessions.
--keep-daemon   Leave the independent daemon package and runtime unchanged.
--dry-run       Resolve assets and list commands without changing the installation.
CODEFX_PROCESS_TIMEOUT bounds process operations (1..300 seconds, default 30).

Environment:
  CODEX_RELEASE          Version to install; overridden by --release.
  CODEX_NON_INTERACTIVE  Set to 1, true, or yes to skip prompts.
  CODEX_INSTALLER_USE_RELEASES_OPENAI_COM
                         Set to 0, false, or no to use GitHub Releases.
EOF
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

download_file() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    case "$url" in
      "$RELEASES_BASE_URL"/*)
        curl -fsSL --connect-timeout "$RELEASES_CONNECT_TIMEOUT" --max-time "$RELEASES_ASSET_TIMEOUT" "$url" -o "$output"
        ;;
      *)
        curl -fsSL --retry 3 --connect-timeout 10 --max-time "$RELEASES_ASSET_TIMEOUT" "$url" -o "$output"
        ;;
    esac
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    case "$url" in
      "$RELEASES_BASE_URL"/*)
        wget -q -t 1 -T "$RELEASES_ASSET_TIMEOUT" -O "$output" "$url"
        ;;
      *)
        wget -q -t 3 -T "$RELEASES_ASSET_TIMEOUT" -O "$output" "$url"
        ;;
    esac
    return
  fi

  echo "curl or wget is required to install Codex." >&2
  exit 1
}

download_text() {
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    case "$url" in
      "$RELEASES_BASE_URL"/*)
        curl -fsSL --connect-timeout "$RELEASES_CONNECT_TIMEOUT" --max-time "$RELEASES_METADATA_TIMEOUT" "$url"
        ;;
      *)
        curl -fsSL --retry 3 --connect-timeout 10 --max-time "$RELEASES_METADATA_TIMEOUT" "$url"
        ;;
    esac
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    case "$url" in
      "$RELEASES_BASE_URL"/*)
        wget -q -t 1 -T "$RELEASES_METADATA_TIMEOUT" -O - "$url"
        ;;
      *)
        wget -q -t 3 -T "$RELEASES_METADATA_TIMEOUT" -O - "$url"
        ;;
    esac
    return
  fi

  echo "curl or wget is required to install Codex." >&2
  exit 1
}

download_file_with_fallback() {
  primary_url="$1"
  fallback_url="$2"
  output="$3"
  expected_digest="$4"
  fallback_asset="$5"
  required_manifest_asset="${6:-}"

  if download_file "$primary_url" "$output" &&
    verify_archive_digest "$output" "$expected_digest" &&
    { [ -z "$required_manifest_asset" ] || package_archive_digest "$required_manifest_asset" "$output" >/dev/null; }; then
    return
  fi

  if [ -z "$fallback_url" ]; then
    return 1
  fi

  warn "Could not download or verify $primary_url; retrying from GitHub Releases."
  download_file "$fallback_url" "$output"
  if verify_archive_digest "$output" "$expected_digest" &&
    { [ -z "$required_manifest_asset" ] || package_archive_digest "$required_manifest_asset" "$output" >/dev/null; }; then
    return
  fi

  resolve_release_from_github "$resolved_version"
  fallback_digest="$(release_asset_digest "$fallback_asset")"
  verify_archive_digest "$output" "$fallback_digest"
  if [ -n "$required_manifest_asset" ]; then
    package_archive_digest "$required_manifest_asset" "$output" >/dev/null
  fi
}

parse_release_metadata() {
  # Bound awk's record size so compact, single-line JSON stays fast on every
  # supported awk implementation. JSON strings cannot contain literal newlines,
  # so the record boundaries inserted by fold do not change the document.
  LC_ALL=C fold -b -w 4096 | LC_ALL=C awk '
    function finish_string(value) {
      if (object_depth == 1 &&
          (key == "tag_name" || key == "version" || key == "target" || key == "entrypoint")) {
        print key "\t" value
      } else if (object_depth == asset_object_depth) {
        if (key == "name") {
          asset_name = value
        } else if (key == "digest") {
          asset_digest = value
        }
      }

      expecting_value = 0
      key = ""
    }

    {
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)

        if (in_string) {
          if (escaped) {
            token = token "\\" char
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            in_string = 0
            if (string_is_value) {
              finish_string(token)
            } else {
              pending_key = token
            }
          } else {
            token = token char
          }
          continue
        }

        if (char == "\"") {
          in_string = 1
          token = ""
          escaped = 0
          string_is_value = expecting_value
        } else if (char == ":" && pending_key != "") {
          key = pending_key
          pending_key = ""
          expecting_value = 1
        } else if (char == "{") {
          object_depth++
          if (assets_array_depth != 0 &&
              array_depth == assets_array_depth &&
              asset_object_depth == 0) {
            asset_object_depth = object_depth
            asset_name = ""
            asset_digest = ""
          }
          expecting_value = 0
          key = ""
        } else if (char == "}") {
          if (object_depth == asset_object_depth) {
            if (asset_name != "" && asset_digest != "") {
              print "asset\t" asset_name "\t" asset_digest
            }
            asset_object_depth = 0
            asset_name = ""
            asset_digest = ""
          }
          object_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == "[") {
          array_depth++
          if (expecting_value && key == "assets" && object_depth == 1) {
            assets_array_depth = array_depth
          }
          expecting_value = 0
          key = ""
        } else if (char == "]") {
          if (array_depth == assets_array_depth) {
            assets_array_depth = 0
          }
          array_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == ",") {
          expecting_value = 0
          key = ""
          pending_key = ""
        }
      }
    }

    END {
      if (in_string || object_depth != 0 || array_depth != 0) {
        exit 1
      }
    }
  '
}

release_url_for_asset() {
  asset="$1"
  resolved_version="$2"

  printf 'https://github.com/%s/releases/download/rust-v%s/%s\n' "$CODEFX_GITHUB_REPO" "$resolved_version" "$asset"
}

releases_url_for_asset() {
  asset="$1"
  resolved_version="$2"

  printf '%s/releases/%s/%s\n' "$RELEASES_BASE_URL" "$resolved_version" "$asset"
}

release_metadata_url() {
  resolved_version="$1"

  printf 'https://api.github.com/repos/%s/releases/tags/rust-v%s\n' "$CODEFX_GITHUB_REPO" "$resolved_version"
}

parse_downloaded_release_metadata() {
  requested_release="$1"
  source_name="$2"
  if ! release_metadata="$(printf '%s\n' "$release_json" | parse_release_metadata)"; then
    echo "Could not parse $source_name release metadata for Codex $requested_release." >&2
    return 1
  fi
}

resolve_metadata_version() {
  release_tag="$(printf '%s\n' "$release_metadata" | awk -F '\t' '$1 == "tag_name" { print $2; exit }')"
  case "$release_tag" in
    rust-v*) metadata_version="${release_tag#rust-v}" ;;
    *) metadata_version="" ;;
  esac
  if [ -z "$metadata_version" ]; then
    echo "Failed to resolve the latest Codefx release version." >&2
    return 1
  fi
  validate_version "$metadata_version"
}

resolve_release_from_github() {
  normalized_version="$1"
  if [ "$normalized_version" = "latest" ]; then
    requested_release="latest"
    metadata_url="https://api.github.com/repos/$CODEFX_GITHUB_REPO/releases/latest"
  else
    resolved_version="$normalized_version"
    requested_release="$resolved_version"
    metadata_url="$(release_metadata_url "$resolved_version")"
  fi

  if ! release_json="$(download_text "$metadata_url")"; then
    echo "Could not fetch GitHub release metadata for Codex $requested_release. GitHub API may be unavailable or rate limited." >&2
    exit 1
  fi

  parse_downloaded_release_metadata "$requested_release" "GitHub"

  if [ "$normalized_version" = "latest" ]; then
    resolve_metadata_version
    resolved_version="$metadata_version"
  fi

  release_source="github"
}

resolve_release_from_releases() {
  normalized_version="$1"

  if [ "$normalized_version" = "latest" ]; then
    requested_release="latest"
    metadata_url="$RELEASES_BASE_URL/channels/latest"
  else
    requested_release="$normalized_version"
    metadata_url="$RELEASES_BASE_URL/releases/$normalized_version/release.json"
  fi

  if ! release_json="$(download_text "$metadata_url")"; then
    return 1
  fi

  if ! parse_downloaded_release_metadata "$requested_release" "releases.openai.com"; then
    return 1
  fi
  if ! resolve_metadata_version; then
    return 1
  fi
  if [ "$normalized_version" != "latest" ] && [ "$metadata_version" != "$normalized_version" ]; then
    echo "Release metadata version did not match requested Codex version $normalized_version." >&2
    return 1
  fi
  resolved_version="$metadata_version"
  release_source="releases.openai.com"
}

resolve_release() {
  normalized_version="$(normalize_version "$RELEASE")"
  validate_version "$normalized_version"

  case "$PREFER_RELEASES_OPENAI_COM" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
      if resolve_release_from_releases "$normalized_version" &&
        select_release_assets; then
        return
      fi
      warn "releases.openai.com is unavailable; falling back to GitHub Releases."
      ;;
  esac

  resolve_release_from_github "$normalized_version"
  select_release_assets
}

release_asset_digest_or_empty() {
  asset="$1"

  digest="$(printf '%s\n' "$release_metadata" | awk -F '\t' -v asset="$asset" '
    $1 == "asset" && $2 == asset {
      print $3
      exit
    }
  ')"

  case "$digest" in
    sha256:????????????????????????????????????????????????????????????????)
      digest="${digest#sha256:}"
      case "$digest" in
        *[!0-9a-fA-F]*) return 1 ;;
      esac
      printf '%s\n' "$digest"
      ;;
    *)
      return 1
      ;;
  esac
}

release_asset_exists() {
  asset="$1"

  release_asset_digest_or_empty "$asset" >/dev/null 2>&1
}

release_asset_digest() {
  asset="$1"

  digest="$(release_asset_digest_or_empty "$asset" || true)"
  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for release asset $asset." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

select_release_assets() {
  package_asset="codex-package-$vendor_target.tar.gz"
  checksum_asset="codex-package_SHA256SUMS"
  download_fallback_url=""
  checksum_fallback_url=""

  if release_asset_exists "$package_asset" &&
    release_asset_exists "$checksum_asset"; then
    install_layout="package"
    asset="$package_asset"
  elif release_asset_exists "codex-npm-$npm_tag-$resolved_version.tgz"; then
    install_layout="legacy-platform-npm"
    asset="codex-npm-$npm_tag-$resolved_version.tgz"
  else
    echo "Could not find Codex package or platform npm release assets for Codex $resolved_version." >&2
    return 1
  fi

  if [ "$release_source" = "releases.openai.com" ]; then
    download_url="$(releases_url_for_asset "$asset" "$resolved_version")"
    download_fallback_url="$(release_url_for_asset "$asset" "$resolved_version")"
    if [ "$install_layout" = "package" ]; then
      checksum_url="$(releases_url_for_asset "$checksum_asset" "$resolved_version")"
      checksum_fallback_url="$(release_url_for_asset "$checksum_asset" "$resolved_version")"
    fi
  else
    download_url="$(release_url_for_asset "$asset" "$resolved_version")"
    if [ "$install_layout" = "package" ]; then
      checksum_url="$(release_url_for_asset "$checksum_asset" "$resolved_version")"
    fi
  fi
}

package_archive_digest() {
  asset="$1"
  manifest_path="$2"

  digest="$(awk -v asset="$asset" '
    $2 == asset && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$manifest_path" 2>/dev/null || true)"

  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for $asset in codex-package_SHA256SUMS." >&2
    return 1
  fi

  printf '%s\n' "$digest"
}

file_sha256() {
  path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //'
    return
  fi

  echo "sha256sum, shasum, or openssl is required to verify the Codex download." >&2
  exit 1
}

verify_archive_digest() {
  archive_path="$1"
  expected_digest="$2"
  actual_digest="$(file_sha256 "$archive_path")"

  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "Downloaded Codex archive checksum did not match expected digest." >&2
    echo "expected: $expected_digest" >&2
    echo "actual:   $actual_digest" >&2
    return 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install Codex." >&2
    exit 1
  fi
}

pick_profile() {
  # Use the same shell-specific split Homebrew documents because there is no
  # universal startup file across macOS/Linux login and interactive shells.
  case "$os:${SHELL:-}" in
    darwin:*/zsh)
      printf '%s\n' "$HOME/.zprofile"
      ;;
    darwin:*/bash)
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    linux:*/zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    linux:*/bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

add_to_path() {
  path_action="already"
  path_profile=""

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      if [ -z "$conflict_manager" ]; then
        return
      fi
      ;;
  esac

  profile="$(cf_resolve_path "$(pick_profile)")"
  path_profile="$profile"
  begin_marker="# >>> Codex installer >>>"
  end_marker="# <<< Codex installer <<<"
  path_line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$profile" ] && grep -F "$begin_marker" "$profile" >/dev/null 2>&1; then
    if grep -F "$path_line" "$profile" >/dev/null 2>&1; then
      path_action="configured"
      return
    fi

    if grep -F "$end_marker" "$profile" >/dev/null 2>&1; then
      rewrite_path_block "$profile" "$begin_marker" "$end_marker" "$path_line"
      path_action="updated"
      return
    fi
  fi

  append_path_block "$profile" "$begin_marker" "$end_marker" "$path_line"
  path_action="added"
}

append_path_block() {
  profile="$1"
  begin_marker="$2"
  end_marker="$3"
  path_line="$4"

  {
    printf '\n%s\n' "$begin_marker"
    printf '%s\n' "$path_line"
    printf '%s\n' "$end_marker"
  } >>"$profile"
}

rewrite_path_block() {
  profile="$1"
  begin_marker="$2"
  end_marker="$3"
  path_line="$4"
  tmp_profile="$tmp_dir/profile.$$.tmp"

  awk -v begin="$begin_marker" -v end="$end_marker" -v line="$path_line" '
    BEGIN {
      in_block = 0
      replaced = 0
    }
    $0 == begin {
      if (!replaced) {
        print begin
        print line
        print end
        replaced = 1
      }
      in_block = 1
      next
    }
    in_block {
      if ($0 == end) {
        in_block = 0
      }
      next
    }
    {
      print
    }
    END {
      if (in_block != 0) {
        exit 1
      }
    }
  ' "$profile" >"$tmp_profile"
  mv "$tmp_profile" "$profile"
}

mkdir_lock_is_stale() {
  [ -d "$LOCK_DIR" ] || return 1

  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  started_at="$(cat "$LOCK_DIR/started_at" 2>/dev/null || true)"
  now="$(date +%s 2>/dev/null || printf '0')"

  case "$started_at" in
    ''|*[!0-9]*)
      started_at=0
      ;;
  esac

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  if [ "$started_at" -eq 0 ] || [ "$now" -eq 0 ]; then
    return 0
  fi

  [ $((now - started_at)) -ge "$LOCK_STALE_AFTER_SECS" ]
}

acquire_install_lock() {
  mkdir -p "$STANDALONE_ROOT"

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 120 9
    lock_kind="flock"
    return
  fi

  lock_deadline=$(( $(date +%s) + 120 ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if mkdir_lock_is_stale; then
      warn "Removing stale installer lock at $LOCK_DIR"
      rm -rf "$LOCK_DIR"
      continue
    fi
    [ "$(date +%s)" -lt "$lock_deadline" ] || { echo "Installer lock timed out." >&2; return 1; }
    sleep 1
  done

  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  date +%s >"$LOCK_DIR/started_at" 2>/dev/null || true
  lock_kind="mkdir"
}

release_install_lock() {
  if [ "$lock_kind" = "mkdir" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  elif [ "$lock_kind" = "flock" ] || [ "$lock_kind" = "lockf" ]; then
    exec 9>&- 2>/dev/null || true
  fi
  lock_kind=""
}

cleanup_stale_install_artifacts() {
  mkdir -p "$RELEASES_DIR" "$STANDALONE_ROOT"

  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -name '.staging.*' -exec rm -rf {} +
  find "$STANDALONE_ROOT" -mindepth 1 -maxdepth 1 -name '.current.*' -exec rm -f {} +

  if [ "$DAEMON_ONLY" != "1" ] && [ -d "$BIN_DIR" ]; then
    find "$BIN_DIR" -mindepth 1 -maxdepth 1 -name '.codex.*' -exec rm -f {} +
  fi
}

record_standalone_releases_in_use() {
  # /proc also catches old clients with no session records. On macOS lsof
  # checks every open file in the release, including running helper programs.
  if [ "$os" = "linux" ]; then
    [ -r /proc/self/mountinfo ] && [ -L /proc/self/exe ] || return 1
    # hidepid can omit other users' processes entirely; do not assume an
    # incomplete process listing proves an older release is unused.
    if grep -E '(^|[ ,])hidepid=[^0, ]' /proc/self/mountinfo >/dev/null; then
      return 1
    fi
    : > "$tmp_dir/in-use" || return 1
    for process in /proc/[0-9]*; do
      if executable="$(readlink "$process/exe" 2>/dev/null)"; then
        printf 'n%s\n' "$executable" >> "$tmp_dir/in-use" || return 1
      elif [ -d "$process" ]; then
        # Even same-user ssh-agent/systemd processes may deny exe inspection.
        # Only an unreadable Codex or bundled helper prevents safe pruning.
        process_name="$(cat "$process/comm" 2>/dev/null)" || {
          [ ! -d "$process" ] && continue
          return 1
        }
        # Linux truncates comm to 15 bytes, including the code-mode host.
        case "$process_name" in
          codex* | rg | bwrap)
            # A zombie has no files left open, even if its parent never reaps it.
            grep -Eq '^State:[[:space:]]*Z' "$process/status" 2>/dev/null && continue
            [ ! -d "$process" ] && continue
            return 1
            ;;
        esac
      fi
    done
  else
    # macOS lsof silently omits other users' processes, even with no errors.
    # ps can still report their executable names. As on Linux, decline to
    # prune when an uninspectable Codex or helper may be using a release.
    current_uid="$(id -u)" || return 1
    ps -axo uid=,comm= > "$tmp_dir/processes" || return 1
    [ -s "$tmp_dir/processes" ] || return 1
    while read -r process_uid process_name; do
      [ "$process_uid" = "$current_uid" ] && continue
      case "${process_name##*/}" in
        codex* | rg | bwrap) return 1 ;;
      esac
    done < "$tmp_dir/processes"
    if /usr/sbin/lsof -nP -F n +D "$releases" > "$tmp_dir/in-use" 2> "$tmp_dir/lsof-error"; then
      :
    else
      # lsof returns 1 for an empty result as well as for errors.
      [ ! -s "$tmp_dir/in-use" ] && [ ! -s "$tmp_dir/lsof-error" ] || return 1
    fi
    [ ! -s "$tmp_dir/lsof-error" ] || return 1
  fi
}

# Run under the install lock, after the visible command has been verified.
# Only retire ordinary, manifest-owned packages; never retry a retired tree.
prune_standalone_releases() (
  [ ! -L "$CODEX_HOME_DIR/packages" ] &&
    [ ! -L "$STANDALONE_ROOT" ] && [ ! -L "$RELEASES_DIR" ] || return 1
  releases="$(cd -P "$RELEASES_DIR" && pwd)" || return 1
  # Local process inspection cannot establish whether a network home is in
  # use on another host. df -l excludes remotely mounted filesystems.
  df -lP "$releases" > /dev/null 2> "$tmp_dir/df-error" || return 1
  [ ! -s "$tmp_dir/df-error" ] || return 1
  selected="$(cd -P "$CURRENT_LINK" && pwd)" || return 1
  history="$(cat "$STANDALONE_ROOT/selection-history")" || return 1
  previous="$(printf '%s\n' "$history" | sed -n '2p')"
  case "$previous" in
    */* | . | ..) return 1 ;;
  esac
  identity="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK" 2>/dev/null ||
    LC_ALL=C stat -f '%d %i %Fc' "$CURRENT_LINK")" || return 1
  [ "$selected" = "$releases/${selected##*/}" ] &&
    [ "$history" = "$(printf '%s\n%s\n%s' "${selected##*/}" "$previous" "$identity")" ] ||
    return 1
  record_standalone_releases_in_use || return 1
  restore_candidate=""
  # A stopped install must not strand a late-starting release in retirement.
  trap 'if [ -n "$restore_candidate" ] && [ -d "$retired/release" ] &&
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    mv "$retired/release" "$candidate" && rmdir "$retired"
  fi' EXIT
  trap 'exit 1' HUP INT TERM

  for candidate in "$releases"/*; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] &&
      [ "$candidate" != "$selected" ] && [ "${candidate##*/}" != "$previous" ] || continue
    grep -F "n$candidate/" "$tmp_dir/in-use" >/dev/null && continue
    [ -f "$candidate/codex-package.json" ] && [ ! -L "$candidate/codex-package.json" ] || continue
    metadata="$(parse_release_metadata < "$candidate/codex-package.json")" || continue
    version="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "version" {print $2}')"
    target="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "target" {print $2}')"
    entrypoint="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "entrypoint" {print $2}')"
    [ "${candidate##*/}" = "$version-$target" ] && [ "$version" != "latest" ] &&
      [ "$entrypoint" = "bin/codex" ] && [ -f "$candidate/bin/codex" ] || continue
    validate_version "$version" >/dev/null 2>&1 || continue
    case "$target" in
      aarch64-apple-darwin | x86_64-apple-darwin | aarch64-unknown-linux-musl | x86_64-unknown-linux-musl) ;;
      *) continue ;;
    esac

    # Reject symlinks (except the installer's own alias), special files and
    # mounts before rm -r. find -xdev alone would not protect nested mounts.
    [ "$(readlink "$candidate/codex" 2>/dev/null)" = "bin/codex" ] || continue
    if ! find "$candidate" -xdev ! -type f ! -type d ! -path "$candidate/codex" -print > "$tmp_dir/unowned"; then
      continue
    fi
    [ ! -s "$tmp_dir/unowned" ] || continue
    if [ "$os" = "linux" ]; then
      # mountinfo escapes spaces, tabs, newlines, and backslashes in paths.
      if ! CODEX_PRUNE_RELEASE="$candidate" LC_ALL=C awk '
        BEGIN { release = ENVIRON["CODEX_PRUNE_RELEASE"] }
        { path = $5; gsub(/\\040/, " ", path); gsub(/\\011/, "\t", path)
          gsub(/\\012/, "\n", path); gsub(/\\134/, "\\", path)
          if (path == release || index(path, release "/") == 1) found = 1 }
        END { exit found ? 1 : 0 }
      ' /proc/self/mountinfo; then
        continue
      fi
    else
      device="$(stat -f '%d' "$releases")" || return 1
      if ! find "$candidate" -xdev -exec stat -f '%d' {} + > "$tmp_dir/devices"; then
        continue
      fi
      grep -vxF "$device" "$tmp_dir/devices" >/dev/null && continue
    fi

    retired="$(mktemp -d "$releases/.retired.XXXXXXXX")" || return 1
    restore_candidate=1
    if mv "$candidate" "$retired/release"; then
      # Block new launches at the original path before the final use check.
      # Some systems report the old executable path, so check both names.
      if ! record_standalone_releases_in_use ||
        grep -F -e "n$candidate/" -e "n$retired/release/" "$tmp_dir/in-use" >/dev/null; then
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
        mv "$retired/release" "$candidate" && rmdir "$retired" || return 1
        restore_candidate=""
        continue
      fi
      # Once proved unused, never restore a possibly partially deleted tree.
      restore_candidate=""
      find "$retired" -xdev -depth -delete || return 1
    else
      restore_candidate=""
      rmdir "$retired"
      return 1
    fi
  done
)

replace_path_with_symlink() {
  link_path="$1"
  link_target="$2"
  tmp_link="$3"

  rm -f "$tmp_link"
  ln -s "$link_target" "$tmp_link"

  if mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  if mv -hf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  rm -f "$link_path"
  mv -f "$tmp_link" "$link_path"
}

version_from_binary() {
  codex_path="$1"

  if [ ! -x "$codex_path" ]; then
    return 1
  fi

  version_output="$(cf_run "$codex_path" --version 2>/dev/null)" || return 1
  printf '%s\n' "$version_output" | sed -n 's/^codefx \([0-9][0-9A-Za-z.+-]*\)$/\1/p' | head -n 1
}

current_installed_version() {
  version="$(version_from_binary "$CURRENT_LINK/bin/codex" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  version="$(version_from_binary "$CURRENT_LINK/codex" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  return 0
}

resolve_existing_codex() {
  command -v codex 2>/dev/null || true
}

classify_existing_codex() {
  existing_path="$1"

  if [ -z "$existing_path" ] || [ "$existing_path" = "$BIN_PATH" ]; then
    return 1
  fi

  if [ -f "$existing_path" ] && grep -F "#!/usr/bin/env node" "$existing_path" >/dev/null 2>&1; then
    case "$existing_path" in
      *".bun"*)
        printf 'bun\n'
        ;;
      *)
        printf 'npm\n'
        ;;
    esac
    return 0
  fi

  return 1
}

prompt_yes_no() {
  prompt="$1"

  case "$NON_INTERACTIVE" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
      return 1
      ;;
  esac

  if ( : </dev/tty ) 2>/dev/null; then
    printf '%s [y/N] ' "$prompt" >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
      return 1
    fi
  elif [ -t 0 ]; then
    printf '%s [y/N] ' "$prompt"
    if ! IFS= read -r answer; then
      return 1
    fi
  else
    return 1
  fi

  case "$answer" in
    y | Y | yes | YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_launch_instructions() {
  case "$path_action" in
    added)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && codex"
      step "Future terminals: open a new terminal and run: codex"
      step "PATH was added to $path_profile"
      ;;
    updated)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && codex"
      step "Future terminals: open a new terminal and run: codex"
      step "PATH was updated in $path_profile"
      ;;
    configured)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && codex"
      step "Future terminals: open a new terminal and run: codex"
      step "PATH is already configured in $path_profile"
      ;;
    *)
      step "Current terminal: codex"
      step "Future terminals: open a new terminal and run: codex"
      ;;
  esac
}

maybe_launch_codex_now() {
  if prompt_yes_no "Start Codex now?"; then
    step "Launching Codex"
    "$BIN_PATH"
  fi
}

detect_conflicting_install() {
  existing_path="$(resolve_existing_codex)"
  manager="$(classify_existing_codex "$existing_path" || true)"

  if [ -z "$manager" ] && [ -n "$existing_path" ] && [ "$existing_path" != "$BIN_PATH" ]; then manager=native; fi

  conflict_manager="$manager"
  conflict_path="$existing_path"
  [ -n "$manager" ] || return 0
  step "Detected existing $manager-managed Codex at $existing_path"
  warn "Multiple managed Codex installs can be ambiguous because PATH order decides which one runs."
}

handle_conflicting_install() {
  if [ -n "$conflict_path" ]; then
    step "Original package-manager installation retained at $conflict_path."
  fi
}

install_package_release() {
  release_dir="$1"
  archive_path="$2"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release"
  mkdir -p "$stage_release"
  cf_validate_archive "$archive_path"
  tar -xzf "$archive_path" -C "$stage_release"
  chmod 0755 \
    "$stage_release/bin/codex" \
    "$stage_release/bin/codex-code-mode-host" \
    "$stage_release/codex-path/rg"
  if [ -f "$stage_release/codex-resources/bwrap" ]; then
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi
  ln -sf "bin/codex" "$stage_release/codex"

  if ! release_contents_are_complete "$stage_release" "$resolved_version" "$vendor_target" "$install_layout"; then
    echo "Staged Codefx package failed executable or version validation; existing installation preserved." >&2
    return 1
  fi
  cf_prepare
  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    # Keep the previous bytes until the new directory has been committed.
    backup_release="$RELEASES_DIR/.backup.$(basename "$release_dir").$$"
    printf '%s\n' "$release_dir" > "$cf_tx/release.path"
    printf '%s\n' "$backup_release" > "$cf_tx/release.backup"
    mv "$release_dir" "$backup_release"
    if ! mv "$stage_release" "$release_dir"; then
      mv "$backup_release" "$release_dir"
      return 1
    fi
  else
    mv "$stage_release" "$release_dir"
  fi
}

install_legacy_platform_npm_release() {
  release_dir="$1"
  archive_path="$2"
  target="$3"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"
  extract_dir="$tmp_dir/extract"
  vendor_root="$extract_dir/package/vendor/$target"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release" "$extract_dir"
  mkdir -p "$stage_release/codex-resources" "$extract_dir"
  cf_validate_archive "$archive_path"
  tar -xzf "$archive_path" -C "$extract_dir"

  cp "$vendor_root/codex/codex" "$stage_release/codex"
  cp "$vendor_root/path/rg" "$stage_release/codex-resources/rg"
  chmod 0755 "$stage_release/codex" "$stage_release/codex-resources/rg"
  if [ -f "$vendor_root/codex-resources/bwrap" ]; then
    cp "$vendor_root/codex-resources/bwrap" "$stage_release/codex-resources/bwrap"
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi

  if ! release_contents_are_complete "$stage_release" "$resolved_version" "$vendor_target" "$install_layout"; then
    echo "Staged Codefx package failed executable or version validation; existing installation preserved." >&2
    return 1
  fi
  cf_prepare
  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    # Keep the previous bytes until the new directory has been committed.
    backup_release="$RELEASES_DIR/.backup.$(basename "$release_dir").$$"
    printf '%s\n' "$release_dir" > "$cf_tx/release.path"
    printf '%s\n' "$backup_release" > "$cf_tx/release.backup"
    mv "$release_dir" "$backup_release"
    if ! mv "$stage_release" "$release_dir"; then
      mv "$backup_release" "$release_dir"
      return 1
    fi
  else
    mv "$stage_release" "$release_dir"
  fi
}

release_dir_is_complete() {
  release_dir="$1"
  expected_version="$2"
  expected_target="$3"
  layout="$4"

  [ -d "$release_dir" ] &&
    [ "$(basename "$release_dir")" = "$expected_version-$expected_target" ] ||
    return 1

  release_contents_are_complete "$release_dir" "$expected_version" "$expected_target" "$layout"
}

release_contents_are_complete() (
  release_dir="$1"
  expected_version="$2"
  expected_target="$3"
  layout="$4"

  case "$layout" in
    package)
      cf_manifest=$(tr -d '\n\r' < "$release_dir/codex-package.json" 2>/dev/null) || return 1
      cf_meta_version=$(printf '%s' "$cf_manifest" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      cf_meta_target=$(printf '%s' "$cf_manifest" | sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      cf_meta_entry=$(printf '%s' "$cf_manifest" | sed -n 's/.*"entrypoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [ "$cf_meta_version" = "$expected_version" ] && [ "$cf_meta_target" = "$expected_target" ] &&
        [ "$cf_meta_entry" = bin/codex ] &&
      [ -f "$release_dir/codex-package.json" ] &&
        [ -x "$release_dir/bin/codex" ] &&
        [ -x "$release_dir/bin/codex-code-mode-host" ] &&
        [ -x "$release_dir/codex" ] &&
        [ -x "$release_dir/codex-path/rg" ] ||
        return 1
      ;;
    legacy-platform-npm)
      [ -x "$release_dir/codex" ] &&
        [ -x "$release_dir/codex-resources/rg" ] ||
        return 1
      ;;
    *)
      return 1
      ;;
  esac

  case "$layout:$expected_target" in
    package:*linux* | legacy-platform-npm:*linux*)
      [ -x "$release_dir/codex-resources/bwrap" ] || return 1
      ;;
  esac

  installed_version="$(version_from_binary "$release_dir/bin/codex" || version_from_binary "$release_dir/codex" || true)"
  [ "$installed_version" = "$expected_version" ]
)

update_current_link() {
  release_dir="$1"
  tmp_link="$STANDALONE_ROOT/.current.$$"

  replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$tmp_link"
}

release_codex_relative_path() {
  release_dir="$1"

  if [ -x "$release_dir/bin/codex" ]; then
    printf 'bin/codex\n'
  else
    printf 'codex\n'
  fi
}

update_visible_command() {
  release_dir="$1"
  mkdir -p "$BIN_DIR"
  tmp_link="$BIN_DIR/.codex.$$"
  codex_relative_path="$(release_codex_relative_path "$release_dir")"

  replace_path_with_symlink "$BIN_PATH" "$CURRENT_LINK/$codex_relative_path" "$tmp_link"

  if [ "$os" = "darwin" ] && [ -x "$release_dir/bin/codex-code-mode-host" ]; then
    replace_path_with_symlink \
      "$CODE_MODE_HOST_BIN_PATH" \
      "$CURRENT_LINK/bin/codex-code-mode-host" \
      "$tmp_link"
  elif [ "$(readlink "$CODE_MODE_HOST_BIN_PATH" 2>/dev/null || true)" = \
    "$CURRENT_LINK/bin/codex-code-mode-host" ]; then
    rm -f "$CODE_MODE_HOST_BIN_PATH"
  fi
}

verify_visible_command() {
  [ "$(version_from_binary "$BIN_PATH")" = "$resolved_version" ]
  if [ "$os" = "darwin" ] && [ "$install_layout" = "package" ]; then
    [ -x "$CODE_MODE_HOST_BIN_PATH" ]
  fi
}

# Manual installers and guarded Rust updaters share the transaction machinery.
# Guarded updaters coordinate process lifetimes in Rust; never stop their parent.
cf_guarded() {
  [ "${CODEX_INSTALL_IF_LATEST:-0}" = 1 ] || [ "${CODEX_INSTALL_IF_CURRENT:-0}" = 1 ] ||
    [ "$DAEMON_ONLY" = 1 ] || [ "${old_updater_parent:-false}" = true ]
}

cf_run() (
  # Portable bounded execution; no dependency on GNU timeout on macOS.
  "$@" & cf_child=$!
  ( trap '[ -z "${cf_sleep:-}" ] || kill "$cf_sleep" 2>/dev/null; exit 0' TERM INT
    sleep "$CF_TIMEOUT" & cf_sleep=$!
    wait "$cf_sleep"; kill -TERM "$cf_child" 2>/dev/null || exit 0
    sleep 3 & cf_sleep=$!; wait "$cf_sleep"
    kill -KILL "$cf_child" 2>/dev/null || true
  ) & cf_watch=$!
  cf_result=0
  wait "$cf_child" || cf_result=$?
  kill "$cf_watch" 2>/dev/null || true
  wait "$cf_watch" 2>/dev/null || true
  exit "$cf_result"
)

cf_resolve_path() (
  cf_path=$1; cf_count=0
  while [ -L "$cf_path" ]; do
    cf_count=$((cf_count+1))
    [ "$cf_count" -le 40 ] || { echo 'Symbolic link loop in profile path.' >&2; return 1; }
    cf_target=$(readlink "$cf_path")
    case "$cf_target" in /*) cf_path=$cf_target ;; *) cf_path="$(dirname "$cf_path")/$cf_target" ;; esac
  done
  printf '%s\n' "$cf_path"
)

cf_inventory() (
  printf '==> Existing codex commands (all PATH entries):\n'
  cf_rest="$PATH:"
  while [ -n "$cf_rest" ]; do
    cf_part=${cf_rest%%:*}; cf_rest=${cf_rest#*:}
    [ -n "$cf_part" ] || cf_part=.
    [ -f "$cf_part/codex" ] || continue
    cf_resolved="$cf_part/codex"; cf_i=0
    while [ -L "$cf_resolved" ] && [ "$cf_i" -lt 40 ]; do
      cf_link=$(readlink "$cf_resolved")
      case "$cf_link" in /*) cf_resolved=$cf_link ;; *) cf_resolved="$(dirname "$cf_resolved")/$cf_link" ;; esac
      cf_i=$((cf_i+1))
    done
    cf_kind=native
    case "$cf_resolved" in
      *pnpm*|*\.pnpm/*) cf_kind=pnpm ;;
      *\.bun/*) cf_kind=bun ;;
      *\.vite-plus/*|*\.vp/*) cf_kind=vp ;;
      *node_modules/@openai/codex/*) cf_kind=npm ;;
      */Caskroom/codex/*|*/Cellar/codex/*) cf_kind=brew ;;
    esac
    printf '    %s [%s] -> %s\n' "$cf_part/codex" "$cf_kind" "$cf_resolved"
  done
)

cf_processes() (
  # ps failure is an error, rather than evidence that no process exists.
  ps -u "$(id -u)" -o pid= -o ppid= -o stat= -o comm= > "$tmp_dir/processes" || {
    echo 'Cannot inspect running processes; installation was stopped safely.' >&2; return 1;
  }
  awk '$3 !~ /^Z/ && $4 ~ /(^|\/)(codex|codefx)(\.exe)?$/ { print $1, $2, $4 }' "$tmp_dir/processes"
)

cf_prepare() {
  [ "$cf_prepared" = 0 ] || return 0
  cf_prepared=1
  if ! cf_guarded; then
    cf_processes > "$tmp_dir/active-codex" || return 1
    if [ -s "$tmp_dir/active-codex" ]; then
      cat "$tmp_dir/active-codex" >&2
      if [ "$CF_STOP_RUNNING" != 1 ]; then
        echo 'Codex is running. Close the listed sessions, or use --stop-running from an external terminal.' >&2
        return 1
      fi
      # An installer inside Codex must never terminate its own ancestor.
      cf_ancestor=$$
      while [ "$cf_ancestor" -gt 1 ]; do
        if awk -v p="$cf_ancestor" '$1 == p { found=1 } END { exit !found }' "$tmp_dir/active-codex"; then
          echo 'Run this installer from an external terminal: its ancestor is Codex.' >&2; return 1
        fi
        cf_parent=$(awk -v p="$cf_ancestor" '$1 == p { print $2; exit }' "$tmp_dir/processes")
        [ -n "$cf_parent" ] || break
        cf_ancestor=$cf_parent
      done
    fi
  fi
  cf_tx="$STANDALONE_ROOT/.transaction"
  mkdir -m 700 "$cf_tx"
  cf_snapshot "$CURRENT_LINK" current
  cf_snapshot "$AUTO_UPDATE_VERSION" channel
  cf_snapshot "$STANDALONE_ROOT/selection-history" history
  if [ "$DAEMON_ONLY" != 1 ]; then
    cf_snapshot "$BIN_PATH" visible
    cf_snapshot "$CODE_MODE_HOST_BIN_PATH" host
    cf_snapshot "$(cf_resolve_path "$(pick_profile)")" profile
  fi
  cf_snapshot "$CODEX_HOME_DIR/packages/app-server-daemon/current" daemon-current
  cf_snapshot "$CODEX_HOME_DIR/packages/app-server-daemon/auto-update-version" daemon-channel
  cf_snapshot "$CODEX_HOME_DIR/packages/app-server-daemon/selection-history" daemon-history
  cf_snapshot "$CODEX_HOME_DIR/app-server-daemon/settings.json" daemon-settings
  if ! cf_guarded; then
    cf_old_cli=$(resolve_existing_codex)
    if [ -n "$cf_old_cli" ] && [ "$CF_DAEMON_POLICY" != keep ] &&
      { [ -d "$CODEX_HOME_DIR/app-server-daemon" ] || [ -d "$CODEX_HOME_DIR/packages/app-server-daemon" ]; }; then
      # A failed version query alone does not distinguish an absent daemon.
      if cf_run "$cf_old_cli" app-server daemon version > "$cf_tx/daemon-version" 2>/dev/null &&
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' "$cf_tx/daemon-version"; then
        if [ "$CF_STOP_RUNNING" != 1 ]; then
          echo 'A managed app-server daemon is running; close it or use --stop-running.' >&2; return 1
        fi
        printf '%s\n' "$cf_old_cli" > "$cf_tx/restart-cli"
        cf_run "$cf_old_cli" app-server daemon stop > "$cf_tx/daemon-stop" 2>&1 || {
          cat "$cf_tx/daemon-stop" >&2; return 1;
        }
      fi
    fi
    if [ -s "$tmp_dir/active-codex" ]; then
      while read -r cf_pid cf_ppid cf_name; do
        # Recheck identity before signalling. Never escalate to SIGKILL.
        cf_now=$(ps -p "$cf_pid" -o ppid= -o comm= 2>/dev/null | awk '{$1=$1;print}')
        if [ "$cf_now" = "$cf_ppid $cf_name" ]; then kill -TERM "$cf_pid" 2>/dev/null || true; fi
      done < "$tmp_dir/active-codex"
      cf_deadline=$(( $(date +%s) + CF_TIMEOUT ))
      while :; do
        cf_processes > "$tmp_dir/remaining" || return 1
        [ -s "$tmp_dir/remaining" ] || break
        if [ "$(date +%s)" -ge "$cf_deadline" ]; then
          cat "$tmp_dir/remaining" >&2
          echo 'Timed out waiting for Codex to exit. Original installation will be restored.' >&2; return 1
        fi
        sleep 1
      done
    fi
  fi
}

cf_snapshot() (
  cf_path=$1; cf_key=$2
  if [ -L "$cf_path" ]; then
    readlink "$cf_path" > "$cf_tx/$cf_key.link"
  elif [ -f "$cf_path" ]; then
    cp -p "$cf_path" "$cf_tx/$cf_key.file"
  elif [ -e "$cf_path" ]; then
    echo "Refusing to overwrite a directory or special file: $cf_path" >&2; return 1
  fi
  printf '%s\n' "$cf_path" > "$cf_tx/$cf_key.path"
)

cf_restore() (
  cf_failed=0
  if [ -f "$cf_tx/migration-attempted" ] && [ -x "$BIN_PATH" ]; then
    cf_run "$BIN_PATH" app-server daemon stop > "$cf_tx/migration-stop" 2>&1 || {
      cat "$cf_tx/migration-stop" >&2; return 1;
    }
  fi
  # Restore the original package bytes before restoring links and runtime.
  if [ -f "$cf_tx/release.path" ] && [ -f "$cf_tx/release.backup" ]; then
    cf_original=$(cat "$cf_tx/release.path"); cf_saved=$(cat "$cf_tx/release.backup")
    if [ -d "$cf_saved" ]; then
      rm -rf "$cf_original" && mv "$cf_saved" "$cf_original" || cf_failed=1
    fi
  fi
  for cf_record in "$cf_tx"/*.path; do
    [ -f "$cf_record" ] || continue
    [ "${cf_record##*/}" != release.path ] || continue
    cf_key=${cf_record%.path}; cf_path=$(cat "$cf_record")
    if [ -d "$cf_path" ] && [ ! -L "$cf_path" ]; then
      warn "Rollback preserved unexpected directory $cf_path"; cf_failed=1; continue
    fi
    rm -f "$cf_path" || { cf_failed=1; continue; }
    if [ -f "$cf_key.link" ]; then
      ln -s "$(cat "$cf_key.link")" "$cf_path" || cf_failed=1
    elif [ -f "$cf_key.file" ]; then
      cp -p "$cf_key.file" "$cf_path" || cf_failed=1
    fi
  done
  if [ -f "$cf_tx/restart-cli" ]; then
    cf_restart=$(cat "$cf_tx/restart-cli")
    cf_run "$cf_restart" app-server daemon start > "$cf_tx/daemon-restore" 2>&1 || {
      cat "$cf_tx/daemon-restore" >&2; cf_failed=1;
    }
  fi
  [ "$cf_failed" = 0 ]
)

cf_migrate_daemon() {
  cf_guarded && return 0
  [ "$CF_DAEMON_POLICY" != keep ] || return 0
  if [ -f "$CODEX_HOME_DIR/app-server-daemon/settings.json" ] ||
    [ -e "$CODEX_HOME_DIR/packages/app-server-daemon/current" ] || [ -f "$cf_tx/restart-cli" ]; then
    : > "$cf_tx/migration-attempted"
    step 'Migrating the managed app-server daemon to the verified Codefx package'
    cf_run "$BIN_PATH" app-server daemon update --from-cli --yes || return 1
    if [ -f "$cf_tx/restart-cli" ]; then
      cf_run "$BIN_PATH" app-server daemon start || return 1
      cf_run "$BIN_PATH" app-server daemon version > "$cf_tx/daemon-health" || return 1
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' "$cf_tx/daemon-health" || return 1
      cf_daemon_version=$(tr -d '\n\r' < "$cf_tx/daemon-health" | sed -n 's/.*"appServerVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [ "$cf_daemon_version" = "$resolved_version" ] || { echo 'Daemon version health check failed.' >&2; return 1; }
    else
      # from-cli may start a runtime; preserve the original stopped state.
      cf_run "$BIN_PATH" app-server daemon stop || return 1
    fi
  fi
}

cf_validate_archive() (
  # tar listings are checked before extraction: no links, devices or traversal.
  tar -tzf "$1" > "$tmp_dir/archive-names" || return 1
  awk 'BEGIN { ok=1 } /^\// || /\\/ || /(^|\/)\.\.(\/|$)/ || /[[:cntrl:]]/ { ok=0 } END {exit !ok}' "$tmp_dir/archive-names" || {
    echo 'Unsafe archive member path.' >&2; return 1;
  }
  tar -tvzf "$1" > "$tmp_dir/archive-types" || return 1
  awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { bad=1 } END {exit bad}' "$tmp_dir/archive-types" || {
    echo 'Archive links and special files are not allowed.' >&2; return 1;
  }
)

cf_finish() {
  if [ -n "$cf_tx" ] && [ -d "$cf_tx" ]; then
    # Keep the previous entrypoints and profile available for manual recovery.
    rm -f "$cf_tx/migration-attempted" "$cf_tx/restart-cli"
    mv "$cf_tx" "$STANDALONE_ROOT/.rollback.$(date +%s).$$"
    cf_tx=""
  fi
  cf_committed=1
}

parse_args "$@"
case "$CF_TIMEOUT" in ''|*[!0-9]*) echo 'Invalid process timeout.' >&2; exit 2 ;; esac
[ "$CF_TIMEOUT" -ge 1 ] && [ "$CF_TIMEOUT" -le 300 ] || { echo 'Process timeout must be 1..300.' >&2; exit 2; }
case "$CF_DAEMON_POLICY" in auto|keep) ;; *) echo 'Invalid daemon policy.' >&2; exit 2 ;; esac
# Shell profile entries use double quotes; reject characters interpreted there.
case "$BIN_DIR" in /*) ;; *) echo 'CODEX_INSTALL_DIR must be absolute.' >&2; exit 2 ;; esac
case "$BIN_DIR" in *'"'*|*'$'*|*'`'*|*'\'*|*'
'*) echo 'Install path contains unsupported shell metacharacters.' >&2; exit 2 ;; esac


require_command mktemp
require_command tar

case "$(uname -s)" in
  Darwin)
    os="darwin"
    ;;
  Linux)
    os="linux"
    ;;
  *)
    echo "install.sh supports macOS and Linux. Use install.ps1 on Windows." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64)
    arch="x86_64"
    ;;
  arm64 | aarch64)
    arch="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x86_64" ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    arch="aarch64"
  fi
fi

if [ "$os" = "darwin" ]; then
  if [ "$arch" = "aarch64" ]; then
    npm_tag="darwin-arm64"
    vendor_target="aarch64-apple-darwin"
    platform_label="macOS (Apple Silicon)"
  else
    npm_tag="darwin-x64"
    vendor_target="x86_64-apple-darwin"
    platform_label="macOS (Intel)"
  fi
else
  if [ "$arch" = "aarch64" ]; then
    npm_tag="linux-arm64"
    vendor_target="aarch64-unknown-linux-musl"
    platform_label="Linux (ARM64)"
  else
    npm_tag="linux-x64"
    vendor_target="x86_64-unknown-linux-musl"
    platform_label="Linux (x64)"
  fi
fi

resolve_release
release_name="$resolved_version-$vendor_target"
release_dir="$RELEASES_DIR/$release_name"
current_version="$(current_installed_version)"

if [ -n "$current_version" ] && [ "$current_version" != "$resolved_version" ]; then
  step "Updating Codefx CLI from $current_version to $resolved_version"
elif [ -n "$current_version" ]; then
  step "Updating Codefx CLI"
else
  step "Installing Codefx CLI"
fi
step "Detected platform: $platform_label"
step "Resolved version: $resolved_version"

if [ "$DAEMON_ONLY" != "1" ]; then
  detect_conflicting_install
fi

cf_inventory
if [ "$CF_DRY_RUN" = 1 ]; then
  step "Dry run: verified release metadata contains $asset ($vendor_target)."
  step "Destination: $BIN_PATH; daemon policy: $CF_DAEMON_POLICY. No changes made."
  exit 0
fi
tmp_dir="$(mktemp -d)"
cleanup() {
  cf_exit=$?
  trap - EXIT INT TERM
  if [ "$cf_committed" = 0 ] && [ -n "$cf_tx" ] && [ -d "$cf_tx" ]; then
    warn 'Restoring the previous installation after an incomplete transaction.'
    if cf_restore; then rm -rf "$cf_tx"; else
      warn "Rollback needs attention; recovery files retained at $cf_tx"
      cf_exit=1
    fi
  fi
  release_install_lock
  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  exit "$cf_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_install_lock
if [ -d "$STANDALONE_ROOT/.transaction" ]; then
  cf_tx="$STANDALONE_ROOT/.transaction"
  warn 'Recovering an interrupted installation before proceeding.'
  cf_restore || exit 1
  rm -rf "$cf_tx"; cf_tx=""
fi
if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" = "1" ] &&
  { [ -e "$STANDALONE_ROOT/current" ] || [ -L "$STANDALONE_ROOT/current" ]; }; then
  echo "A dedicated daemon is already selected; retry the update." >&2
  exit 1
fi
updater_record="$CODEX_HOME_DIR/app-server-daemon/app-server-updater.pid"
if [ "$DAEMON_ONLY" = "1" ]; then
  updater_record="$CODEX_HOME_DIR/app-server-daemon/daemon-updater.pid"
fi
old_updater_parent="false"
if [ "${CODEX_INSTALL_IF_LATEST:-}" != "1" ] && [ "${CODEX_INSTALL_IF_CURRENT:-}" != "1" ] && [ -f "$updater_record" ]; then
  updater_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$updater_record" | head -n 1)"
  recorded_start="$(sed -n 's/.*"processStartTime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$updater_record" | head -n 1)"
  if [ -r "/proc/$$/stat" ]; then
    parent_pid="$(sed 's/^.*) //' "/proc/$$/stat" | awk '{ print $2 }')"
  else
    parent_pid="$(ps -p "$$" -o ppid= 2>/dev/null)" || parent_pid=""
    parent_pid="$(printf '%s' "$parent_pid" | tr -d ' ')"
  fi
  if [ -n "$updater_pid" ] && [ "$updater_pid" = "$parent_pid" ]; then
    actual_details="$(ps -p "$updater_pid" -o stat= -o lstart= 2>/dev/null)" || actual_details=""
    actual_start="$(printf '%s' "$actual_details" | sed 's/^[^[:space:]]*[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$recorded_start" ] && [ "$recorded_start" = "$actual_start" ]; then
      old_updater_parent="true"
    fi
  fi
  if [ "$RELEASE" = "latest" ] && [ -n "$updater_pid" ] &&
    { [ -z "$parent_pid" ] || { [ "$updater_pid" = "$parent_pid" ] &&
      { [ -z "$recorded_start" ] || [ -z "$actual_start" ]; }; }; } &&
    kill -0 "$updater_pid" 2>/dev/null; then
    warn "Cannot verify whether an older updater launched this installer; skipping latest update."
    exit 0
  fi
fi
if [ "${CODEX_INSTALL_IF_LATEST:-}" = "1" ] || [ "${CODEX_INSTALL_IF_CURRENT:-}" = "1" ] || [ "$old_updater_parent" = "true" ]; then
  guarded_release="${CODEX_UPDATE_FROM_RELEASE:-}"
  if [ "$old_updater_parent" = "true" ]; then
    guarded_release="$(cat "$AUTO_UPDATE_VERSION" 2>/dev/null || true)"
  fi
  current_release_dir="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || exit 0
  releases_dir="$(cd -P "$RELEASES_DIR" 2>/dev/null && pwd)" || exit 0
  if [ "$RELEASE" != "latest" ] || [ -z "$guarded_release" ] ||
    [ "$current_release_dir" != "$releases_dir/$guarded_release" ]; then
    if [ "${CODEX_INSTALL_IF_CURRENT:-}" = "1" ]; then
      echo "Daemon selection changed; retry the update." >&2
      exit 1
    fi
    exit 0
  fi
  # An explicit daemon update may leave a local or pinned release. Scheduled
  # updates still require the selected release to follow the latest channel.
  if [ "${CODEX_INSTALL_IF_CURRENT:-}" != "1" ] &&
    [ "$(cat "$AUTO_UPDATE_VERSION" 2>/dev/null || true)" != "$guarded_release" ]; then
    exit 0
  fi
fi
cleanup_stale_install_artifacts

if ! release_dir_is_complete "$release_dir" "$resolved_version" "$vendor_target" "$install_layout"; then
  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    if [ "$DAEMON_ONLY" = "1" ]; then
      echo "Refusing to overwrite existing daemon release $release_dir." >&2
      exit 1
    fi
    warn "Found incomplete existing release at $release_dir; reinstalling."
  fi

  archive_path="$tmp_dir/$asset"
  checksum_path="$tmp_dir/$checksum_asset"

  step "Downloading Codefx CLI"
  if [ "$install_layout" = "package" ]; then
    checksum_digest="$(release_asset_digest "$checksum_asset")"
    download_file_with_fallback "$checksum_url" "$checksum_fallback_url" "$checksum_path" "$checksum_digest" "$checksum_asset" "$asset"
    expected_digest="$(package_archive_digest "$asset" "$checksum_path")"
  else
    expected_digest="$(release_asset_digest "$asset")"
  fi
  download_file_with_fallback "$download_url" "$download_fallback_url" "$archive_path" "$expected_digest" "$asset"

  step "Installing standalone package to $release_dir"
  if [ "$install_layout" = "package" ]; then
    install_package_release "$release_dir" "$archive_path"
  else
    install_legacy_platform_npm_release "$release_dir" "$archive_path" "$vendor_target"
  fi
fi
if ! release_dir_is_complete "$release_dir" "$resolved_version" "$vendor_target" "$install_layout"; then
  echo "Installed Codex command did not report expected version $resolved_version." >&2
  exit 1
fi
cf_prepare
if [ "$DAEMON_ONLY" = "1" ] && [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" != "1" ]; then
  installed_codex="$release_dir/codex"
  if [ "$install_layout" = "package" ]; then
    installed_codex="$release_dir/bin/codex"
  fi
  if ! "$installed_codex" app-server daemon pid-update-loop --check-package-ownership >/dev/null 2>&1; then
    echo "The production release does not support daemon-owned packages; the current selection was left unchanged." >&2
    exit 1
  fi
fi
if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" != "1" ]; then
  # A no-op must not replace the selection link: history is bound to it.
  selected_dir="$(cd -P "$release_dir" && pwd)"
  previous_dir="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || previous_dir=""
  if [ "$previous_dir" != "$selected_dir" ]; then
    update_current_link "$release_dir"
    if ! (
      history="$STANDALONE_ROOT/selection-history"
      # GNU and BSD stat both inspect the link itself by default.
      selection_id="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK" 2>/dev/null ||
        LC_ALL=C stat -f '%d %i %Fc' "$CURRENT_LINK")"
      printf '%s\n%s\n%s\n' "$release_name" "${previous_dir##*/}" "$selection_id" > "$history.tmp.$$"
      mv -f "$history.tmp.$$" "$history"
    ); then
      warn "Could not record installation selection; pruning will be skipped."
    fi
  fi
else
  # Do not publish history for a migration until Rust has committed the cutover.
  update_current_link "$release_dir"
fi
if [ "$RELEASE" = "latest" ]; then
  printf '%s' "$release_name" > "$AUTO_UPDATE_VERSION.tmp.$$"
  mv -f "$AUTO_UPDATE_VERSION.tmp.$$" "$AUTO_UPDATE_VERSION"
else
  rm -f "$AUTO_UPDATE_VERSION"
fi
if [ "$DAEMON_ONLY" = "1" ]; then
  cf_finish
  release_install_lock
  exit 0
fi
update_visible_command "$release_dir"
add_to_path
verify_visible_command
cf_migrate_daemon
cf_finish
if ! prune_standalone_releases; then
  warn "Could not safely inspect old Codefx releases; skipped remaining cleanup."
fi
release_install_lock
handle_conflicting_install

case "$path_action" in
  added)
    print_launch_instructions
    ;;
  updated)
    print_launch_instructions
    ;;
  configured)
    print_launch_instructions
    ;;
  *)
    step "$BIN_DIR is already on PATH"
    print_launch_instructions
    ;;
esac

printf 'Codefx CLI %s installed successfully.\n' "$resolved_version"
maybe_launch_codex_now
