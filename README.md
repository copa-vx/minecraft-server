# minecraft-server

A vanilla Minecraft: Java Edition server, packaged as a
[Celaut](https://github.com/celaut-project/nodo) service (microVM), following the
same shape as the rest of [`copa-vx`](https://github.com/copa-vx) and
[`celaut-basics`](https://github.com/celaut-basics): `.service/` (Dockerfile,
`service.json`, `pack_config.json`), `service/` (the entrypoint), `tests/`, and this
README.

## Why package a game server as a Celaut service

A Minecraft server is ordinary software with an unusual property: it is one of the
few servers most people have ever run themselves, on hardware they own, for friends
they know by name. That makes it a good fit for a network of nodes that already
exists to run somebody else's workload on somebody else's machine — the same
motion as asking a friend "can you host it this time", except the specification the
node reads says up front what the service will touch, and the image it runs is
pinned by content hash rather than by "whatever `docker pull` gets today".

It is also a clean case for what Celaut's isolation actually buys here: a
Minecraft server is a JVM parsing untrusted, attacker-influenced input — the
packets of anyone who connects — continuously, for as long as it runs. Whatever
that JVM can reach is what the microVM's `network` declaration says it can reach,
which for this service is one hostname, not the internet.

## The EULA

Mojang requires that whoever runs a server accept
[the EULA](https://aka.ms/MinecraftEULA), explicitly. This service will not accept
it on your behalf: pass `MINECRAFT_EULA=true` at launch, or the entrypoint refuses
to start and says why. There is no default that makes this optional.

```bash
nodo execute minecraft-server -e MINECRAFT_EULA true
```

## Configuration

Everything below is an environment variable read once, at startup, and turned into
`/data/server.properties` written fresh on every launch — editing that file by hand
does not survive a restart, on purpose, for the same reason `bitcoin-node` rewrites
`bitcoin.conf` every time: the manifest is the single source of truth for
configuration, and the world (which lives elsewhere, under `level-name`) is the only
state that is supposed to persist across it.

| Variable | Default | Meaning |
|---|---|---|
| `MINECRAFT_EULA` | *(required)* | Must be exactly `true`. |
| `MINECRAFT_ONLINE_MODE` | `true` | Verify players against Mojang. `false` needs no network but trusts any claimed username. |
| `MINECRAFT_MOTD` | `A Celaut Minecraft server` | The line shown in the server list. |
| `MINECRAFT_MAX_PLAYERS` | `20` | |
| `MINECRAFT_DIFFICULTY` | `easy` | `peaceful`, `easy`, `normal`, or `hard`. |
| `MINECRAFT_GAMEMODE` | `survival` | `survival`, `creative`, `adventure`, or `spectator`. |
| `MINECRAFT_LEVEL_SEED` | *(random)* | World seed. Only matters on first generation. |
| `MINECRAFT_VIEW_DISTANCE` | `10` | Chunks, `3`-`32`. The main lever on memory and CPU. |
| `MINECRAFT_PVP` | `true` | |
| `MINECRAFT_WHITELIST` | *(none)* | Comma-separated usernames, applied once at startup. See `NODE-REQUIREMENTS.md`. |
| `MINECRAFT_OPS` | *(none)* | Comma-separated usernames, granted operator once at startup. |
| `MINECRAFT_MEMORY` | `1536M` | JVM `-Xms`/`-Xmx`, e.g. `1536M` or `3G`. Checked against this instance's `mem_limit` at startup — see below. |

The Minecraft version itself is not a runtime variable. It is pinned in
`.service/Dockerfile` at build time, the same way `bitcoin-node` pins Bitcoin Core:
the content hash of the image is supposed to mean something, and a version anyone
could override at launch would make it mean less.

## Memory, and why it can refuse to start

`MINECRAFT_MEMORY` sets the JVM heap. If that heap plus the JVM's own overhead
(metaspace, thread stacks, direct buffers) would not fit inside this instance's
`mem_limit`, the entrypoint fails immediately with a message naming both numbers,
rather than starting a server the kernel OOM-kills at some unpredictable point once
players are on it. That failure has no exception and no log line of its own — it is
the silent kind these `celaut-basics`-style services are written to turn into a
loud one at the boundary instead. Raise `mem_limit` in `.service/service.json`'s
`resources`, or lower `MINECRAFT_MEMORY`, whichever is actually true for the node
you are launching on.

## Network

```json
"network": [{ "tags": ["sessionserver.mojang.com"] }]
```

Deliberately not `["*"]`. Unlike `remote-browser`, where the destination is
whoever the person driving it clicks on and genuinely cannot be enumerated in
advance, this service's only outbound call is to one fixed Mojang hostname, made by
the server itself to check a connecting player's session — and only when
`MINECRAFT_ONLINE_MODE` is at its default of `true`. `nodo` resolves that tag to
its current A records at launch; running with `MINECRAFT_ONLINE_MODE=false` needs
no network entry to be honoured at all.

## Persistence

The world lives in `/data`, expected to be the instance's persistent disk — see
`NODE-REQUIREMENTS.md`. This is the opposite default from `remote-browser`'s
architectures, where the disk is deliberately ephemeral: there, persistence would
be a stray login surviving past the session it belonged to; here, the entire reason
to run this service twice is that the second time the world is still there.

## Shutdown

`SIGTERM` does not go to the JVM. It goes to the server's own console as
`save-all flush` followed by `stop`, and the entrypoint waits for the process to
exit on its own before returning. A killed Minecraft server can leave a region file
half-written the same way a killed `bitcoind` can leave a corrupt chainstate, and
for the same underlying reason: both hold their real state in files they only
flush in an orderly shutdown. If the server does not stop within 120 seconds, the
entrypoint escalates to `SIGTERM` on the process and says so, which is the one path
where a region file can still end up mid-write.

## Pack

```bash
nodo pack minecraft-server
```

`architecture` is `linux/arm64` in `.service/service.json`. The packer builds for
the host it runs on; change it to match yours.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

They check `service.json` against `entrypoint.sh` — every declared env is read and
every read env is declared, the one api slot matches `SERVER_PORT`, the EULA has no
`:-true` fallback anywhere, and the network declaration has not quietly widened to
a wildcard. None of these is something a launch failure would catch; they are the
class of drift that leaves a service running and just quietly wrong.

## What this is not

- **Not a modded or Bedrock server.** Vanilla Java Edition, matching whatever
  `MINECRAFT_VERSION` the Dockerfile currently pins.
- **Not backed up.** The persistent disk is the only copy of the world this service
  knows about.
- **Not protected from griefing by anything other than `MINECRAFT_WHITELIST`.**
  Publishing 25565 to an unwhitelisted, online-mode server means any Minecraft
  account can join.

## Status

Specification and implementation. **Nothing has been packed or run.** See
`NODE-REQUIREMENTS.md` for what to check first if it does not come up.
