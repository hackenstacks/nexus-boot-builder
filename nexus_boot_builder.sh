#!/bin/sh
# nexus_boot_builder.sh — NeXuS Boot Builder state manager
#
# Designer: hackenstacks <nxsnet@proton.me>
# Project:  NeXuS Hadean-Eon Phase — Sovereign Service Orchestration
#
# Called by nexus_boot_builder.toml (watchbind) for all UI operations.
# Manages named boot profiles: which services start, in what mode.
#
# Each profile = a resource allocation decision:
#   studio    → kill heavy services, free RAM/CPU for production
#   server    → everything on for max capability
#   stealth   → minimum footprint, ghost lineup only
#   locked-down → no network services, local AI only
#   torrent   → file sharing + darknet stack
#   kiosk     → browser-facing only, no management surface
#   ghost     → RAM-only, no mounts, armed via nexus-ghost-mode.sh
#   default   → balanced daily ops
#
# Usage (via watchbind keybindings):
#   nexus_boot_builder.sh list           — generate service table (watchbind watched cmd)
#   nexus_boot_builder.sh toggle <id>    — toggle service enabled
#   nexus_boot_builder.sh ghost  <id>    — toggle ghost flag
#   nexus_boot_builder.sh mode           — cycle mode (tmux→daemon→ghost)
#   nexus_boot_builder.sh profile next   — cycle active profile
#   nexus_boot_builder.sh apply          — apply active profile now
#   nexus_boot_builder.sh restart        — stop + restart nexus-bg session
#   nexus_boot_builder.sh init           — (re)create profiles.json with all presets
#   nexus_boot_builder.sh new <name>     — clone current profile to new name
#   nexus_boot_builder.sh del            — delete active profile

# ── Paths ─────────────────────────────────────────────────────────────────────
PROFILES="${NEXUS_BOOT_PROFILES:-$HOME/.config/nexus/boot-profiles.json}"
NEXUS_HOME="${NEXUS_HOME:-$HOME/NeXuS}"
NEXUS_SCRIPTS="${NEXUS_SCRIPTS:-$HOME/scripts}"
SELF="$(readlink -f "$0")"
SELF_DIR="$(dirname "$SELF")"

BOOT_SH="$NEXUS_SCRIPTS/nexus-boot.sh"
GHOST_SH="$NEXUS_SCRIPTS/nexus-ghost-mode.sh"

MODES="tmux daemon ghost"

# ── Service registry (id:label:port:group) ────────────────────────────────────
# One entry per line — order determines list display order
REGISTRY="
api-proxy:NWS API Proxy:8443:direct
aichat:aichat AI API:3030:direct
nxs-search:NeXuS Search:5000:direct
step-ca:NeXuS CA:9000:stack
nncc:Network Cmd Ctr:8801:stack
wiki:nb Wiki:6789:stack
copyparty:File Server:8802:stack
metrics:Health Collector::direct
DivaChain:DivaChain:17468:stack
mkdocs:MkDocs Docs:8000:direct
"

# ── Preset service configs (jq-compatible JSON fragments) ─────────────────────
# Format: "id enabled ghost" lines, space-separated
_preset() {
    case "$1" in
        default)
            printf "api-proxy 1 1\naichat 1 1\nnxs-search 1 1\nstep-ca 1 0\nnncc 1 0\nwiki 1 0\ncopyparty 0 0\nmetrics 1 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        locked-down)
            # No network exposure — local AI only, health monitoring
            printf "api-proxy 0 0\naichat 1 0\nnxs-search 0 0\nstep-ca 0 0\nnncc 0 0\nwiki 0 0\ncopyparty 0 0\nmetrics 1 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        stealth)
            # Minimum footprint — ghost-flagged services only, mode=ghost
            printf "api-proxy 1 1\naichat 1 1\nnxs-search 1 1\nstep-ca 0 0\nnncc 0 0\nwiki 0 0\ncopyparty 0 0\nmetrics 0 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        torrent)
            # File sharing + darknet stack — copyparty + DivaChain/I2P
            printf "api-proxy 1 0\naichat 1 0\nnxs-search 1 0\nstep-ca 1 0\nnncc 1 0\nwiki 0 0\ncopyparty 1 0\nmetrics 1 0\nDivaChain 1 0\nmkdocs 0 0\n" ;;
        server)
            # Maximum capability — all services, full stack
            printf "api-proxy 1 1\naichat 1 1\nnxs-search 1 1\nstep-ca 1 0\nnncc 1 0\nwiki 1 0\ncopyparty 1 0\nmetrics 1 0\nDivaChain 0 0\nmkdocs 1 0\n" ;;
        studio)
            # Production focus — free RAM/CPU, no heavy services
            # Keep: AI + NWS for management + search. Kill: stack services.
            printf "api-proxy 1 0\naichat 1 0\nnxs-search 0 0\nstep-ca 0 0\nnncc 0 0\nwiki 0 0\ncopyparty 0 0\nmetrics 1 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        kiosk)
            # Browser-facing only — NWS at 8443, no management surface
            printf "api-proxy 1 0\naichat 0 0\nnxs-search 0 0\nstep-ca 1 0\nnncc 0 0\nwiki 0 0\ncopyparty 0 0\nmetrics 1 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        ghost)
            # RAM-only boot — armed via nexus-ghost-mode.sh arm
            printf "api-proxy 1 1\naichat 1 1\nnxs-search 1 1\nstep-ca 0 0\nnncc 0 0\nwiki 0 0\ncopyparty 0 0\nmetrics 0 0\nDivaChain 0 0\nmkdocs 0 0\n" ;;
        *)
            _preset default ;;
    esac
}

# Build a jq services object from a preset spec
_preset_json() {
    _preset "$1" | awk '
    BEGIN { printf "{" ; first=1 }
    NF == 3 {
        id=$1; en=($2=="1" ? "true":"false"); gh=($3=="1" ? "true":"false")
        if(!first) printf ","
        printf "\"" id "\":{\"enabled\":" en ",\"ghost\":" gh "}"
        first=0
    }
    END { printf "}" }
    '
}

# Build the complete default profiles.json
_build_default_json() {
    default_json=$(_preset_json default)
    locked_json=$(_preset_json locked-down)
    stealth_json=$(_preset_json stealth)
    torrent_json=$(_preset_json torrent)
    server_json=$(_preset_json server)
    studio_json=$(_preset_json studio)
    kiosk_json=$(_preset_json kiosk)
    ghost_json=$(_preset_json ghost)

    jq -n \
      --argjson d  "$default_json" \
      --argjson l  "$locked_json"  \
      --argjson st "$stealth_json" \
      --argjson t  "$torrent_json" \
      --argjson sv "$server_json"  \
      --argjson sd "$studio_json"  \
      --argjson k  "$kiosk_json"   \
      --argjson g  "$ghost_json"   \
      '{
        active: "default",
        profiles: {
          "default":     {mode:"tmux",   services:$d},
          "locked-down": {mode:"daemon", services:$l},
          "stealth":     {mode:"ghost",  services:$st},
          "torrent":     {mode:"tmux",   services:$t},
          "server":      {mode:"tmux",   services:$sv},
          "studio":      {mode:"daemon", services:$sd},
          "kiosk":       {mode:"daemon", services:$k},
          "ghost":       {mode:"ghost",  services:$g}
        }
      }'
}

# ── JSON helpers ──────────────────────────────────────────────────────────────
_ensure_profiles() {
    [ -f "$PROFILES" ] && return 0
    mkdir -p "$(dirname "$PROFILES")"
    _build_default_json > "$PROFILES"
}

_active()  { jq -r '.active' "$PROFILES"; }
_mode()    { jq -r ".profiles[\"$(_active)\"].mode // \"tmux\"" "$PROFILES"; }
_enabled() { jq -r ".profiles[\"$(_active)\"].services[\"$1\"].enabled // false" "$PROFILES"; }
_ghost()   { jq -r ".profiles[\"$(_active)\"].services[\"$1\"].ghost  // false" "$PROFILES"; }

_set() {
    # _set .profiles["name"].services["id"].enabled true
    tmp="$(mktemp)"
    jq "$1 = $2" "$PROFILES" > "$tmp" && mv "$tmp" "$PROFILES"
}

# ── Port probe (fast parallel) ────────────────────────────────────────────────
_live() {
    port="$1"
    [ -z "$port" ] && printf "·" && return
    nc -z -w1 127.0.0.1 "$port" 2>/dev/null && printf "●" || printf "○"
}

# ── List (watchbind watched command) ─────────────────────────────────────────
_list() {
    _ensure_profiles
    active=$(_active)
    mode=$(_mode)
    profiles=$(jq -r '.profiles | keys | join("  ")' "$PROFILES")

    # Header
    printf "PROFILES: %s\n" "$profiles"
    printf "ACTIVE:   %-14s  MODE: %s\n" "$active" "$mode"
    printf "%-12s  %-18s  %-6s  %-5s  %-7s  %s\n" \
        "SERVICE" "LABEL" "STATUS" "EN" "PORT" "GHOST"
    printf "%s\n" "────────────────────────────────────────────────────────────"

    echo "$REGISTRY" | grep -v '^$' | while IFS=: read -r id label port group; do
        [ -z "$id" ] && continue
        live=$(_live "$port")
        en=$(_enabled "$id")
        gh=$(_ghost  "$id")
        en_s=$([ "$en" = "true" ] && printf "[✓]" || printf "[ ]")
        gh_s=$([ "$gh" = "true" ] && printf "G" || printf "-")
        port_s=$([ -n "$port" ] && printf ":%-5s" "$port" || printf "──────")
        printf "%-12s  %-18s  %-6s  %-5s  %-7s  %s\n" \
            "$id" "$label" "$live" "$en_s" "$port_s" "$gh_s"
    done
}

# ── Commands ──────────────────────────────────────────────────────────────────
_toggle() {
    id="$1"
    _ensure_profiles
    active=$(_active)
    cur=$(_enabled "$id")
    new=$([ "$cur" = "true" ] && printf "false" || printf "true")
    _set ".profiles[\"$active\"].services[\"$id\"].enabled" "$new"
}

_ghost_toggle() {
    id="$1"
    _ensure_profiles
    active=$(_active)
    cur=$(_ghost "$id")
    new=$([ "$cur" = "true" ] && printf "false" || printf "true")
    _set ".profiles[\"$active\"].services[\"$id\"].ghost" "$new"
}

_cycle_mode() {
    _ensure_profiles
    active=$(_active)
    cur=$(_mode)
    case "$cur" in
        tmux)   new="daemon" ;;
        daemon) new="ghost"  ;;
        ghost)  new="tmux"   ;;
        *)      new="tmux"   ;;
    esac
    _set ".profiles[\"$active\"].mode" "\"$new\""
}

_next_profile() {
    _ensure_profiles
    active=$(_active)
    names=$(jq -r '.profiles | keys[]' "$PROFILES" | tr '\n' ' ')
    next=""
    found=0
    for n in $names; do
        if [ "$found" = "1" ]; then next="$n"; break; fi
        [ "$n" = "$active" ] && found=1
    done
    [ -z "$next" ] && next=$(jq -r '.profiles | keys | first' "$PROFILES")
    jq --arg n "$next" '.active = $n' "$PROFILES" > /tmp/nbp.tmp && mv /tmp/nbp.tmp "$PROFILES"
}

_apply() {
    _ensure_profiles
    mode=$(_mode)
    case "$mode" in
        ghost)  "$GHOST_SH" arm ;;
        daemon) "$BOOT_SH" daemon ;;
        *)      "$BOOT_SH" start ;;
    esac
}

_restart() {
    "$BOOT_SH" stop 2>/dev/null
    sleep 1
    "$BOOT_SH" start
}

_cleanup() {
    # Stealth session teardown — scrub traces from RAM and /tmp
    # Shell history
    cat /dev/null > "${HISTFILE:-$HOME/.bash_history}" 2>/dev/null
    cat /dev/null > "$HOME/.local/share/fish/fish_history" 2>/dev/null
    history -c 2>/dev/null || true

    # tmux pane history for nexus-bg session
    tmux list-panes -s -t nexus-bg -F '#{session_name}:#{window_index}.#{pane_index}' \
        2>/dev/null | while read -r pane; do
        tmux send-keys -t "$pane" "clear" Enter 2>/dev/null
        tmux clear-history -t "$pane" 2>/dev/null
    done

    # Temp logs
    rm -f /tmp/nexus-*.log /tmp/nexus-*.tmp 2>/dev/null

    # kernel dmesg is read-only but clear what we can
    sync

    printf "stealth cleanup: traces cleared\n"
}

_new_profile() {
    name="$1"
    [ -z "$name" ] && echo "Usage: nexus_boot_builder.sh new <name>" >&2 && return 1
    _ensure_profiles
    active=$(_active)
    jq --arg n "$name" --arg src "$active" \
        '.profiles[$n] = .profiles[$src] | .active = $n' \
        "$PROFILES" > /tmp/nbp.tmp && mv /tmp/nbp.tmp "$PROFILES"
}

_del_profile() {
    _ensure_profiles
    active=$(_active)
    count=$(jq '.profiles | length' "$PROFILES")
    [ "$count" -le 1 ] && echo "cannot delete last profile" >&2 && return 1
    jq --arg a "$active" \
        'del(.profiles[$a]) | .active = (.profiles | keys | first)' \
        "$PROFILES" > /tmp/nbp.tmp && mv /tmp/nbp.tmp "$PROFILES"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────
CMD="${1:-list}"
shift 2>/dev/null || true

case "$CMD" in
    list)           _list           ;;
    toggle)         _toggle   "$1"  ;;
    ghost)          _ghost_toggle "$1" ;;
    mode)           _cycle_mode     ;;
    profile)        _next_profile   ;;
    apply)          _apply          ;;
    restart)        _restart        ;;
    new)            _new_profile "$1" ;;
    del)            _del_profile    ;;
    cleanup)        _cleanup        ;;
    init)           mkdir -p "$(dirname "$PROFILES")"
                    _build_default_json > "$PROFILES"
                    echo "initialized: $PROFILES" ;;
    *)
        printf "Usage: %s {list|toggle|ghost|mode|profile|apply|restart|new|del|init}\n" \
            "$(basename "$0")"
        exit 1
        ;;
esac
