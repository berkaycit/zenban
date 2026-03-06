# vim:ft=zsh
#
# zenban zsh shell integration.
# Loaded by .zshenv after ghostty integration.
# Currently minimal - sets ZENBAN_TERMINAL for hook detection.

[[ -n "${ZENBAN_TERMINAL:-}" ]] || return 0
