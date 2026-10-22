#!/usr/bin/env bash
# Start the sandboxed OpenCode agent for a project. Counterpart of agent.ps1.
#
#   agent.sh [--docs] [--shell] [--restart-gateway] <workspace> [opencode arguments...]
#
#   --docs             also start the squid docs proxy (domain allowlist)
#   --shell            open bash instead of opencode
#   --restart-gateway  recreate the gateway (new key or template)
#
# Options are recognised before the workspace and directly after it; the first other
# word after the workspace starts the opencode arguments.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docs=0; shell=0; restart=''; workspace=''; agent_args=()
while (( $# )); do
    case "$1" in
        --docs)            docs=1 ;;
        --shell)           shell=1 ;;
        --restart-gateway) restart=restart ;;
        -h|--help)         sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)
            if [[ -z "$workspace" ]]; then workspace="$1"
            else agent_args=("$@"); break
            fi ;;
    esac
    shift
done
[[ -n "$workspace" ]] || die 'Usage: agent.sh [--docs] [--shell] [--restart-gateway] <workspace> [opencode arguments...]'
[[ -d "$workspace" ]] || die "Workspace not found: $workspace"
ws="$(cd "$workspace" && pwd -P)"

assert_podman
init_networks
start_gateway "$restart"
if (( docs )); then start_squid; fi

build_agent_args "$ws" "$docs" 1
if (( shell )); then
    cmd=(bash)
else
    cmd=(opencode ${agent_args[@]+"${agent_args[@]}"})
fi
exec podman "${RUN_ARGS[@]}" "$AGENT_IMAGE" "${cmd[@]}"
