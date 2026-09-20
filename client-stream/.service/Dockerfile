# Content-addressed, the same way server/Dockerfile and remote-browser/stream are:
# the base is pinned by digest, every apt package by its exact version, and every
# object this image did not get from Debian -- the server jar, the client jar, its
# libraries, its assets, Sunshine -- by the sha1 or sha256 its own publisher
# names for it. A build that drifted underneath any of those would change what
# runs without changing the hash anyone reviewed.
#
# Two stages. The first fetches ~600 MB and several thousand small files that
# nothing at runtime needs the tools to re-fetch; the second is what actually
# ships, and never sees a Python interpreter.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS fetch

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        python3=3.13.5-1 \
        ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*

# Same version as server/Dockerfile, on purpose: the bundled client and the
# bundled server have to speak the same protocol, and that is only guaranteed
# within one Minecraft release.
ARG MINECRAFT_VERSION=26.3

# The root of trust for everything fetch-client.py reads afterwards. Mojang's CDN
# paths are themselves content-addressed (.../v1/packages/<sha1>/<id>.json), so
# this one sha1 is what anchors the client jar, every library, and the asset
# index that the version json names -- transitively, the same way it anchors the
# server jar one file below. Re-derive it from
# https://piston-meta.mojang.com/mc/game/version_manifest_v2.json if
# MINECRAFT_VERSION ever moves.
ARG MINECRAFT_VERSION_JSON_URL=https://piston-meta.mojang.com/v1/packages/96c00d95a31328714d3811cfade2804bb050e455/26.3.json
ARG MINECRAFT_VERSION_JSON_SHA1=96c00d95a31328714d3811cfade2804bb050e455

COPY .service/fetch-client.py /tmp/fetch-client.py
RUN python3 /tmp/fetch-client.py \
      "${MINECRAFT_VERSION_JSON_URL}" "${MINECRAFT_VERSION_JSON_SHA1}" /opt/client


FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

#  openjdk-25-jre-headless   runs both the bundled server and the bundled client.
#                            Headless is not a display restriction on this JVM --
#                            LWJGL/SDL open their own native window independent of
#                            AWT -- it is one fewer thing on the classpath.
#  xvfb                      the X server the client renders into and Sunshine
#                            captures from. No CONFIG_DRM in the guest kernel, so
#                            there is no framebuffer device to hand a real Xorg;
#                            Xvfb allocates one in ordinary memory instead.
#  x11-utils                 xdpyinfo, so the entrypoint waits for the display to
#                            answer instead of sleeping and hoping.
#  libgl1-mesa-dri            software OpenGL. `# CONFIG_DRM is not set` in the
#  libglx-mesa0              guest kernel means no /dev/dri and nothing to
#  libgl1                    accelerate with; llvmpipe is what LIBGL_ALWAYS_SOFTWARE
#                            selects instead, and this is the same trade
#                            remote-browser/stream makes for Chromium.
#  libx11-6, libxext6,       what the client's window and input layer (SDL3, in
#  libxrandr2, libxinerama1, this Minecraft version) links against on X11. None of
#  libxcursor1, libxi6,      these touch the network or a device node; they are
#  libxxf86vm1               ordinary client-side X libraries.
#  pulseaudio                a *userspace* null sink, exactly like
#                            remote-browser/stream: `# CONFIG_SOUND is not set` in
#                            the guest kernel, so there is no ALSA device to open,
#                            but module-null-sink never wants one.
#  ca-certificates           the bundled client still talks to Mojang's telemetry
#                            and account-services hosts on startup even when it
#                            never authenticates; see client-stream/README.md.
#  curl                      fetches the Sunshine package below, and nothing at
#                            runtime.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        openjdk-25-jre-headless=25.0.4.1+1-1~deb13u1 \
        xvfb=2:21.1.16-1.3+deb13u4 \
        x11-utils=7.7+7 \
        libgl1-mesa-dri=25.0.7-2+deb13u1 \
        libglx-mesa0=25.0.7-2+deb13u1 \
        libgl1=1.7.0-1+b2 \
        libx11-6=2:1.8.12-1 \
        libxext6=2:1.3.4-1+b3 \
        libxrandr2=2:1.5.4-1+b3 \
        libxinerama1=2:1.1.4-3+b4 \
        libxcursor1=1:1.2.3-1 \
        libxi6=2:1.8.2-1 \
        libxxf86vm1=1:1.1.4-1+b4 \
        pulseaudio=17.0+dfsg1-2+b1 \
        ca-certificates=20250419 \
        curl=8.14.1-2+deb13u5 \
    && rm -rf /var/lib/apt/lists/*

# Sunshine, pinned by version AND by the sha256 GitHub publishes for that asset --
# the same release remote-browser/stream already verified and runs. Not in
# Debian, so it arrives over the network at build time, which is exactly the
# input that has to be nailed down for the image to stay reproducible.
#
# GPL-3.0. It is the GameStream host: it captures the X display, encodes it, and
# speaks the protocol Moonlight speaks.
ARG SUNSHINE_VERSION=2026.914.233613
ARG SUNSHINE_SHA256=45f250a6bae3629bd67d6856356e5d838569fbe4f6128440124c727a3d5fef5e
RUN curl -fsSL -o /tmp/sunshine.deb \
      "https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine_${SUNSHINE_VERSION}-1%2Bdebiantrixie_arm64.deb" \
    && echo "${SUNSHINE_SHA256}  /tmp/sunshine.deb" | sha256sum -c - \
    && apt-get update \
    && apt-get install --no-install-recommends -y /tmp/sunshine.deb \
    && rm -f /tmp/sunshine.deb \
    && rm -rf /var/lib/apt/lists/*

# The dedicated server jar this instance's client plays against -- same version,
# same verification, as server/Dockerfile.
ARG MINECRAFT_VERSION=26.3
ARG MINECRAFT_SERVER_SHA1=33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c
ADD https://piston-data.mojang.com/v1/objects/${MINECRAFT_SERVER_SHA1}/server.jar /srv/minecraft/server.jar
RUN echo "${MINECRAFT_SERVER_SHA1}  /srv/minecraft/server.jar" | sha1sum -c -

# The client: jar, libraries (Mojang's plus the arm64 natives fetch-client.py adds
# from LWJGL's own Maven Central releases -- see that script), and assets, built
# in the `fetch` stage above and copied over verified, with nothing left behind
# that fetched them.
COPY --from=fetch /opt/client /srv/minecraft/client

RUN useradd --create-home --home-dir /home/minecraft --shell /usr/sbin/nologin minecraft \
    && mkdir -p /data /run/pulse \
    && chown -R minecraft:minecraft /srv/minecraft /data /home/minecraft

COPY service /service
RUN chmod +x /service/entrypoint.sh
