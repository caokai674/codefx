#!/bin/sh
# Replace an official Codex installation with Codefx. The command remains `codex`.
set -eu

CODEFX_GITHUB_REPO="${CODEFX_GITHUB_REPO:-hitmux/codefx}"
CODEFX_INSTALL_REF="${CODEFX_INSTALL_REF:-main}"
CODEFX_INSTALLER_URL="${CODEFX_INSTALLER_URL:-https://raw.githubusercontent.com/$CODEFX_GITHUB_REPO/$CODEFX_INSTALL_REF/scripts/install/install.sh}"

case "$CODEFX_GITHUB_REPO" in
  */*) ;;
  *) echo "Invalid CODEFX_GITHUB_REPO: $CODEFX_GITHUB_REPO" >&2; exit 2 ;;
esac

fetch() {
  url="$1"; output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
  else
    echo "curl or wget is required to install Codefx." >&2; exit 1
  fi
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codefx-install.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
installer="$tmp_dir/install.sh"
fetch "$CODEFX_INSTALLER_URL" "$installer"
chmod 0755 "$installer"

export CODEFX_GITHUB_REPO CODEFX_REPLACE_OFFICIAL=1
export CODEX_NON_INTERACTIVE="${CODEX_NON_INTERACTIVE:-1}"
export CODEX_INSTALLER_USE_RELEASES_OPENAI_COM="${CODEX_INSTALLER_USE_RELEASES_OPENAI_COM:-false}"
sh "$installer" "$@"
