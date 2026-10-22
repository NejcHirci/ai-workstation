#!/usr/bin/env bash
# Store the Cortecs API key as the Podman secret "cortecs_key". Counterpart of set-key.ps1.
#
#   set-key.sh            asks for the key (input is hidden)
#   set-key.sh --stdin    reads the key from standard input (for a password manager:
#                         pass show cortecs | bash scripts/set-key.sh --stdin)
set -euo pipefail

command -v podman >/dev/null 2>&1 || { echo 'ERROR: podman is not installed.' >&2; exit 1; }

key=''
if [[ "${1:-}" == --stdin ]]; then
    IFS= read -r key || true
else
    [[ -t 0 ]] || { echo 'ERROR: not a terminal. Use --stdin to pipe the key in.' >&2; exit 1; }
    read -rsp 'Cortecs API key for OpenCode: ' key
    echo
fi
key="${key//[[:space:]]/}"   # a trailing newline or space would end up inside the Authorization header
[[ -n "$key" ]] || { echo 'ERROR: empty key.' >&2; exit 1; }

# The key goes to Podman through a pipe: no temporary file on disk.
printf '%s' "$key" | podman secret create --replace cortecs_key - >/dev/null
unset key
echo 'Secret cortecs_key stored in Podman.'
