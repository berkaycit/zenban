#!/bin/sh
set -eu

shell_path="${CMUX_ZELLIJ_SHELL:-${SHELL:-/bin/zsh}}"
shell_name="$(basename "$shell_path")"

case "$shell_name" in
  zsh|bash|sh)
    exec "$shell_path" -il
    ;;
  fish)
    exec "$shell_path" -li
    ;;
  *)
    exec "$shell_path"
    ;;
esac
