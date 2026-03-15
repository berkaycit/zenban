#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/zenban/Resources/SentryConfig.plist"

usage() {
  cat <<'EOF'
Usage: ./scripts/upload-sentry-dsyms.sh [path/to/zenban.app]

Environment:
  SENTRY_AUTH_TOKEN   Required. Sentry auth token used by sentry-cli.
  SENTRY_URL          Optional. Overrides the Sentry base URL if needed.

If no app path is provided, the script searches common local build output paths.
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$CONFIG_PATH"
}

resolve_app_path() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return
  fi

  local candidates=(
    "$ROOT_DIR/build/codex-derived/Build/Products/Release/zenban.app"
    "$ROOT_DIR/build/codex-derived/Build/Products/Debug/zenban.app"
    "$ROOT_DIR/build/Build/Products/Release/zenban.app"
    "$ROOT_DIR/build/Build/Products/Debug/zenban.app"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "Could not locate zenban.app. Pass the app path explicitly." >&2
  exit 1
}

find_app_dsym() {
  local app_path="$1"
  local app_name
  app_name="$(basename "$app_path")"
  local sibling="$app_path.dSYM"
  if [[ -d "$sibling" ]]; then
    printf '%s\n' "$sibling"
    return
  fi

  local products_dir
  products_dir="$(cd "$(dirname "$app_path")" && pwd)"
  local nested="$products_dir/dSYMs/$app_name.dSYM"
  if [[ -d "$nested" ]]; then
    printf '%s\n' "$nested"
    return
  fi

  return 1
}

append_generated_dsym() {
  local binary_path="$1"
  local dsym_name="$2"

  [[ -x "$binary_path" ]] || return 1

  if [[ -z "${temp_dir:-}" ]]; then
    temp_dir="$(mktemp -d)"
  fi

  local generated_dsym="$temp_dir/$dsym_name"
  local dsymutil_log="$temp_dir/$dsym_name.log"
  dsymutil "$binary_path" -o "$generated_dsym" > /dev/null 2>"$dsymutil_log" || true
  if [[ -d "$generated_dsym" ]]; then
    upload_paths+=("$generated_dsym")
    rm -f "$dsymutil_log"
    return 0
  fi

  if [[ -s "$dsymutil_log" ]]; then
    cat "$dsymutil_log" >&2
  fi
  return 1
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ -f "$CONFIG_PATH" ]] || {
    echo "Missing config file: $CONFIG_PATH" >&2
    exit 1
  }
  [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] || {
    echo "SENTRY_AUTH_TOKEN is required." >&2
    exit 1
  }

  require_tool sentry-cli
  require_tool dsymutil

  local app_path
  if [[ -n "${1:-}" ]]; then
    app_path="$(resolve_app_path "$1")"
  else
    app_path="$(resolve_app_path)"
  fi
  [[ -d "$app_path" ]] || {
    echo "App not found: $app_path" >&2
    exit 1
  }

  local org_slug project_slug
  org_slug="$(plist_value organizationSlug)"
  project_slug="$(plist_value projectSlug)"

  local -a upload_paths=()
  local temp_dir=""
  local found_app_symbols=0
  if app_dsym="$(find_app_dsym "$app_path")"; then
    upload_paths+=("$app_dsym")
    found_app_symbols=1
  fi

  local app_debug_dylib="$app_path/Contents/MacOS/zenban.debug.dylib"
  if append_generated_dsym "$app_debug_dylib" "zenban.debug.dylib.dSYM"; then
    found_app_symbols=1
  fi

  if [[ $found_app_symbols -eq 0 ]]; then
    echo "Warning: app debug symbols not found for $app_path" >&2
  fi

  local cli_binary="$app_path/Contents/Resources/bin/cmux"
  append_generated_dsym "$cli_binary" "cmux.dSYM" || true

  if [[ ${#upload_paths[@]} -eq 0 ]]; then
    echo "No debug files found to upload." >&2
    [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
    exit 1
  fi

  sentry-cli debug-files upload \
    --org "$org_slug" \
    --project "$project_slug" \
    "${upload_paths[@]}"

  [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
}

main "$@"
