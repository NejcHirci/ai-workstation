#!/usr/bin/env bash
# Add, remove or list domains in the Squid allowlist and reload Squid without a restart.
# Counterpart of allow-site.ps1.
#
#   allow-site.sh DOMAIN|URL [DOMAIN...] [--exact] [--minutes N] [--force]
#   allow-site.sh DOMAIN [DOMAIN...] --remove
#   allow-site.sh --list
#   allow-site.sh --prune
#
#   --exact      only that exact host (default: it and all its subdomains)
#   --minutes N  temporary entry; removed when this script next runs after N minutes
#   --force      allow domains where the agent could also upload data
#
# Run it on the host, never inside the agent container. Several domains may also be given
# comma separated. Needs bash 4 or newer.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOW_FILE="$REPO_ROOT/images/squid/allowlist.txt"
EXPIRY_FILE="$REPO_ROOT/images/squid/allowlist.expiry"   # host only, not mounted: "entry<TAB>unix-seconds"

# Domains where an approval would also allow uploading data (paste sites, file hosts, tunnels, user-content hosting).
RISKY=(github.com gist.github.com gitlab.com bitbucket.org pastebin.com hastebin.com
       transfer.sh file.io drive.google.com docs.google.com googleusercontent.com
       storage.googleapis.com dropbox.com onedrive.live.com amazonaws.com
       blob.core.windows.net discord.com slack.com telegram.org webhook.site
       requestbin.com ngrok.io ngrok-free.app workers.dev pages.dev herokuapp.com
       vercel.app netlify.app huggingface.co)

mode=add; exact=0; minutes=0; force=0; domains=()
while (( $# )); do
    case "$1" in
        --list)    mode=list ;;
        --prune)   mode=prune ;;
        --remove)  mode=remove ;;
        --exact)   exact=1 ;;
        --force)   force=1 ;;
        --minutes) shift; minutes="${1:?--minutes needs a number}"
                   [[ "$minutes" =~ ^[0-9]+$ && "$minutes" -ge 1 && "$minutes" -le 10080 ]] \
                       || die '--minutes must be between 1 and 10080' ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        die "Unknown option: $1" ;;
        *)         IFS=', ' read -r -a parts <<< "$1"
                   for p in "${parts[@]}"; do [[ -n "$p" ]] && domains+=("$p"); done ;;
    esac
    shift
done
if [[ $mode == add || $mode == remove ]] && (( ${#domains[@]} == 0 )); then
    die 'Give at least one domain (see --help).'
fi

# ---------- state ----------
lines=()      # raw allowlist lines (comments preserved)
declare -A expiry=()

read_state() {
    lines=()
    if [[ -f "$ALLOW_FILE" ]]; then
        while IFS= read -r l || [[ -n "$l" ]]; do lines+=("${l%$'\r'}"); done < "$ALLOW_FILE"
    fi
    expiry=()
    if [[ -f "$EXPIRY_FILE" ]]; then
        while IFS=$'\t' read -r k v || [[ -n "$k" ]]; do
            [[ -n "$k" && "$v" =~ ^[0-9]+$ ]] && expiry["$k"]="$v"
        done < "$EXPIRY_FILE"
    fi
    return 0
}

write_state() {
    # Overwrite in place (same inode) so the bind mount in the Squid container sees the change.
    if (( ${#lines[@]} )); then printf '%s\n' "${lines[@]}" > "$ALLOW_FILE"; else : > "$ALLOW_FILE"; fi
    if (( ${#expiry[@]} )); then
        for k in "${!expiry[@]}"; do printf '%s\t%s\n' "$k" "${expiry[$k]}"; done | sort > "$EXPIRY_FILE"
    else
        rm -f "$EXPIRY_FILE"
    fi
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

entries() {   # prints non-comment, non-empty lines of the allowlist
    local l
    for l in "${lines[@]+"${lines[@]}"}"; do
        l="$(trim "$l")"
        [[ -n "$l" && "$l" != \#* ]] && printf '%s\n' "$l"
    done
    return 0
}

has_entry() {   # no pipe to grep -q here: with pipefail an early exit would count as failure
    local all
    all="$(entries)"
    [[ $'\n'"$all"$'\n' == *$'\n'"$1"$'\n'* ]]
}

remove_entry() {   # remove_entry ENTRY  (drops matching lines and its expiry)
    local new=() l
    for l in "${lines[@]+"${lines[@]}"}"; do
        [[ "$(trim "$l")" == "$1" ]] || new+=("$l")
    done
    lines=("${new[@]+"${new[@]}"}")
    unset 'expiry[$1]'
}

# ---------- domain handling ----------
HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$'

normalize_host() {   # URL or host -> clean lowercase host name
    local s="${1,,}"
    s="${s//[[:space:]]/}"
    if [[ "$s" =~ ^[a-z][a-z0-9+.-]*:// ]]; then
        s="${s#*://}"; s="${s%%/*}"; s="${s%%\?*}"; s="${s%%#*}"; s="${s##*@}"; s="${s%%:*}"
    fi
    while [[ "$s" == .* ]]; do s="${s#.}"; done
    while [[ "$s" == *. ]]; do s="${s%.}"; done
    if (( ${#s} > 253 )) || ! [[ "$s" =~ $HOST_RE ]]; then
        die "'$1' is not a valid host name (no wildcards, ports, paths or IP addresses)."
    fi
    printf '%s' "$s"
}

risky_match() {   # prints the risky domain that overlaps $1, if any
    local r
    for r in "${RISKY[@]}"; do
        if [[ "$1" == "$r" || "$1" == *".$r" || "$r" == *".$1" ]]; then printf '%s' "$r"; return 0; fi
    done
    return 0
}

covered() {   # covered ENTRY: is it already allowed by an existing entry?
    local name="${1#.}" wild=0 e base
    [[ "$1" == .* ]] && wild=1
    while IFS= read -r e; do
        if [[ "$e" == .* ]]; then
            base="${e#.}"
            if [[ "$name" == "$base" || "$name" == *".$base" ]]; then return 0; fi
        elif (( ! wild )) && [[ "$e" == "$name" ]]; then
            return 0
        fi
    done < <(entries)
    return 1
}

# ---------- expiry and reload ----------
remove_expired() {   # returns 0 if something was removed
    local now k gone=1
    now="$(date +%s)"
    for k in "${!expiry[@]}"; do
        if (( expiry[$k] <= now )); then
            remove_entry "$k"
            echo "Expired and removed: $k"
            gone=0
        fi
    done
    return $gone
}

update_squid() {
    if ! podman info >/dev/null 2>&1; then echo 'Podman is not usable; the list applies when Squid next starts.'; return 0; fi
    if ! container_running egress-squid; then echo 'Squid is not running; the list applies on next start (agent.sh --docs).'; return 0; fi
    podman exec egress-squid squid -k reconfigure >/dev/null 2>&1 || die 'squid -k reconfigure failed.'
    local inside onDisk
    inside="$(podman exec egress-squid cat /etc/squid/allowlist.txt | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v -e '^$' -e '^#' | sort || true)"
    onDisk="$(entries | sort)"
    if [[ "$inside" != "$onDisk" ]]; then
        warn 'Squid sees a different allowlist than the file on disk. Run: podman rm -f egress-squid  (agent.sh --docs recreates it).'
    else
        echo 'Squid reloaded and in sync.'
    fi
}

# ---------- main ----------
read_state
changed=0
if remove_expired; then changed=1; fi

case "$mode" in
    list)
        mapfile -t cur < <(entries)
        if (( ${#cur[@]} == 0 )); then echo '(allowlist is empty)'; fi
        for e in "${cur[@]+"${cur[@]}"}"; do
            if [[ -n "${expiry[$e]+x}" ]]; then
                printf '%-40s expires %s\n' "$e" "$(date -d "@${expiry[$e]}" '+%Y-%m-%d %H:%M')"
            else
                printf '%-40s permanent\n' "$e"
            fi
        done ;;

    prune)
        (( changed )) || echo 'Nothing to prune.' ;;

    remove)
        for d in "${domains[@]}"; do
            h="$(normalize_host "$d")"
            if has_entry "$h" || has_entry ".$h"; then
                remove_entry "$h"; remove_entry ".$h"
                echo "Removed: $h"; changed=1
            else
                warn "$h is not in the allowlist."
            fi
        done ;;

    add)
        for d in "${domains[@]}"; do
            h="$(normalize_host "$d")"
            if (( exact )); then entry="$h"; else entry=".$h"; fi

            bad="$(risky_match "$h")"
            if [[ -n "$bad" ]] && (( ! force )); then
                warn "Refusing ${h}: it overlaps '$bad', where the agent could also upload data. Re-run with --force only if you accept that."
                continue
            fi

            if has_entry "$entry"; then
                if [[ -z "${expiry[$entry]+x}" ]]; then
                    echo "Already allowed (permanent): $entry"; continue
                fi
            elif covered "$entry"; then
                echo "Already allowed by a broader entry: $h"; continue
            else
                lines+=("$entry")
            fi

            if (( minutes )); then
                expiry["$entry"]=$(( $(date +%s) + minutes * 60 ))
                echo "Allowed $entry for $minutes minute(s) (until $(date -d "@${expiry[$entry]}" '+%H:%M'))."
            else
                unset 'expiry[$entry]'
                echo "Allowed $entry permanently."
            fi
            changed=1
        done ;;
esac

if (( changed )); then
    write_state
    update_squid
fi
