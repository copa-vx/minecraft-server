# What `client-stream` needs

See the [top-level README](../README.md) for how this architecture relates to its
sibling, [`server/`](../server/), and [`TODO.md`](../TODO.md) for the one item
below that is a confirmed, open blocker rather than a design tradeoff.

## From the node

**Two symbols in the guest kernel, and without them this service is view-only** —
exactly [`remote-browser/stream`'s
requirement](https://github.com/celaut-basics/remote-browser/blob/main/stream/NODE-REQUIREMENTS.md),
for the same reason:

```
CONFIG_INPUT=y
CONFIG_INPUT_UINPUT=y
```

Sunshine injects mouse and keyboard through `/dev/uinput`. Without it Moonlight's
clicks and keystrokes go nowhere and this is a stream you can watch someone else's
character stand still in, not one you can play. See remote-browser's own
`NODE-REQUIREMENTS.md` for the full case; it does not repeat here because nothing
about it is specific to Minecraft.

**Nothing else.** No GPU, no `/dev/dri` — see "What this costs" below — and no
network egress at all: `service.json` declares `"network": []`.

## From the host

- **Moonlight, installed natively.** Same reasoning as `remote-browser/stream`: a
  native client decodes once and hands the frame to your own compositor, and
  Moonlight is packaged for Linux `arm64` nowhere, which is a reason to install it
  on the host rather than try to put it in an image.
- **Eight tunnels**, the same GameStream family `remote-browser/stream` needs,
  rebuilt locally:

```bash
for p in 47989 47984 47990 48010; do nodo tunnel <instance> $p --listen $p & done
for p in 47998 47999 48000 48002; do nodo tunnel <instance> $p --listen $p --udp & done
```

  With the same caveat `remote-browser` documents: datagrams through the tunnel
  become reliable and can head-of-line block, a non-issue on your own machine and
  a real cost against a remote node.

## Why this needs no Mojang account and no network egress

The bundled client never authenticates. It launches straight into the bundled
server via `--quickPlayMultiplayer 127.0.0.1:25565`, a loopback address nothing
outside this JVM can reach — there is no `api` slot for it, unlike `server/` — and
the bundled server always runs `online-mode=false`, so it never checks a
connecting client's identity against Mojang either. Nobody involved needs an
account, which is what was asked for when this architecture was designed: no
Microsoft login, no session check, ever.

**The client still tries.** On startup it makes a handful of best-effort calls —
`discovery.minecraftservices.com`, `api.minecraftservices.com` for "user
properties", `sessionserver.mojang.com` for a profile lookup — regardless of
whether it ever logs in, because that code path runs before anything checks
whether there is a real session to ask about. With `"network": []` these fail or
time out, and the client logs a `WARN`/`ERROR` for each and keeps going; nothing
here waits on them or treats them as fatal. Confirmed by running the client
against a network that refused every connection: it reached the render step
regardless. If a future Minecraft version makes one of these calls blocking, that
would show up as a longer, not permanent, startup stall — worth knowing before
assuming a hang is the render backend's fault instead.

## The open blocker: no OpenGL context under Xvfb

**Confirmed by actually running it**, on `linux/arm64`, with every package this
directory's `Dockerfile` pins:

```
[Render thread/ERROR]: Failed to create backend OpenGL
com.mojang.renderpearl.api.device.BackendCreationException: Failed to create window for OpenGL context: Couldn't find matching GLX visual
[Render thread/ERROR]: Failed to create backend Vulkan
com.mojang.renderpearl.api.device.BackendCreationException: Vulkan is not supported: Installed Vulkan doesn't implement the VK_KHR_surface extension
```

That message is SDL3's own (`X11_GL_GetVisual` in SDL's X11 backend), surfaced
through Mojang's `renderpearl` render-backend abstraction, this Minecraft
version's replacement for driving GLFW directly. What has been checked, in the
same container, against the same Xvfb:

- **Xvfb *can* provide a working software GL context.** `glxinfo -B` reports
  `direct rendering: Yes`, Mesa llvmpipe, OpenGL 4.5 core and compatibility —
  with `LIBGL_ALWAYS_SOFTWARE=1` and Xvfb started with `+extension GLX
  +extension RENDER` (without that flag pair the failure is immediate and total,
  a first thing to check if this regresses). `glxgears`, a real double-buffered,
  depth-buffered GLX client, runs on the same display without complaint.
- **The gap is narrower than "no GLX at all".** Something about the specific
  FBConfig SDL3 requests — most likely something `glxgears` does not ask for:
  an sRGB-capable framebuffer, a specific multisample or stencil combination, or
  a core-profile context flag — has no match among what Xvfb's built-in
  software GLX module advertises, and SDL surfaces that as "no visual" rather
  than naming the attribute that failed.
- **Vulkan is not a fallback here.** The image installs no Vulkan ICD at all
  (there is no hardware to back one), so `renderpearl`'s Vulkan backend fails
  for an unrelated and expected reason; it was never going to be the way this
  works on a GPU-less guest.

What has **not** been tried, in the order most likely to be worth it:

1. **SDL's own verbose logging**, to get the actual rejected FBConfig attributes
   instead of the one-line summary. Mojang's logger appears to swallow SDL's
   internal log categories rather than forward them; getting past that may need
   `LD_PRELOAD`-ing a small shim on `SDL_LogMessage`, or a build of SDL3 with a
   different default log output.
2. **Xorg with the `dummy` video driver and `glamor`**, in place of Xvfb. Xvfb's
   GLX module is Xorg's original, legacy software path; glamor's is Mesa-backed
   and more likely to expose whatever modern FBConfig SDL3 wants — at the risk
   of glamor's own software fallback wanting a DRM render node this guest kernel
   does not have either (see "What this costs", below).
3. **VirtualGL** between the client and Xvfb, the standard answer to exactly this
   class of problem in cloud VDI: it intercepts GLX calls and renders off-screen
   with a more complete software (or real) driver, then copies the frame into
   Xvfb's window. Adds a process and a moving part `remote-browser/stream` does
   not have.
4. Whatever `com.mojang.renderpearl.backend.opengl.GlDevice` actually requests —
   not available without decompiling the client jar, which nobody has done for
   this investigation.

Until one of these closes the gap, `client-stream` boots its server, its display,
its audio, and Sunshine correctly, and the client itself exits at the point above
a few seconds later — Sunshine keeps streaming a black Xvfb with nothing drawn to
it. See [`TODO.md`](../TODO.md).

## What this costs, which `server/` does not pay at all

**No GPU**, the same fact `remote-browser` documents for its own `stream/`:
`celaut.Sysresources` has no accelerator field, so no service on this network can
ask a node for one, and the guest kernel's `# CONFIG_DRM is not set` means there
is no `/dev/dri` even to fall back from. Once the blocker above is resolved,
software rasterisation and software x264 encoding both run on the same CPU
budget this instance's `cpu_quota` allows, at the same time the JVM is
simulating the world — the honest target, going in, is a low resolution at a
modest, not a smooth, frame rate.

**Two JVMs instead of one.** `MINECRAFT_MEMORY` sizes the bundled server's heap,
exactly as in `server/`; `MINECRAFT_CLIENT_MEMORY` sizes the bundled client's.
Both are checked against this instance's `mem_limit` together, with room for
Xvfb, PulseAudio, and Sunshine's own buffers, before anything starts — see the
entrypoint's `check_memory_fits_cgroup`. Raise `mem_limit` in `service.json`'s
`resources` if either needs to grow.

## Status

All of this was run in a plain Docker container on `linux/arm64`, not yet
inside an actual `nodo` microVM — close enough to catch the bugs below, not
close enough to stand in for `CONFIG_INPUT`/`uinput` behavior, a real cgroup
`mem_limit`, or `nodo`'s own network isolation. `nodo pack`ing and launching
this for real is what would close that gap.

**Confirmed to build and confirmed to run every process except the one that
matters**, as of 2026-09-20: the fetch stage, the arm64 LWJGL natives, the
bundled server (reaches `Done`, stops cleanly on `SIGTERM`), Xvfb (real
`direct rendering` llvmpipe, confirmed with `glxinfo`/`glxgears`), PulseAudio,
and Sunshine (correctly selects its software `libx264` encoder and starts
serving) were each individually verified working, together, in one running
instance. The client's render backend is the one piece that is not, and it is
why nobody has seen this stream a frame yet — see the blocker above.

**Found by actually running the whole stack together, and fixed, three bugs
none of the pieces would have shown in isolation:**

- Same as `server/`: everything `start_server` creates under `/data` before
  dropping to the `minecraft` user was root-owned, silently. Fixed the same way.
- The Sunshine `.deb` ships no `/etc/sunshine` of its own — `start_sunshine`'s
  `sunshine.conf` had nowhere to land until this added the `mkdir -p`.
- **`DISPLAY` was never exported for Sunshine's own process**, only passed to
  the client. Without it, Sunshine did not fail loudly or fall back to `x11`
  capture — it silently skipped past its own `capture = x11` config and probed
  `nvenc`, `vulkan`, then `vaapi` in turn, none of which exist in this microVM,
  and gave up with "Unable to find display or encoder during startup". This one
  is worth remembering on its own: a config value that is set and simply not
  honored, with no warning that it was ignored, is exactly the silent-drift
  shape `tests/test_manifest.py` exists to catch for the manifest and could not
  catch here, because nothing was wrong with the manifest.

Where to look first, beyond the render blocker above:

- Whether `openjdk-25-jre-headless`, the Sunshine release, and the Debian package
  versions this Dockerfile pins are still current — same caveat as `server/`.
- Whether Mojang has published Linux/arm64 LWJGL natives of its own by the time
  this is rebuilt, which would make the Maven Central fallback in
  `fetch-client.py` unnecessary rather than wrong.
- Whether `--quickPlayMultiplayer` is still this version's flag for skipping the
  multiplayer menu — it has existed since 1.20 but is not a documented, stable
  CLI interface.
