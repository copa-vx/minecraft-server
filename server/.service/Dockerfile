# Content-addressed: two packs of the same tree must produce the same image, so the
# base is pinned by digest, the JRE by its exact Debian version, and the server jar by
# the sha1 Mojang's own version manifest publishes for it.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

#  openjdk-25-jre-headless   the runtime this build of the server asks for (Mojang's
#                            version manifest names java-runtime-epsilon, major 25).
#                            Headless because nothing here ever opens a display.
#  ca-certificates           only reached when MINECRAFT_ONLINE_MODE=true: the server
#                            calls sessionserver.mojang.com over HTTPS to check that a
#                            connecting client really authenticated with Mojang/Microsoft.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        openjdk-25-jre-headless=25.0.4.1+1-1~deb13u1 \
        ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*

# The server jar for 26.3, Mojang's latest release as of 2026-09-20. Verified against
# the sha1 in that version's own entry in version_manifest_v2.json -- not against a
# "latest" URL, which is exactly the kind of pointer that can serve something else
# tomorrow without this file changing.
ARG MINECRAFT_VERSION=26.3
ARG MINECRAFT_SERVER_SHA1=33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c
ADD https://piston-data.mojang.com/v1/objects/${MINECRAFT_SERVER_SHA1}/server.jar /srv/minecraft/server.jar
RUN echo "${MINECRAFT_SERVER_SHA1}  /srv/minecraft/server.jar" | sha1sum -c - \
    && useradd --create-home --home-dir /srv/minecraft --shell /usr/sbin/nologin minecraft \
    && mkdir -p /data \
    && chown -R minecraft:minecraft /srv/minecraft /data

COPY service /service
RUN chmod +x /service/entrypoint.sh
