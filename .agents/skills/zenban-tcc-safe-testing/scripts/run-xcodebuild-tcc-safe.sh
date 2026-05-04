#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run Zenban xcodebuild tests with TCC-safe app-hosted state.

Usage:
  ZENBAN_TCC_TEST_NAME=notification-duplicate \
    .agents/skills/zenban-tcc-safe-testing/scripts/run-xcodebuild-tcc-safe.sh \
      -project zenban.xcodeproj -scheme zenban ... test

Environment:
  ZENBAN_TCC_TEST_NAME   Optional cache directory name under ~/Library/Caches/Zenban.
  ZENBAN_TCC_CACHE_ROOT  Optional cache root. Defaults to ~/Library/Caches/Zenban.
USAGE
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
cache_root="${ZENBAN_TCC_CACHE_ROOT:-$HOME/Library/Caches/Zenban}"
test_name="${ZENBAN_TCC_TEST_NAME:-xcodebuild-$(date +%Y%m%d-%H%M%S)}"
safe_name="$(printf '%s' "$test_name" | tr -c 'A-Za-z0-9._-' '-')"
board_dir="$cache_root/$safe_name"

case "$board_dir" in
  "$HOME/Library/Caches/Zenban/"*) ;;
  *)
    echo "Refusing to use non-cache board dir: $board_dir" >&2
    echo "Set ZENBAN_TCC_CACHE_ROOT under ~/Library/Caches/Zenban." >&2
    exit 64
    ;;
esac

rm -rf "$board_dir"
mkdir -p "$board_dir"
defaults delete com.berkaycit.zenban NSOSPLastRootDirectory >/dev/null 2>&1 || true

export CMUX_UI_TEST_MODE=1
export CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY="$board_dir"

echo "CMUX_UI_TEST_MODE=$CMUX_UI_TEST_MODE"
echo "CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY=$CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY"

cd "$repo_root"
exec xcodebuild "$@"
