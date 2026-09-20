# What each architecture needs

Each service directory has its own `NODE-REQUIREMENTS.md`; this is the index.

| | from the node | from the host |
|---|---|---|
| [`server/`](server/NODE-REQUIREMENTS.md) | a persistent disk; egress to `sessionserver.mojang.com` if `MINECRAFT_ONLINE_MODE=true` | your own Minecraft: Java Edition client; `nodo tunnel` if not publishing 25565 |
| [`client-stream/`](client-stream/NODE-REQUIREMENTS.md) | `CONFIG_INPUT=y` + `CONFIG_INPUT_UINPUT=y`, **or it is view-only**; nothing else | Moonlight installed natively, and eight tunnels — same family `remote-browser/stream` needs |

Read together they say the same thing [`remote-browser`'s own index
says](https://github.com/celaut-basics/remote-browser/blob/main/NODE-REQUIREMENTS.md):
the only architecture here that needs a **capability** from the node needs it for
*input*, not for pixels or for the world. `server/` needs a disk because a world
is the one thing worth this service running twice for; `client-stream/` needs
none, because the only state it holds is a byproduct of playing, not the reason
anyone launched it.

## What neither one asks for

**A GPU.** `celaut.Sysresources` is `blkio_weight`, `cpu_period`, `cpu_quota`,
`mem_limit` and `disk_space` — no accelerator field, and no way to declare that
an instance needs one, the same fact `remote-browser` is built around. `server/`
never needed one; `client-stream/` renders and encodes in software for exactly
the reason Chromium does in `remote-browser/stream`.

**A Mojang account, in `client-stream/`.** The bundled client never
authenticates and the bundled server never checks — see its own
`NODE-REQUIREMENTS.md` for what that costs and what it still tries regardless.

## Where this differs from `remote-browser`

`remote-browser` built three architectures around one question — where the
pixels are compressed, and by what — because a browser is both the best and
worst case for that tradeoff depending on what is on screen. A game is a
worse case than a browser scrolling: it is full-screen motion nearly all the
time, which is exactly the condition under which `remote-browser`'s own README
recommends its `stream/` architecture over `waypipe/`'s damage-proportional
cost. That comparison is why `client-stream/` exists in this shape at all,
rather than a Wayland-forwarding one; see the top-level README's "why two" for
how it was decided.
