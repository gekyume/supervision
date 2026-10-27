#!/bin/zsh
# The only thing an iPhone Shortcut's SSH key is allowed to run (via `command=` in
# ~/.ssh/authorized_keys). It accepts exactly:
#   pause <minutes 1–120> [reason words…]
#   resume
#   status
# and nothing else. Every pause is logged as coming from the phone.
set -e
CTL=/usr/local/bin/supervisionctl
[ -x "$CTL" ] || CTL="$HOME/bin/supervisionctl"
read -r cmd arg rest <<< "${SSH_ORIGINAL_COMMAND:-status}"
case "$cmd" in
  pause)
    [[ "$arg" == <-> ]] && (( arg >= 1 && arg <= 120 )) || { echo "Pause needs a number of minutes from 1 to 120."; exit 1; }
    reason="from iPhone Shortcut${rest:+: $rest}"
    "$CTL" pause "$arg" "$reason" ;;
  resume) "$CTL" resume ;;
  status) "$CTL" status | head -2 ;;
  *) echo "Allowed: pause <minutes> [reason] · resume · status"; exit 1 ;;
esac
