#!/usr/bin/env python3
"""Fetch the Minecraft Java client (jar, linux libraries, assets) named by a
pinned version-manifest sha1, verifying every object against the sha1 the
manifest itself publishes for it. Mirrors what the official launcher does at
install time; run once, at image build time, not at container start.

Trust runs from one root: MINECRAFT_VERSION_JSON_SHA1. Mojang's CDN paths are
themselves content-addressed (.../v1/packages/<sha1>/<id>.json), so fetching
that URL and checking the response hashes to the pinned sha1 is what anchors
everything this script reads out of the document afterwards -- library and
asset hashes included, transitively, the same way a lockfile's root hash
anchors the tree under it.
"""
import concurrent.futures
import hashlib
import json
import os
import sys
import urllib.request

WORKERS = 24


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, dest, expected_sha1, expected_size=None):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) == (expected_size or -1) and sha1_of(dest) == expected_sha1:
        return
    tmp = dest + ".part"
    with urllib.request.urlopen(url, timeout=60) as resp, open(tmp, "wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    got = sha1_of(tmp)
    if got != expected_sha1:
        os.remove(tmp)
        raise SystemExit(f"sha1 mismatch for {url}: expected {expected_sha1}, got {got}")
    os.replace(tmp, dest)


def rule_allows_linux(rules):
    """Mojang's own algorithm: no rules => allow. Otherwise the last matching
    rule wins, and the default when rules exist is disallow."""
    verdict = False
    for rule in rules:
        os_match = "os" not in rule or rule["os"].get("name") == "linux"
        if os_match:
            verdict = rule["action"] == "allow"
    return verdict


# Mojang's own manifest ships linux natives for x64 only -- Linux/arm64 is not one
# of the platforms Mojang tests or ships for, unlike Windows/arm64 and macOS/arm64
# (both present in the same manifest). LWJGL itself does not share that gap: the
# upstream project builds and publishes a natives-linux-arm64 classifier for every
# module below, straight to Maven Central. Added alongside Mojang's x64 jars, not
# instead of them -- LWJGL's own loader picks the file matching the JVM's actual
# os.arch out of whatever is on the classpath, so carrying both costs bytes and
# nothing else.
MAVEN_CENTRAL = "https://repo1.maven.org/maven2"
LWJGL_ARM64_MODULES = [
    "lwjgl", "lwjgl-freetype", "lwjgl-jemalloc", "lwjgl-openal", "lwjgl-opengl",
    "lwjgl-sdl", "lwjgl-shaderc", "lwjgl-spvc", "lwjgl-stb", "lwjgl-vma",
]


def fetch_maven_central_arm64_natives(out_dir, version):
    jobs = []
    for module in LWJGL_ARM64_MODULES:
        base = f"{MAVEN_CENTRAL}/org/lwjgl/{module}/{version}/{module}-{version}-natives-linux-arm64.jar"
        with urllib.request.urlopen(base + ".sha1", timeout=30) as resp:
            expected = resp.read().decode().strip().split()[0]
        dest = os.path.join(out_dir, "libraries", "org", "lwjgl", module, version,
                             f"{module}-{version}-natives-linux-arm64.jar")
        jobs.append((base, dest, expected, None))
    return jobs


def main():
    version_json_url = sys.argv[1]
    expected_sha1 = sys.argv[2]
    out_dir = sys.argv[3]

    version_json_path = os.path.join(out_dir, "version.json")
    fetch(version_json_url, version_json_path, expected_sha1)
    with open(version_json_path) as f:
        version = json.load(f)

    jobs = []

    client = version["downloads"]["client"]
    client_path = os.path.join(out_dir, "client.jar")
    jobs.append((client["url"], client_path, client["sha1"], client["size"]))

    lib_paths = []
    for lib in version["libraries"]:
        if "rules" in lib and not rule_allows_linux(lib["rules"]):
            continue
        artifact = lib.get("downloads", {}).get("artifact")
        if not artifact:
            continue
        dest = os.path.join(out_dir, "libraries", artifact["path"])
        jobs.append((artifact["url"], dest, artifact["sha1"], artifact["size"]))
        lib_paths.append(artifact["path"])

    lwjgl_version = next(
        lib["name"].split(":")[2] for lib in version["libraries"]
        if lib["name"].startswith("org.lwjgl:lwjgl:")
    )
    for url, dest, sha1, size in fetch_maven_central_arm64_natives(out_dir, lwjgl_version):
        jobs.append((url, dest, sha1, size))
        lib_paths.append(os.path.relpath(dest, os.path.join(out_dir, "libraries")))

    asset_index = version["assetIndex"]
    index_path = os.path.join(out_dir, "assets", "indexes", f"{asset_index['id']}.json")
    fetch(asset_index["url"], index_path, asset_index["sha1"], asset_index["size"])
    with open(index_path) as f:
        objects = json.load(f)["objects"]

    for obj in objects.values():
        h = obj["hash"]
        dest = os.path.join(out_dir, "assets", "objects", h[:2], h)
        url = f"https://resources.download.minecraft.net/{h[:2]}/{h}"
        jobs.append((url, dest, h, obj["size"]))

    print(f"fetching {len(jobs)} objects ({sum(j[3] or 0 for j in jobs) / 1e6:.1f} MB) with {WORKERS} workers",
          file=sys.stderr)

    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(fetch, url, dest, sha1, size): url for url, dest, sha1, size in jobs}
        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            url = futures[future]
            try:
                future.result()
            except Exception as exc:  # noqa: BLE001 -- reported, not swallowed
                failures.append((url, exc))
            if i % 200 == 0 or i == len(jobs):
                print(f"  {i}/{len(jobs)}", file=sys.stderr)

    if failures:
        for url, exc in failures:
            print(f"FAILED {url}: {exc}", file=sys.stderr)
        raise SystemExit(f"{len(failures)} object(s) failed")

    with open(os.path.join(out_dir, "libraries.classpath"), "w") as f:
        f.write(":".join(os.path.join("libraries", p) for p in lib_paths))

    # The entrypoint needs the version id for --version and the client jar itself
    # has no reliable way to report it before it is running; writing it once here,
    # from the same trusted document, is simpler than re-parsing version.json in
    # bash at container start.
    with open(os.path.join(out_dir, "version-id"), "w") as f:
        f.write(version["id"])

    print("mainClass:", version["mainClass"])
    print("assetIndex id:", asset_index["id"])
    print("libraries:", len(lib_paths))
    print("assets:", len(objects))


if __name__ == "__main__":
    main()
