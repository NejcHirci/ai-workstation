#!/usr/bin/env bash
# Run the sandbox checks inside a throwaway agent container. Counterpart of verify-sandbox.ps1.
#
#   verify-sandbox.sh [--docs] <workspace>
#
#   --docs   also start and test the squid docs proxy
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docs=0; workspace=''
for a in "$@"; do
    case "$a" in
        --docs)     docs=1 ;;
        -h|--help)  sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          workspace="$a" ;;
    esac
done
[[ -n "$workspace" ]] || die 'Usage: verify-sandbox.sh [--docs] <workspace>'
[[ -d "$workspace" ]] || die "Workspace not found: $workspace"
ws="$(cd "$workspace" && pwd -P)"

assert_podman
init_networks
start_gateway
if (( docs )); then start_squid; fi

build_agent_args "$ws" "$docs" 0
exec podman "${RUN_ARGS[@]}" -v "$(bind_arg "$SCRIPT_DIR/verify-inside.sh" /verify.sh)" \
    "$AGENT_IMAGE" bash /verify.sh
