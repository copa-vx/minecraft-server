#!/usr/bin/env bash
# Bring up a vanilla Minecraft server whose world lives in /data.
#
# The whole service, in order: validate the environment against the EULA and against
# the memory this instance was actually given, write server.properties from scratch,
# start the server with its console on a pipe this script keeps open, wait for it to
# report ready, feed it whitelist/op commands over that same console, and then get out
# of the way until asked to stop.
#
# Two things it is careful about, for the same reason bitcoin-node is careful about its
# two:
#
# * It never lets the JVM ask for more heap than this instance's cgroup will honour.
#   An -Xmx bigger than mem_limit is not a Java error, it is the kernel OOM-killing the
#   process at some unpredictable point after startup -- a crash with no exception and
#   no log line, which is the failure mode this script exists to turn into a refusal at
#   start rather than a mystery ten minutes in.
# * It stops the server with its own "stop" command, not a signal. A killed Minecraft
#   server can leave region files half-written, the same class of problem a killed
#   bitcoind has with its chainstate, and for the same reason: both hold their state in
#   files they only flush in an orderly shutdown.

set -euo pipefail

DATA_DIR=/data
SERVER_JAR=/srv/minecraft/server.jar
CONSOLE_FIFO=/run/minecraft/console
WRAPPER_LOG="${DATA_DIR}/logs/entrypoint-console.log"

# The port this image's service.json declares. Not an env var: changing it here without
# changing the manifest is exactly the drift tests/test_manifest.py exists to catch.
SERVER_PORT=25565

SERVER_PID=''
STOPPING=''
SERVER_STATUS=''

log() {
    printf '[minecraft-server] %s\n' "$1"
}

fail() {
    log "FATAL: $1"
    exit 1
}

is_bool() {
    case "$1" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ------------------------------------------------------------------ environment
read_environment() {
    EULA=$(trim "${MINECRAFT_EULA:-}")
    if [ "$EULA" != "true" ]; then
        fail "MINECRAFT_EULA is not 'true'. Mojang's EULA (https://aka.ms/MinecraftEULA) has to be accepted by whoever operates this server, explicitly, every time -- this service will not default it for you."
    fi

    ONLINE_MODE=$(trim "${MINECRAFT_ONLINE_MODE:-true}")
    is_bool "$ONLINE_MODE" || fail "MINECRAFT_ONLINE_MODE='${ONLINE_MODE}' is not 'true' or 'false'"

    MOTD="${MINECRAFT_MOTD:-A Celaut Minecraft server}"

    MAX_PLAYERS=$(trim "${MINECRAFT_MAX_PLAYERS:-20}")
    case "$MAX_PLAYERS" in ''|*[!0-9]*) fail "MINECRAFT_MAX_PLAYERS='${MAX_PLAYERS}' is not a whole number" ;; esac

    DIFFICULTY=$(trim "${MINECRAFT_DIFFICULTY:-easy}")
    case "$DIFFICULTY" in
        peaceful|easy|normal|hard) : ;;
        *) fail "MINECRAFT_DIFFICULTY='${DIFFICULTY}' is not one of peaceful, easy, normal, hard" ;;
    esac

    GAMEMODE=$(trim "${MINECRAFT_GAMEMODE:-survival}")
    case "$GAMEMODE" in
        survival|creative|adventure|spectator) : ;;
        *) fail "MINECRAFT_GAMEMODE='${GAMEMODE}' is not one of survival, creative, adventure, spectator" ;;
    esac

    LEVEL_SEED="${MINECRAFT_LEVEL_SEED:-}"

    VIEW_DISTANCE=$(trim "${MINECRAFT_VIEW_DISTANCE:-10}")
    case "$VIEW_DISTANCE" in ''|*[!0-9]*) fail "MINECRAFT_VIEW_DISTANCE='${VIEW_DISTANCE}' is not a whole number" ;; esac
    if [ "$VIEW_DISTANCE" -lt 3 ] || [ "$VIEW_DISTANCE" -gt 32 ]; then
        fail "MINECRAFT_VIEW_DISTANCE=${VIEW_DISTANCE} is outside the range the server accepts, 3-32"
    fi

    PVP=$(trim "${MINECRAFT_PVP:-true}")
    is_bool "$PVP" || fail "MINECRAFT_PVP='${PVP}' is not 'true' or 'false'"

    WHITELIST=$(trim "${MINECRAFT_WHITELIST:-}")
    OPS=$(trim "${MINECRAFT_OPS:-}")

    MEMORY=$(trim "${MINECRAFT_MEMORY:-1536M}")
    case "$MEMORY" in
        [0-9]*M|[0-9]*G) : ;;
        *) fail "MINECRAFT_MEMORY='${MEMORY}' is not a number followed by M or G, e.g. 1536M or 2G" ;;
    esac
}

# --------------------------------------------------------------------- resources
# Bytes a heap spec like "1536M" or "2G" asks for.
memory_to_bytes() {
    local spec="$1" unit="${1: -1}" number="${1%?}"
    case "$unit" in
        M) printf '%d' $(( number * 1024 * 1024 )) ;;
        G) printf '%d' $(( number * 1024 * 1024 * 1024 )) ;;
    esac
}

# Refuse an -Xmx the container's own cgroup cannot honour, rather than let the kernel
# OOM-kill the JVM later with nothing in this service's own logs to explain why.
# JVM_OVERHEAD_BYTES is what the process needs beyond the heap itself: metaspace, thread
# stacks, and the direct buffers the server's networking and region-file I/O use.
check_memory_fits_cgroup() {
    local heap_bytes limit_bytes limit_file JVM_OVERHEAD_BYTES=$((384 * 1024 * 1024))
    heap_bytes=$(memory_to_bytes "$MEMORY")

    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit_file=/sys/fs/cgroup/memory.max
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_file=/sys/fs/cgroup/memory/memory.limit_in_bytes
    else
        log "no cgroup memory limit visible; skipping the -Xmx sanity check"
        return 0
    fi

    limit_bytes=$(cat "$limit_file")
    case "$limit_bytes" in
        max|9223372036854771712)
            log "cgroup reports no memory limit; skipping the -Xmx sanity check"
            return 0
            ;;
    esac

    if [ $(( heap_bytes + JVM_OVERHEAD_BYTES )) -gt "$limit_bytes" ]; then
        fail "MINECRAFT_MEMORY=${MEMORY} plus this JVM's own overhead (~$((JVM_OVERHEAD_BYTES / 1024 / 1024))M) does not fit in the $((limit_bytes / 1024 / 1024))M this instance's mem_limit allows. Raise mem_limit in service.json's resources, or lower MINECRAFT_MEMORY -- an -Xmx that does not fit is not a Java error, it is a silent OOM-kill partway through the game."
    fi
    log "MINECRAFT_MEMORY=${MEMORY} fits the ${limit_bytes}-byte cgroup limit"
}

# --------------------------------------------------------------------- configuration
# Written at every start from this service's environment. Editing it by hand in /data
# has no lasting effect: the next start overwrites it. The world itself is untouched --
# it lives under level-name, not in this file.
write_configuration() {
    mkdir -p "${DATA_DIR}/logs"
    printf 'eula=true\n' > "${DATA_DIR}/eula.txt"

    {
        printf 'server-port=%s\n' "$SERVER_PORT"
        printf 'motd=%s\n' "$MOTD"
        printf 'max-players=%s\n' "$MAX_PLAYERS"
        printf 'difficulty=%s\n' "$DIFFICULTY"
        printf 'gamemode=%s\n' "$GAMEMODE"
        printf 'view-distance=%s\n' "$VIEW_DISTANCE"
        printf 'pvp=%s\n' "$PVP"
        printf 'online-mode=%s\n' "$ONLINE_MODE"
        if [ -n "$LEVEL_SEED" ]; then
            printf 'level-seed=%s\n' "$LEVEL_SEED"
        fi
        if [ -n "$WHITELIST" ]; then
            printf 'white-list=true\n'
            printf 'enforce-whitelist=true\n'
        else
            printf 'white-list=false\n'
        fi
        # The server binds every interface inside its own microVM; the instance's
        # network is the node's firewall, not this file's business.
        printf 'server-ip=\n'
        printf 'enable-status=true\n'
    } > "${DATA_DIR}/server.properties"

    log "configuration written: difficulty=${DIFFICULTY} gamemode=${GAMEMODE} online-mode=${ONLINE_MODE}"
}

# ------------------------------------------------------------------------- console
# A fifo kept open for both ends, so writing a command to it does not close the pipe
# the server is reading its console from. `exec {fd}<>path` is what keeps it open.
open_console() {
    mkdir -p "$(dirname "$CONSOLE_FIFO")"
    [ -p "$CONSOLE_FIFO" ] || mkfifo -m 600 "$CONSOLE_FIFO"
    exec 3<>"$CONSOLE_FIFO"
}

send_console() {
    printf '%s\n' "$1" >&3
}

wait_for_ready() {
    local timeout="${1:-300}" deadline=$(( SECONDS + ${1:-300} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if grep -q '\]: Done (' "$WRAPPER_LOG" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            fail "the server exited before finishing startup; see ${WRAPPER_LOG}"
        fi
        sleep 1
    done
    fail "the server did not report ready within ${timeout}s; see ${WRAPPER_LOG}"
}

# Whitelisting and opping by name rather than by hand-written UUID: the server itself
# resolves the name against Mojang, which is a real lookup and not a restatement of
# whatever this script was told.
apply_players() {
    local name
    if [ -n "$WHITELIST" ]; then
        IFS=',' read -ra names <<< "$WHITELIST"
        for name in "${names[@]}"; do
            name=$(trim "$name")
            [ -n "$name" ] || continue
            send_console "whitelist add ${name}"
        done
        send_console "whitelist reload"
        log "whitelisted: ${WHITELIST}"
    fi
    if [ -n "$OPS" ]; then
        IFS=',' read -ra names <<< "$OPS"
        for name in "${names[@]}"; do
            name=$(trim "$name")
            [ -n "$name" ] || continue
            send_console "op ${name}"
        done
        log "opped: ${OPS}"
    fi
}

# ------------------------------------------------------------------------ lifecycle
# Ask the server to save and stop, and wait for it to actually do so, rather than
# signalling the JVM. A `kill` can land mid-write to a region file; `stop` cannot,
# because the server does not consider itself stopped until it has finished.
stop_server() {
    local reason="${1:-signal}"
    [ -n "$SERVER_PID" ] || return 0
    [ -z "$STOPPING" ] || return 0
    STOPPING=1
    kill -0 "$SERVER_PID" 2>/dev/null || return 0

    log "${reason}: asking the server to save and stop"
    send_console "save-all flush" || true
    send_console "stop" || true

    local deadline=$(( SECONDS + 120 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            wait "$SERVER_PID" 2>/dev/null && SERVER_STATUS=0 || SERVER_STATUS=$?
            return 0
        fi
        sleep 1
    done
    log "the server did not stop in 120s after 'stop'; sending SIGTERM (region files may be left mid-write)"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null && SERVER_STATUS=0 || SERVER_STATUS=$?
    return 0
}

on_signal() {
    stop_server "signal $1"
}

main() {
    read_environment
    check_memory_fits_cgroup
    write_configuration
    # write_configuration and the mkdir -p calls in it run as root; everything
    # they create under /data is root-owned until this, and the JVM below runs
    # as minecraft. Without it the server still starts -- log4j and
    # server.properties-rewrite failures are non-fatal -- but silently, with no
    # world log and every properties rewrite failing from here on.
    chown -R minecraft:minecraft "$DATA_DIR"
    open_console

    cd "$DATA_DIR"
    runuser -u minecraft -- \
        java -Xms"${MEMORY}" -Xmx"${MEMORY}" \
             -jar "$SERVER_JAR" --nogui \
        <&3 > >(tee -a "$WRAPPER_LOG") 2>&1 &
    SERVER_PID=$!

    trap 'on_signal TERM' TERM
    trap 'on_signal INT' INT

    wait_for_ready
    apply_players

    log "ready: Minecraft on :${SERVER_PORT}, world in ${DATA_DIR}"

    local status=0
    while kill -0 "$SERVER_PID" 2>/dev/null; do
        wait "$SERVER_PID" && status=0 || status=$?
    done
    if [ -n "$SERVER_STATUS" ]; then
        return "$SERVER_STATUS"
    fi
    return "$status"
}

main "$@"
