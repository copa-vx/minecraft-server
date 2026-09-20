# minecraft-server / client-stream

A vanilla Minecraft: Java Edition server **and** an offline Minecraft client,
bundled in one [Celaut](https://github.com/celaut-project/nodo) microVM, the
client's screen captured and sent out as a GameStream video stream — the same
shape as [`celaut-basics/remote-browser`'s
`stream/`](https://github.com/celaut-basics/remote-browser/tree/main/stream), with
a game in place of a browser.

See the [top-level README](../README.md) for why this exists alongside
[`server/`](../server/) and which one fits what you want. **Before relying on
this one, read [`NODE-REQUIREMENTS.md`](NODE-REQUIREMENTS.md)**: the client's
render backend currently fails to obtain an OpenGL context on this
architecture, confirmed by actually running it, and that section says exactly
what was tried and what to try next.

## No account, ever

Unlike `server/`, this architecture never talks to Mojang for authentication.
The bundled client launches straight into the bundled server over loopback; the
server always runs `online-mode=false`; nobody involved needs a Microsoft
account, a Mojang session, or network egress of any kind —
`service.json` declares `"network": []`. See `NODE-REQUIREMENTS.md` for the
handful of best-effort calls the client still attempts and why they are
harmless here.

Because there is no account, there is also no server list entry and no way for
anyone but the person holding the Moonlight session to join: `MINECRAFT_USERNAME`
is a display name, not an identity, and the bundled server's own port is never
published (see `entrypoint.sh` for why it also binds to loopback, on top of
that).

## The EULA

Mojang requires that whoever operates a server accept
[the EULA](https://aka.ms/MinecraftEULA), explicitly — this bundles a server, so
it applies here exactly as it does in `server/`. Pass `MINECRAFT_EULA=true` at
launch or the entrypoint refuses to start and says why.

```bash
nodo execute minecraft-server-client-stream \
  -e MINECRAFT_EULA true -e ADMIN_USER nodo -e ADMIN_PASS <something>
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MINECRAFT_EULA` | *(required)* | Must be exactly `true`. |
| `ADMIN_USER` | *(required)* | Sunshine's own pairing username — see below. |
| `ADMIN_PASS` | *(required)* | Sunshine's own pairing password. |
| `MINECRAFT_USERNAME` | `Player` | The bundled client's display name in its own (single-player, in effect) world. |
| `MINECRAFT_DIFFICULTY` | `easy` | `peaceful`, `easy`, `normal`, or `hard`. |
| `MINECRAFT_GAMEMODE` | `survival` | `survival`, `creative`, `adventure`, or `spectator`. |
| `MINECRAFT_LEVEL_SEED` | *(random)* | World seed. Only matters on first generation. |
| `MINECRAFT_VIEW_DISTANCE` | `10` | Chunks, `3`-`32`. |
| `MINECRAFT_MEMORY` | `1536M` | The bundled **server's** JVM heap. |
| `MINECRAFT_CLIENT_MEMORY` | `2048M` | The bundled **client's** JVM heap. |
| `WIDTH` / `HEIGHT` | `1280` / `720` | Stream resolution — see "What this costs" in `NODE-REQUIREMENTS.md` before reaching for 1080p. |
| `FPS` | `30` | Target frame rate. |
| `SW_PRESET` | `ultrafast` | x264 software preset. Faster presets trade quality for the CPU budget the client and server are also drawing from. |
| `TIMEZONE` | `UTC` | |

`ADMIN_USER`/`ADMIN_PASS` are refused rather than defaulted or generated, for the
same reason `remote-browser/stream` refuses them: an unset password would leave
Sunshine's own configuration API, port 47990, open to anything that can reach it.

There is no `MINECRAFT_ONLINE_MODE`, `MINECRAFT_WHITELIST`, `MINECRAFT_OPS`,
`MINECRAFT_MAX_PLAYERS`, `MINECRAFT_MOTD`, or `MINECRAFT_PVP` here, unlike
`server/`: nothing external can ever reach the bundled server's port, so a
whitelist, an op list, an MOTD nobody sees in a server list they never open, and
player-vs-player all describe a multiplayer situation this architecture does not
have. If you want other people to actually join the world, that is what
`server/` is for.

The Minecraft version is pinned in `.service/Dockerfile`, the same version as
`server/` — see there for why, and `NODE-REQUIREMENTS.md` for the two ARGs that
anchor the client's own download.

## Pairing Moonlight

Sunshine, not this entrypoint, owns pairing. After the instance is up and the
[eight tunnels](NODE-REQUIREMENTS.md) are open:

```bash
curl -k -u "$ADMIN_USER:$ADMIN_PASS" https://127.0.0.1:47990/api/pin -d '{"pin": "<code Moonlight shows you>"}'
```

exactly as documented for [Sunshine
itself](https://docs.lizardbyte.dev/projects/sunshine/latest/about/guides/pairing_guide.html) — this entrypoint only seeds the admin credentials at
startup, the same as `remote-browser/stream`.

## Pack

```bash
nodo pack client-stream
```

`architecture` is `linux/arm64` in `.service/service.json`.

## Tests

```bash
python3 -m unittest discover -s ../tests -v
```

See [`../tests/test_manifest.py`](../tests/test_manifest.py) — one suite, shared
with `server/`.

## What this is not

- **Not a way for other people to join.** One Moonlight session, one player, the
  same limit `remote-browser/stream` has for the same reason: GameStream is not a
  multi-viewer protocol. Use `server/` for a world other people connect to with
  their own client.
- **Not modded, not Bedrock, not backed up.** Same as `server/`.
- **Not smooth.** No GPU in the guest — see "What this costs" in
  `NODE-REQUIREMENTS.md`.
- **Not currently able to render a frame at all.** See the open blocker in
  `NODE-REQUIREMENTS.md` before packing this expecting a picture.

## Status

Specification and implementation, and further than that: built and run, not
working yet. See `NODE-REQUIREMENTS.md` for exactly where it stops and
[`../TODO.md`](../TODO.md) for what to try next.
