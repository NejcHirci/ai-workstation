#!/usr/bin/env bash
# Shared helpers for the Linux scripts. Source it; do not run it.
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Counterpart of lib.ps1 (Windows). Keep the two in step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AGENT_IMAGE='localhost/ai-agent:latest'
GATEWAY_IMG='docker.io/nginxinc/nginx-unprivileged:1.27-alpine'   # pin to a digest once verified
SQUID_IMG='docker.io/ubuntu/squid:latest'                         # pin to a digest once verified
NET_INTERNAL='agent-internal'
NET_EGRESS='agent-egress'
GATEWAY_IP='10.89.77.10'
SQUID_IP='10.89.77.11'

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# SELinux (Fedora, RHEL): bind mounts need ",z" so the container may read them.
SELINUX=0
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" == Enforcing ]]; then
    SELINUX=1
fi

bind_arg() {   # bind_arg SOURCE TARGET [MODE]  -> value for podman -v (default mode: ro)
    local mode="${3:-ro}"
    if (( SELINUX )); then mode="$mode,z"; fi
    printf '%s:%s:%s' "$1" "$2" "$mode"
}

assert_podman() {
    command -v podman >/dev/null 2>&1 || die 'podman is not installed (see GUIDE.md section 3L).'
    podman info >/dev/null 2>&1 || die 'Podman is not usable. Run "podman info" to see why (see GUIDE.md section 3L).'
}

# --- cgroup limits: only pass flags for controllers delegated to the rootless user ---
CONTROLLERS=''
CONTROLLERS_LOADED=0
LIMITS=()

load_controllers() {
    if (( CONTROLLERS_LOADED )); then return 0; fi
    CONTROLLERS=" $(podman info --format '{{range .Host.CgroupControllers}}{{.}} {{end}}') "
    CONTROLLERS_LOADED=1
    local missing='' c
    for c in pids memory cpu; do
        if [[ "$CONTROLLERS" != *" $c "* ]]; then missing="$missing $c"; fi
    done
    if [[ -n "$missing" ]]; then
        warn "Cgroup controllers not delegated to rootless Podman:$missing. Those limits are skipped (see GUIDE.md, section 3L.3)."
    fi
    return 0
}

limit_args() {   # limit_args PIDS MEMORY [CPUS]  -> fills the LIMITS array
    load_controllers
    LIMITS=()
    if [[ -n "${1:-}" && "$CONTROLLERS" == *" pids "*   ]]; then LIMITS+=(--pids-limit "$1"); fi
    if [[ -n "${2:-}" && "$CONTROLLERS" == *" memory "* ]]; then LIMITS+=(--memory "$2"); fi
    if [[ -n "${3:-}" && "$CONTROLLERS" == *" cpu "*    ]]; then LIMITS+=(--cpus "$3"); fi
    return 0
}

init_networks() {
    if ! podman network exists "$NET_INTERNAL"; then
        podman network create --internal --disable-dns --subnet 10.89.77.0/24 "$NET_INTERNAL" >/dev/null
    fi
    if ! podman network exists "$NET_EGRESS"; then
        podman network create --subnet 10.89.78.0/24 "$NET_EGRESS" >/dev/null
    fi
}

container_running() {   # container_running NAME
    [[ -n "$(podman ps --filter "name=^$1\$" --format '{{.Names}}')" ]]
}

start_gateway() {   # start_gateway [restart]
    if [[ "${1:-}" == restart ]]; then podman rm -f llm-gateway >/dev/null 2>&1 || true; fi
    if container_running llm-gateway; then return 0; fi
    podman rm -f llm-gateway >/dev/null 2>&1 || true

    podman secret exists cortecs_key || die 'Secret cortecs_key missing. Run: bash scripts/set-key.sh'
    local tpl="$REPO_ROOT/images/gateway/default.conf.template"

    limit_args 256 256m
    podman run -d --name llm-gateway \
        --network "$NET_INTERNAL:ip=$GATEWAY_IP" --network "$NET_EGRESS" \
        --read-only --tmpfs /tmp --tmpfs '/etc/nginx/conf.d:rw,mode=1777' \
        --cap-drop=all --security-opt no-new-privileges ${LIMITS[@]+"${LIMITS[@]}"} \
        --secret 'cortecs_key,type=env,target=CORTECS_API_KEY' \
        -e 'NGINX_ENVSUBST_FILTER=^CORTECS_' \
        -v "$(bind_arg "$tpl" /etc/nginx/templates/default.conf.template)" \
        "$GATEWAY_IMG" >/dev/null

    local i
    for i in $(seq 1 20); do
        if podman exec llm-gateway wget -q -O- http://127.0.0.1:8080/healthz >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    podman logs llm-gateway || true
    die 'Gateway did not become healthy.'
}

start_squid() {
    if container_running egress-squid; then return 0; fi
    podman rm -f egress-squid >/dev/null 2>&1 || true
    local conf="$REPO_ROOT/images/squid/squid.conf"
    local allow="$REPO_ROOT/images/squid/allowlist.txt"
    limit_args 256 512m
    podman run -d --name egress-squid \
        --network "$NET_INTERNAL:ip=$SQUID_IP" --network "$NET_EGRESS" \
        --security-opt no-new-privileges ${LIMITS[@]+"${LIMITS[@]}"} \
        -v "$(bind_arg "$conf" /etc/squid/squid.conf)" -v "$(bind_arg "$allow" /etc/squid/allowlist.txt)" \
        "$SQUID_IMG" >/dev/null
}

# build_agent_args WORKSPACE DOCS(0|1) INTERACTIVE(0|1) [NAME]  -> fills the RUN_ARGS array
RUN_ARGS=()
build_agent_args() {
    local ws="$1" docs="${2:-0}" interactive="${3:-0}" name="${4:-}"
    local proj safe
    proj="$(basename "$ws")"
    safe="${proj//[^a-zA-Z0-9_.-]/_}"
    if [[ -z "$name" ]]; then name="agent-$safe-$RANDOM"; fi

    RUN_ARGS=(run --rm --init)
    if (( interactive )); then RUN_ARGS+=(-it); fi
    RUN_ARGS+=(--name "$name" --hostname agent)

    # Identity and hardening (the host user is mapped to uid 1000 inside the container)
    RUN_ARGS+=(--userns=keep-id:uid=1000,gid=1000 --user 1000:1000
               --read-only --cap-drop=all --security-opt no-new-privileges
               --tmpfs /tmp:rw,exec,size=2g)
    limit_args 4096 12g 6
    RUN_ARGS+=(${LIMITS[@]+"${LIMITS[@]}"})

    # Network: internal only, no DNS, gateway by static IP
    RUN_ARGS+=(--network "$NET_INTERNAL" --add-host "llm-gateway:$GATEWAY_IP" --dns=none)

    # Workspace (read-write) with protected sub-paths (read-only overlays)
    RUN_ARGS+=(-v "$(bind_arg "$ws" /workspace rw)" -w /workspace -e "PROJECT_NAME=$safe")
    local p d
    if [[ -d "$ws/.git" ]]; then
        for p in hooks config; do
            if [[ -e "$ws/.git/$p" ]]; then RUN_ARGS+=(-v "$(bind_arg "$ws/.git/$p" "/workspace/.git/$p")"); fi
        done
    else
        warn '.git is not a directory (worktree or submodule?). Hooks and config are NOT protected.'
    fi
    for d in .vscode .devcontainer .husky .githooks; do
        if [[ -d "$ws/$d" ]]; then RUN_ARGS+=(-v "$(bind_arg "$ws/$d" "/workspace/$d")"); fi
    done

    # Shared skills (read-only), config (read-only), state and build cache (named volumes)
    local skills="$HOME/.agents/skills"
    local cfg="$REPO_ROOT/config/opencode"
    mkdir -p "$skills"
    RUN_ARGS+=(-v "$(bind_arg "$skills" /home/agent/.agents/skills)"
               -v "$(bind_arg "$cfg" /etc/opencode)"
               -v agent-home:/home/agent
               -v agent-cache:/cache)
    if [[ -d "$cfg/agents" ]]; then
        RUN_ARGS+=(-v "$(bind_arg "$cfg/agents" /home/agent/.config/opencode/agents)")
    fi

    if (( docs )); then
        local px="http://$SQUID_IP:3128" no="llm-gateway,$GATEWAY_IP"
        RUN_ARGS+=(-e "HTTPS_PROXY=$px" -e "https_proxy=$px" -e "NO_PROXY=$no" -e "no_proxy=$no")
    fi
    return 0
}
