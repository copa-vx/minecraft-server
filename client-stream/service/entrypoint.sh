#!/usr/bin/env bash
# PID 1 of this instance: a vanilla Minecraft server nobody outside this microVM
# can reach, and a Minecraft client playing on it, its screen captured and sent
# out as a GameStream video stream -- the same shape as remote-browser/stream,
# with a game in place of a browser and a server in place of nothing.
#
# Five processes, brought up in dependency order: the world (so there is
# something to join), a display nobody can see, a sound card that does not
# exist, the client (so there is something to capture), and the thing that turns
# a captured X display into an H.264 stream. Each wait below is for a fact -- a
# console line, a socket answering -- because the node reports an instance ready
# the moment the guest's IP answers, seconds before anything here has started.
#
# There is no api slot for the server's own port. This architecture's whole
# point is that nobody needs a Minecraft client of their own to use it; opening
# 25565 would just be a second, worse way in, for the one player already sitting
# in front of the stream.

set -euo pipefail

DATA_DIR=/data
SERVER_JAR=/srv/minecraft/server.jar
CLIENT_DIR=/srv/minecraft/client
CONSOLE_FIFO=/run/minecraft/console
LOGS=/data/logs
SERVER_PORT=25565

SERVER_PID=''
STOPPING=''

log() { printf '%s [client-stream] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

is_bool() { case "$1" in true|false) return 0 ;; *) return 1 ;; esac; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ------------------------------------------------------------------ environment
EULA=$(trim "${MINECRAFT_EULA:-}")
[ "$EULA" = "true" ] || fail "MINECRAFT_EULA is not 'true'. Mojang's EULA (https://aka.ms/MinecraftEULA) has to be accepted by whoever operates this server, explicitly, every time -- this service will not default it for you. The bundled client plays against the bundled server; the EULA covers both."

USERNAME=$(trim "${MINECRAFT_USERNAME:-Player}")
DIFFICULTY=$(trim "${MINECRAFT_DIFFICULTY:-easy}")
case "$DIFFICULTY" in peaceful|easy|normal|hard) : ;; *) fail "MINECRAFT_DIFFICULTY='${DIFFICULTY}' is not one of peaceful, easy, normal, hard" ;; esac

GAMEMODE=$(trim "${MINECRAFT_GAMEMODE:-survival}")
case "$GAMEMODE" in survival|creative|adventure|spectator) : ;; *) fail "MINECRAFT_GAMEMODE='${GAMEMODE}' is not one of survival, creative, adventure, spectator" ;; esac

LEVEL_SEED="${MINECRAFT_LEVEL_SEED:-}"

VIEW_DISTANCE=$(trim "${MINECRAFT_VIEW_DISTANCE:-10}")
case "$VIEW_DISTANCE" in ''|*[!0-9]*) fail "MINECRAFT_VIEW_DISTANCE='${VIEW_DISTANCE}' is not a whole number" ;; esac
if [ "$VIEW_DISTANCE" -lt 3 ] || [ "$VIEW_DISTANCE" -gt 32 ]; then
    fail "MINECRAFT_VIEW_DISTANCE=${VIEW_DISTANCE} is outside the range the server accepts, 3-32"
fi

MEMORY=$(trim "${MINECRAFT_MEMORY:-1536M}")
case "$MEMORY" in [0-9]*M|[0-9]*G) : ;; *) fail "MINECRAFT_MEMORY='${MEMORY}' is not a number followed by M or G, e.g. 1536M or 2G" ;; esac

CLIENT_MEMORY=$(trim "${MINECRAFT_CLIENT_MEMORY:-2048M}")
case "$CLIENT_MEMORY" in [0-9]*M|[0-9]*G) : ;; *) fail "MINECRAFT_CLIENT_MEMORY='${CLIENT_MEMORY}' is not a number followed by M or G, e.g. 2048M or 3G" ;; esac

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
SW_PRESET="${SW_PRESET:-ultrafast}"
TIMEZONE="${TIMEZONE:-UTC}"

ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] || fail \
  "ADMIN_USER and ADMIN_PASS are unset. Pass them at launch:
     nodo execute minecraft-server-client-stream -e MINECRAFT_EULA true -e ADMIN_USER nodo -e ADMIN_PASS <something>
   Refusing rather than generating one: an unset password would leave Sunshine's
   configuration API open to anything that can reach port 47990, and a generated
   one would have to be read back out of the serial log, which is worse than
   being asked for it. Same reasoning as remote-browser/stream."

export TZ="$TIMEZONE"
mkdir -p "$LOGS" "$DATA_DIR" /run/pulse "$(dirname "$CONSOLE_FIFO")"

# --------------------------------------------------------------------- resources
# Two JVMs in one cgroup, plus Xvfb, PulseAudio and Sunshine's own encoder buffers.
# OVERHEAD_BYTES covers the second three, generously -- none of them holds a heap
# the way a JVM does, but llvmpipe's own working set and Sunshine's frame buffers
# are real memory this instance's mem_limit has to cover too.
memory_to_bytes() {
    local unit="${1: -1}" number="${1%?}"
    case "$unit" in
        M) printf '%d' $(( number * 1024 * 1024 )) ;;
        G) printf '%d' $(( number * 1024 * 1024 * 1024 )) ;;
    esac
}

check_memory_fits_cgroup() {
    local server_bytes client_bytes limit_bytes limit_file
    local JVM_OVERHEAD_BYTES=$((384 * 1024 * 1024))
    local STACK_OVERHEAD_BYTES=$((512 * 1024 * 1024))
    server_bytes=$(memory_to_bytes "$MEMORY")
    client_bytes=$(memory_to_bytes "$CLIENT_MEMORY")

    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit_file=/sys/fs/cgroup/memory.max
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_file=/sys/fs/cgroup/memory/memory.limit_in_bytes
    else
        log "no cgroup memory limit visible; skipping the memory sanity check"
        return 0
    fi

    limit_bytes=$(cat "$limit_file")
    case "$limit_bytes" in
        max|9223372036854771712)
            log "cgroup reports no memory limit; skipping the memory sanity check"
            return 0
            ;;
    esac

    local needed=$(( server_bytes + client_bytes + 2 * JVM_OVERHEAD_BYTES + STACK_OVERHEAD_BYTES ))
    if [ "$needed" -gt "$limit_bytes" ]; then
        fail "MINECRAFT_MEMORY=${MEMORY} + MINECRAFT_CLIENT_MEMORY=${CLIENT_MEMORY}, plus both JVMs' own overhead and Xvfb/PulseAudio/Sunshine (~$((STACK_OVERHEAD_BYTES / 1024 / 1024))M), need $((needed / 1024 / 1024))M and this instance's mem_limit is only $((limit_bytes / 1024 / 1024))M. Raise mem_limit in service.json's resources, or lower one of the two MINECRAFT_*MEMORY variables."
    fi
    log "server=${MEMORY} + client=${CLIENT_MEMORY} + stack overhead fits the ${limit_bytes}-byte cgroup limit"
}

# ----------------------------------------------------------------- offline UUID
# Exactly Java's UUID.nameUUIDFromBytes(("OfflinePlayer:"+name).getBytes(UTF_8)):
# MD5 the name, then force the version/variant nibbles. This is the same formula
# a vanilla server uses, server-side, to assign a UUID to a claimed username when
# online-mode is false -- computing it here too means the client and the server
# agree on this player's identity (and therefore their inventory) across restarts,
# rather than each inventing their own and drifting apart on the second launch.
offline_uuid() {
    local name="$1" md5 nb6 nb8 hex
    md5=$(printf '%s' "OfflinePlayer:${name}" | md5sum | cut -d' ' -f1)
    nb6=$(printf '%02x' $(( (0x${md5:12:2} & 0x0f) | 0x30 )))
    nb8=$(printf '%02x' $(( (0x${md5:16:2} & 0x3f) | 0x80 )))
    hex="${md5:0:12}${nb6}${md5:14:2}${nb8}${md5:18:14}"
    printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# --------------------------------------------------------------------- server
write_server_properties() {
    mkdir -p "${DATA_DIR}/logs"
    printf 'eula=true\n' > "${DATA_DIR}/eula.txt"
    {
        printf 'server-port=%s\n' "$SERVER_PORT"
        # Bound to loopback, on top of there being no api slot for it: nothing
        # outside this JVM's own client should ever be able to open a login
        # sequence against it, and this is the difference between "unreachable
        # because unpublished" and "unreachable, full stop".
        printf 'server-ip=127.0.0.1\n'
        printf 'online-mode=false\n'
        printf 'max-players=2\n'
        printf 'difficulty=%s\n' "$DIFFICULTY"
        printf 'gamemode=%s\n' "$GAMEMODE"
        printf 'view-distance=%s\n' "$VIEW_DISTANCE"
        if [ -n "$LEVEL_SEED" ]; then
            printf 'level-seed=%s\n' "$LEVEL_SEED"
        fi
        printf 'white-list=false\n'
        printf 'enable-status=false\n'
    } > "${DATA_DIR}/server.properties"
    log "server.properties written: difficulty=${DIFFICULTY} gamemode=${GAMEMODE}"
}

open_console() {
    [ -p "$CONSOLE_FIFO" ] || mkfifo -m 600 "$CONSOLE_FIFO"
    exec 3<>"$CONSOLE_FIFO"
}

send_console() { printf '%s\n' "$1" >&3; }

wait_for_server_ready() {
    local timeout=300 deadline=$(( SECONDS + 300 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -q '\]: Done (' "${LOGS}/server-console.log" 2>/dev/null && return 0
        kill -0 "$SERVER_PID" 2>/dev/null || fail "the server exited before finishing startup; see ${LOGS}/server-console.log"
        sleep 1
    done
    fail "the server did not report ready within ${timeout}s; see ${LOGS}/server-console.log"
}

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
        kill -0 "$SERVER_PID" 2>/dev/null || { wait "$SERVER_PID" 2>/dev/null || true; return 0; }
        sleep 1
    done
    log "the server did not stop in 120s after 'stop'; sending SIGTERM (region files may be left mid-write)"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

start_server() {
    write_server_properties
    # write_server_properties and the mkdir -p calls earlier in main() all run as
    # root; everything they create under /data is root-owned until this, and the
    # JVM below runs as minecraft. Without it the server still starts -- Mojang's
    # own log4j and properties-save failures are non-fatal -- but silently, with
    # no world log and every server.properties rewrite failing.
    chown -R minecraft:minecraft "$DATA_DIR"
    open_console
    cd "$DATA_DIR"
    runuser -u minecraft -- \
        java -Xms"${MEMORY}" -Xmx"${MEMORY}" -jar "$SERVER_JAR" --nogui \
        <&3 > >(tee -a "${LOGS}/server-console.log") 2>&1 &
    SERVER_PID=$!
    wait_for_server_ready
    log "world ready on 127.0.0.1:${SERVER_PORT} (not published -- see the top of this file)"
}

# ------------------------------------------------------------------------- X
start_display() {
    # Exported here, not just passed to the client below: Sunshine reads DISPLAY
    # from its own environment too, and without it, it was observed skipping
    # straight past x11 capture to probe nvenc/vulkan/vaapi -- none of which
    # exist in this microVM -- and dying with "Unable to find display or
    # encoder during startup" despite `capture = x11` in its own config.
    export DISPLAY=:0
    # +extension GLX, explicitly: without it Xvfb answers ordinary X11 fine and
    # every OpenGL context request fails as if no GLX existed at all, which is a
    # much more confusing failure than a client that never launches.
    Xvfb :0 -screen 0 "${WIDTH}x${HEIGHT}x24" -ac -nolisten tcp -noreset \
        +extension GLX +extension RENDER \
        >"${LOGS}/xvfb.log" 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 100); do
        DISPLAY=:0 xdpyinfo >/dev/null 2>&1 && { log "X display :0 is up"; return 0; }
        sleep 0.1
    done
    fail "Xvfb never answered on :0 (see ${LOGS}/xvfb.log)"
}

# --------------------------------------------------------------------- audio
start_audio() {
    cat > /etc/pulse/nodo.pa <<'PA'
load-module module-native-protocol-unix auth-anonymous=1 socket=/run/pulse/native
load-module module-null-sink sink_name=nodo_null sink_properties=device.description=nodo-null
set-default-sink nodo_null
PA
    pulseaudio --system --disallow-exit --exit-idle-time=-1 -n --file=/etc/pulse/nodo.pa \
        >"${LOGS}/pulse.log" 2>&1 &
    PULSE_PID=$!
    for _ in $(seq 1 100); do
        [ -S /run/pulse/native ] && break
        sleep 0.1
    done
    [ -S /run/pulse/native ] || log "WARNING: pulseaudio socket never appeared; the stream will be silent"
}

# ------------------------------------------------------------------ sunshine
start_sunshine() {
    local state=/home/minecraft/.sunshine
    # The Sunshine .deb ships no /etc/sunshine of its own -- confirmed by
    # actually installing it; there is nothing here for `sunshine.conf` to land
    # in until this creates it.
    mkdir -p "$state" /etc/sunshine
    cat > /etc/sunshine/sunshine.conf <<CONF
port = 47989
address_family = ipv4
upnp = off
origin_web_ui_allowed = wan
capture = x11
encoder = software
sw_preset = ${SW_PRESET}
sw_tune = zerolatency
audio_sink = nodo_null.monitor
min_log_level = info
log_path = ${LOGS}/sunshine.log
credentials_file = ${state}/sunshine_creds.json
file_state = ${state}/sunshine_state.json
file_apps = ${state}/apps.json
fps = [${FPS}]
resolutions = [${WIDTH}x${HEIGHT}]
CONF
    cat > "${state}/apps.json" <<APPS
{ "env": {}, "apps": [ { "name": "Minecraft" } ] }
APPS
    chown -R minecraft:minecraft "$state"

    sunshine /etc/sunshine/sunshine.conf --creds "$ADMIN_USER" "$ADMIN_PASS" \
        >"${LOGS}/sunshine-creds.log" 2>&1 || fail "sunshine --creds failed (see ${LOGS}/sunshine-creds.log)"
    sunshine /etc/sunshine/sunshine.conf >"${LOGS}/sunshine.stdout" 2>&1 &
    SUNSHINE_PID=$!
    log "sunshine up (encoder=software preset=${SW_PRESET} ${WIDTH}x${HEIGHT}@${FPS})"
}

# -------------------------------------------------------------------- client
start_client() {
    local uuid; uuid=$(offline_uuid "$USERNAME")
    local version_id; version_id=$(cat "${CLIENT_DIR}/version-id")
    # fetch-client.py names the index file after its own id (Mojang's assetIndex.id,
    # "34" here) -- the file's basename *is* the id, nothing to parse out of JSON.
    local asset_index_json; asset_index_json=$(ls "${CLIENT_DIR}"/assets/indexes/*.json)
    local asset_index; asset_index=$(basename "$asset_index_json" .json)

    local cp="${CLIENT_DIR}/client.jar" lib
    while IFS=':' read -d: -r lib || [ -n "$lib" ]; do
        [ -n "$lib" ] && cp="${cp}:${CLIENT_DIR}/${lib}"
    done < <(cat "${CLIENT_DIR}/libraries.classpath"; printf ':')

    # LIBGL_ALWAYS_SOFTWARE: there is no /dev/dri in this microVM to accelerate
    # with (see the Dockerfile), so llvmpipe is not a fallback here, it is the
    # only implementation. --accessToken/--userType are ignored by an
    # online-mode=false server; --uuid is not, which is why it is computed
    # rather than left to whatever the client would invent on its own.
    LIBGL_ALWAYS_SOFTWARE=1 DISPLAY=:0 PULSE_SERVER=unix:/run/pulse/native \
    runuser -u minecraft --whitelist-environment=LIBGL_ALWAYS_SOFTWARE,DISPLAY,PULSE_SERVER -- \
        java -Xms"${CLIENT_MEMORY}" -Xmx"${CLIENT_MEMORY}" \
             -cp "$cp" net.minecraft.client.main.Main \
             --username "$USERNAME" --version "$version_id" \
             --gameDir /home/minecraft/game --assetsDir "${CLIENT_DIR}/assets" \
             --assetIndex "$asset_index" \
             --uuid "$uuid" --accessToken 0 --userType legacy --versionType release \
             --width "$WIDTH" --height "$HEIGHT" \
             --quickPlayMultiplayer "127.0.0.1:${SERVER_PORT}" \
        >"${LOGS}/client.log" 2>&1 &
    CLIENT_PID=$!
    log "client launched as '${USERNAME}' (uuid ${uuid}), quick-playing 127.0.0.1:${SERVER_PORT}"
}

on_signal() {
    log "signal $1: shutting down"
    stop_server "signal $1"
    kill "${XVFB_PID:-}" "${PULSE_PID:-}" "${SUNSHINE_PID:-}" "${CLIENT_PID:-}" 2>/dev/null || true
    exit 0
}

main() {
    check_memory_fits_cgroup
    mkdir -p /home/minecraft/game
    chown -R minecraft:minecraft /home/minecraft

    start_server
    start_display
    start_audio
    start_sunshine
    start_client

    trap 'on_signal TERM' TERM
    trap 'on_signal INT' INT

    log "up: server=${SERVER_PID} xvfb=${XVFB_PID} pulse=${PULSE_PID} sunshine=${SUNSHINE_PID} client=${CLIENT_PID}"

    # None of the five is optional: without the server there is nothing to play,
    # without Xvfb nothing to capture, without Sunshine nothing to connect to,
    # and a client that died leaves a stream of a frozen or blank screen that
    # looks exactly like a working service. Whichever exits first takes the
    # instance down, on purpose, rather than run on half dead.
    wait -n "$SERVER_PID" "$XVFB_PID" "$PULSE_PID" "$SUNSHINE_PID" "$CLIENT_PID"
    log "a child process exited; shutting the instance down"
    stop_server "a child process exited"
    kill "$XVFB_PID" "$PULSE_PID" "$SUNSHINE_PID" "$CLIENT_PID" 2>/dev/null || true
}

main "$@"
