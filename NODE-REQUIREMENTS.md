# What `minecraft-server` needs

## From the node

- **A persistent disk.** The one property that makes this service worth running at
  all is that the world outlives the instance. Everything that matters --
  `level.dat`, the region files, `ops.json`, `whitelist.json` -- lives under `/data`,
  and if the node reclaims that filesystem between launches there is no world, only
  a fresh one generated from whatever `MINECRAFT_LEVEL_SEED` says. This is the
  opposite default from `remote-browser`, where ephemeral disk is correct; here it
  would throw away the one thing an operator came back for.
- **Egress to `sessionserver.mojang.com`, if `MINECRAFT_ONLINE_MODE=true`** (the
  default). The server itself calls it, once per connecting player, to check they
  really authenticated with Mojang/Microsoft — this is not the player's own
  connection, which arrives on the api slot below. Set
  `MINECRAFT_ONLINE_MODE=false` to run with no egress at all, at the cost of
  accepting any username a client claims, which is only reasonable behind a
  whitelist you trust for other reasons.
- **Nothing else.** No GPU, no `/dev/dri`, no input device: a Minecraft server has
  no display of its own. The game runs entirely in every connecting client.

## From the host

- **A Minecraft: Java Edition client**, the same major version this image's
  `.service/Dockerfile` pins (`MINECRAFT_VERSION` there, currently `26.3`). A
  client on a different major version will refuse to connect, or connect and
  desync — the protocol is not guaranteed compatible across releases.
- **`nodo tunnel`, if you are not ready to publish 25565.** The server itself has
  no transport encryption; the Minecraft protocol is plaintext beyond the login
  handshake. A published port is reachable by anything that can route to the node,
  limited only by whether it is on `MINECRAFT_WHITELIST`.

```bash
nodo tunnel <instance> 25565 --listen 25565
# then connect a Minecraft client to 127.0.0.1:25565
```

## What the host should be careful about

**`MINECRAFT_WHITELIST` and `MINECRAFT_OPS` are read once, at startup**, and applied
by sending `whitelist add`/`op` commands to the server's own console after it
reports ready — the server does the actual name-to-UUID lookup against Mojang, this
service does not maintain its own copy of that mapping. Adding a player later means
restarting the instance with an updated list, or reaching the console some other
way; there is no live-reload path here.

**`MINECRAFT_MEMORY` is checked against this instance's own `mem_limit` at startup**
and the service refuses to start rather than let the JVM be OOM-killed once the
game is already running. If you raise `mem_limit` in `.service/service.json`,
raising `MINECRAFT_MEMORY` to use the extra room is a manual step, not automatic.

## What this architecture does not have

**Anti-cheat, backups, or automatic restarts on crash.** This is a vanilla server
in a microVM, not a hosting platform. A `stop` from the console, `SIGTERM`, or the
server crashing all end the instance the same way `nodo` ends any instance.

## Status

Specification and implementation. **Nothing has been packed or run.**

The base image digest, the JRE's Debian version, and the server jar's sha1 were all
checked against their respective sources (Docker Hub's registry, packages.debian.org
for the security-updated version rather than the source index which lags behind it,
and Mojang's `version_manifest_v2.json`) on 2026-09-20.

Where to look first when it does not work:

- Whether `openjdk-25-jre-headless` still resolves to the pinned version by the time
  this is built — Debian security updates move that version number, and the fix is
  to re-check `packages.debian.org/trixie/openjdk-25-jre-headless` and edit the
  Dockerfile, not to drop the pin.
- Whether the `]: Done (` string `wait_for_ready` greps for is still what this
  server version prints on a successful start; it has held across releases so far
  but is not part of any documented interface.
- Whether `sessionserver.mojang.com` is still the hostname a server calls for
  session verification, or whether Mojang has moved it under
  `api.minecraftservices.com` for this release — the `network` entry in
  `service.json` names the one this repository could confirm.
