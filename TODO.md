# TODO

Both architectures were built and run on `linux/arm64` on 2026-09-20, inside a
container rather than a real `nodo` microVM. `server/` boots to `Done` and stops
cleanly on `SIGTERM`. `client-stream/`'s fetch stage, bundled server, display,
audio and Sunshine stack all came up correctly together in one instance; its
client was confirmed *not* to render a frame, with a specific error, the same
day. The list below is in three halves accordingly.

## Confirm, in this order

### `server/` — boots; unconfirmed against a real client and a real node

1. `nodo pack server`, launch on an actual node, `nodo tunnel <instance> 25565
   --listen 25565`, connect a real Minecraft: Java Edition client to
   `127.0.0.1:25565`. Everything up to the network boundary a container can
   stand in for has been checked; the protocol handshake with a real client has
   not.
2. Whether `]: Done (` is still what this server version prints on a successful
   start — `wait_for_ready` greps for it and nothing documents it as stable.
3. Whether `sessionserver.mojang.com` is still the hostname a server calls for
   session verification when `MINECRAFT_ONLINE_MODE=true`, or whether Mojang has
   moved it under `api.minecraftservices.com` for this release.

### `client-stream/` — the one with a confirmed blocker

1. **The render backend.** `NODE-REQUIREMENTS.md` has the exact error
   (`Couldn't find matching GLX visual`, from SDL3's X11 backend, surfaced
   through Mojang's `renderpearl` abstraction) and four things worth trying,
   ordered by how likely each is to be worth the time: SDL's own verbose
   logging past whatever swallows it today, Xorg+`dummy`+glamor in place of
   Xvfb, VirtualGL between the client and Xvfb, or decompiling
   `GlDevice` to read the actual FBConfig request. Nothing downstream of this
   (Sunshine, the tunnels, Moonlight pairing) can be confirmed until a frame
   exists to capture.
2. **Sunshine's X11 capture against a display no compositor ever touched** —
   the same open item `remote-browser/stream`'s own TODO lists and has not yet
   closed either. Once the client renders, this is the next thing that could
   turn "a frame exists" into "a black screen with horizontal lines" instead.
3. The `POST /api/pin` request shape for pairing, and whether this Sunshine
   build wants `pairing_id` — copied from `remote-browser/stream`'s own
   unconfirmed item, not independently checked here.
4. Whether a node leaves enough of the port layout intact for the eight-tunnel
   recipe in `client-stream/NODE-REQUIREMENTS.md` — same question
   `remote-browser/stream`'s TODO asks, same answer expected.

## Build

### A UUID that survives a rebuild, not just a restart, in `client-stream/`

`offline_uuid` derives a player's UUID from `MINECRAFT_USERNAME` alone, so
inventory persists across restarts of the same instance. It does not and cannot
survive `nodo pack`-ing a new image with a different username default reused by
mistake, or moving `/data` to a different instance under a different name. Worth
a line in the README if this trips someone; not worth solving, since the
alternative is a Mojang account, which is the one thing this architecture is
built not to need.

### Whether `client-stream/`'s two-JVM memory check is generous enough

`check_memory_fits_cgroup` reserves a flat 512 MiB for Xvfb, PulseAudio and
Sunshine combined, guessed rather than measured. Once the render blocker above
is closed, watching actual RSS under load would turn that guess into a number.

## Not blocked on us

- **`uinput`, for `client-stream/` only**, and without it that architecture is
  view-only. Nothing here to add to `remote-browser/stream/NODE-REQUIREMENTS.md`'s
  own case for it; the argument does not change for a game.

## Considered and dropped

**Waypipe, for `client-stream/`.** The question that started this: whether
`remote-browser/waypipe`'s architecture — no encoder, cost proportional to what
changes on screen — fits a game better than GameStream does. It is the wrong
tool for the opposite of the reason it is the right one for a mostly-still
browser page: Minecraft is close to full-screen motion continuously, the
worst case `remote-browser`'s own README describes for damage-proportional
forwarding and the best case it describes for a transport that costs the same
whether the screen is still or not. `stream/`'s shape was chosen before any
code was written, on that comparison alone.

**Publishing 25565 in `client-stream/` too, so a second real player could join
alongside the streamed one.** Would turn the bundled server's fixed
`online-mode=false` into the same griefing exposure `server/`'s README already
warns about for an unwhitelisted server, and reintroduces the whitelist/ops
configuration surface this architecture was deliberately built without. If
that turns out to be wanted, it is `server/` with a second, thinner
`client-stream`-like sibling watching the same world, not a flag on this one.
