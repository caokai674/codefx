#!/bin/sh
# Codefx bootstrap. The public command remains `codex`.
# Rust updater contract: CODEX_INSTALL_IF_LATEST CODEX_INSTALL_IF_CURRENT
# CODEX_INSTALL_DAEMON_ONLY CODEX_INSTALL_DEFER_SELECTION are forwarded unchanged.
set -eu
CODEFX_GITHUB_REPO="${CODEFX_GITHUB_REPO:-hitmux/codefx}"
CODEFX_INSTALL_REF="${CODEFX_INSTALL_REF:-main}"
case "$CODEFX_GITHUB_REPO" in
  *[!A-Za-z0-9_./-]*|*/*/*|/*|*/|''|*[.][.]*) echo 'Invalid CODEFX_GITHUB_REPO.' >&2; exit 2 ;;
  */*) ;;
  *) echo 'Expected CODEFX_GITHUB_REPO=owner/name.' >&2; exit 2 ;;
esac
case "$CODEFX_INSTALL_REF" in ''|*[!A-Za-z0-9_./-]*|*[.][.]*|/*) echo 'Invalid CODEFX_INSTALL_REF.' >&2; exit 2 ;; esac
fetch() (
  url=$1; output=$2
  case "$url" in https://*) ;; *) echo 'Installer downloads require HTTPS.' >&2; exit 2 ;; esac
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$output.part"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -t 3 -T 120 -O "$output.part" "$url"
  else
    echo 'curl or wget is required to install Codefx.' >&2; exit 1
  fi
  mv "$output.part" "$output"
)
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codefx-install.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "${CODEFX_INSTALLER_URL:-}" ]; then
  installer_url=$CODEFX_INSTALLER_URL
else
  # Resolve moving refs once; every fetched installer byte uses this commit.
  case "$CODEFX_INSTALL_REF" in
    *[!0-9a-f]*|'') installer_sha='' ;;
    *) installer_sha=$CODEFX_INSTALL_REF ;;
  esac
  if [ "${#installer_sha}" -ne 40 ]; then
    fetch "https://api.github.com/repos/$CODEFX_GITHUB_REPO/commits/$CODEFX_INSTALL_REF" "$tmp_dir/commit.json"
    installer_sha=$(tr '{},' '\n' < "$tmp_dir/commit.json" | sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' | head -n 1)
  fi
  [ "${#installer_sha}" -eq 40 ] || { echo 'Cannot resolve installer commit.' >&2; exit 1; }
  installer_url="https://raw.githubusercontent.com/$CODEFX_GITHUB_REPO/$installer_sha/scripts/install/install.sh"
fi
fetch "$installer_url" "$tmp_dir/install.sh"
export CODEFX_GITHUB_REPO
export CODEX_NON_INTERACTIVE="${CODEX_NON_INTERACTIVE:-1}"
export CODEX_INSTALLER_USE_RELEASES_OPENAI_COM="${CODEX_INSTALLER_USE_RELEASES_OPENAI_COM:-false}"
sh "$tmp_dir/install.sh" "$@"
