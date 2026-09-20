# minecraft-server

A vanilla Minecraft: Java Edition server, packaged as
[Celaut](https://github.com/celaut-project/nodo) services, **two of them**,
following the same shape as [`celaut-basics/remote-browser`](https://github.com/celaut-basics/remote-browser):
each is a self-contained `.service/` (Dockerfile, `service.json`,
`pack_config.json`) plus `service/` (the entrypoint), sharing one `tests/` at the
top of the repository.

## Why two

Both run the same server jar. They differ in **who holds the client**.

| | [`server/`](server/) | [`client-stream/`](client-stream/) |
|---|---|---|
| what it is | a dedicated server, nothing else | a dedicated server **and** a Minecraft client, in the same microVM |
| what you need | your own Minecraft: Java Edition client | a Moonlight client, installed natively — see `client-stream/NODE-REQUIREMENTS.md` |
| accounts | your real Mojang/Microsoft account, or none if `MINECRAFT_ONLINE_MODE=false` | none — the bundled client is offline, always, and always plays against its own bundled server |
| who can join | anyone who reaches the published port, limited by `MINECRAFT_WHITELIST` | one person, whoever is holding the Moonlight session — the same limit `remote-browser/stream` has |
| transport | the Minecraft protocol itself, plaintext | H.264 video + audio, the GameStream family of ports |
| network egress | one Mojang hostname, only if `MINECRAFT_ONLINE_MODE=true` | **none** |

### Which to run

- **You already have Minecraft installed, and want to host a world for people who
  also have it:** `server/`. It is the smaller image, the smaller resource
  footprint, and the one that does what `nodo pack`-ing a dedicated server has
  always meant.
- **You do not want to install Minecraft at all, or want to hand someone a world
  they can play from a browser tab away — a phone, a borrowed laptop, a Steam
  Deck — with nothing installed but a Moonlight client:** `client-stream/`. The
  cost is the one every architecture in `remote-browser/stream` already pays: no
  GPU in the microVM, so the client renders in software, and the honest target is
  low resolution at a modest frame rate, not what the same game looks like on your
  own machine. See its own README for exactly how modest, and why.

Nothing about `server/` changed to make room for the other; the two do not share
code, only a version pin and a set of tests.

## The EULA

Mojang requires that whoever operates a server accept
[the EULA](https://aka.ms/MinecraftEULA), explicitly. Neither architecture accepts
it on your behalf: pass `MINECRAFT_EULA=true` at launch, or the entrypoint refuses
to start and says why. There is no default that makes this optional, in either one.

## Pack

```bash
nodo pack server
nodo pack client-stream
```

`architecture` is `linux/arm64` in both `service.json`s. The packer builds for the
host it runs on; change it to match yours.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

One suite, covering both architectures: every declared env is read and every read
env is declared, `init.entry_path` points at a file that exists, the EULA has no
`:-true` fallback anywhere, and neither's network declaration has quietly widened
past what its own README says. None of these is something a launch failure would
catch; they are the class of drift that leaves a service running and just quietly
wrong.

## Status

Both have been built and run — in a plain Docker container on `linux/arm64`,
not yet inside an actual `nodo` microVM, which is the gap `nodo pack`ing and
launching either one for real would close. `server/` boots to `Done` and
stops cleanly on `SIGTERM`; a real client actually connecting is the one thing
left unconfirmed. `client-stream/` boots its bundled server, display, audio,
and Sunshine correctly too, but its bundled client fails to obtain an OpenGL
context — a specific, verified blocker, not an unknown — before it ever
streams a frame. See [`TODO.md`](TODO.md) before spending time on either, and
each architecture's own `NODE-REQUIREMENTS.md` for everything else.
