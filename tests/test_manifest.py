"""Each service's manifest, checked against its own entrypoint.

Two services, one shape, following celaut-basics/remote-browser's own top-level
tests: `service.json` declares what a node will accept and which ports it will
open; `entrypoint.sh` decides what is actually read and bound; nothing joins the
two, and they drift in both directions, silently.

- Declared and never read -- an operator passes it at `nodo execute -e`, the node
  accepts it, and it changes nothing.
- Read and never declared -- the entrypoint has a knob the node will refuse to
  pass, so it is stuck at its default with no way to say otherwise.
- A slot declared on a port nothing binds -- a firewall hole with nobody behind it.

None of these produces an error anywhere. They produce a service that quietly
ignores its own manifest, which is the same shape of failure as a network
declaration that has quietly widened: the manifest is what somebody reads to
decide what this thing does, and it is wrong.
"""
import json
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = ("server", "client-stream")

# Two shapes an environment read takes in these entrypoints:
#   MINECRAFT_X anywhere as `${MINECRAFT_X}` or `${MINECRAFT_X:-default}` -- these
#   are always wrapped (`X=$(trim "${MINECRAFT_X:-...}")`), so the name at the
#   assignment site does not have to match the one inside the braces.
#   Anything else, only when it is its own default: `NAME="${NAME:-default}"` or
#   `NAME="${NAME}"`, the shape every non-MINECRAFT_ variable in these two
#   entrypoints actually uses -- which is also what keeps this from matching an
#   ordinary local variable like `"${LOGS}/xvfb.log"` as if it were an environment
#   read.
_READ = re.compile(
    r'\$\{(MINECRAFT_[A-Z_]+)(?::-[^}]*)?\}'
    r'|^[ \t]*([A-Z_][A-Z0-9_]*)="\$\{\2(?::-[^}]*)?\}"',
    re.MULTILINE,
)


def manifest(service):
    with open(os.path.join(ROOT, service, ".service", "service.json")) as handle:
        return json.load(handle)


def entrypoint(service):
    with open(os.path.join(ROOT, service, "service", "entrypoint.sh")) as handle:
        return handle.read()


def read_envs(service):
    return {a or b for a, b in _READ.findall(entrypoint(service))}


class TestLayout(unittest.TestCase):
    def test_each_service_is_complete(self):
        for service in SERVICES:
            for relative in (".service/service.json", ".service/pack_config.json",
                              ".service/Dockerfile", "service/entrypoint.sh",
                              "NODE-REQUIREMENTS.md", "README.md"):
                path = os.path.join(ROOT, service, relative)
                self.assertTrue(os.path.isfile(path), f"{service}: missing {relative}")

    def test_entry_path_points_at_the_file_that_exists(self):
        for service in SERVICES:
            entry = manifest(service)["init"]["entry_path"]
            self.assertTrue(
                os.path.isfile(os.path.join(ROOT, service, *entry)),
                f"{service}: init.entry_path {entry} is not a file in the tree. "
                "It packs fine and the instance can never start.",
            )


class TestEnvironment(unittest.TestCase):
    def test_everything_declared_is_read(self):
        for service in SERVICES:
            declared = set(manifest(service).get("envs", []))
            unused = declared - read_envs(service)
            self.assertFalse(
                unused,
                f"{service}: declared in service.json and never read by entrypoint.sh: "
                f"{sorted(unused)}. The node will accept these at `nodo execute -e` "
                "and they will change nothing.",
            )

    def test_everything_read_is_declared(self):
        for service in SERVICES:
            declared = set(manifest(service).get("envs", []))
            undeclared = read_envs(service) - declared
            self.assertFalse(
                undeclared,
                f"{service}: read by entrypoint.sh and not declared in service.json: "
                f"{sorted(undeclared)}. The node will refuse to pass these, so they "
                "are stuck at their defaults.",
            )


class TestEula(unittest.TestCase):
    def test_the_eula_is_refused_by_default_not_defaulted(self):
        # Mojang's EULA has to be an explicit, informed acceptance, in both
        # architectures -- client-stream bundles a server exactly as server/ is
        # one. A `:-true` fallback here would accept it on the operator's behalf.
        for service in SERVICES:
            self.assertNotRegex(entrypoint(service), r'MINECRAFT_EULA:-true',
                                 f"{service}: EULA has a default of true")


class TestSlots(unittest.TestCase):
    def test_no_port_is_declared_twice_on_one_transport(self):
        for service in SERVICES:
            declared = [(s["port"], s["transport"]) for s in manifest(service)["api"]]
            self.assertEqual(len(declared), len(set(declared)), f"{service}: duplicate slot")

    def test_server_has_exactly_one_slot_matching_its_port(self):
        slots = manifest("server")["api"]
        self.assertEqual(len(slots), 1, "server: expected exactly one slot")
        slot = slots[0]
        self.assertEqual(slot["transport"], "tcp")
        self.assertIn("minecraft", slot["protocol"])
        self.assertIn(
            f'SERVER_PORT={slot["port"]}', entrypoint("server").replace(" ", ""),
            f"server: slot {slot['port']} is declared and does not match "
            "SERVER_PORT in entrypoint.sh",
        )

    def test_server_properties_is_not_left_to_pick_its_own_port(self):
        self.assertIn("server-port=", entrypoint("server"))

    def test_client_stream_declares_no_slot_for_its_own_bundled_server(self):
        # The whole point of client-stream is that nobody needs a Minecraft
        # client of their own to use it -- an api slot for its internal server
        # would be a second, worse way in, for the one player already watching
        # the stream. See client-stream/README.md.
        for slot in manifest("client-stream")["api"]:
            self.assertNotEqual(slot["port"], 25565,
                                 "client-stream: 25565 is published; it should "
                                 "only ever be reachable from inside the instance")

    def test_the_gamestream_family_matches_the_base_in_the_entrypoint(self):
        # Moonlight does not discover ports, it derives them from one base by
        # fixed offsets -- exactly remote-browser/stream's own test, reused here
        # because client-stream generates its sunshine.conf the same way.
        found = re.search(r"^port = (\d+)$", entrypoint("client-stream"), re.MULTILINE)
        self.assertIsNotNone(found, "client-stream: no `port =` base in the generated sunshine.conf")
        base = int(found.group(1))
        slots = {(s["port"], s["transport"]) for s in manifest("client-stream")["api"]}
        for offset, what in ((0, "HTTP"), (-5, "HTTPS"), (1, "web API"), (21, "RTSP")):
            self.assertIn((base + offset, "tcp"), slots,
                          f"client-stream: base{offset:+d} ({base + offset}/tcp, {what}) is not declared")
        for offset, what in ((9, "video"), (10, "control"), (11, "audio"), (13, "mic")):
            self.assertIn((base + offset, "udp"), slots,
                          f"client-stream: base{offset:+d} ({base + offset}/udp, {what}) is not declared")


class TestNetwork(unittest.TestCase):
    def test_neither_service_widens_to_a_wildcard(self):
        # Unlike remote-browser, where an open destination is the honest
        # statement of what a browser is, both of these have an enumerable (or
        # empty) egress need. A "*" here would be a regression to the easy answer.
        for service in SERVICES:
            tags = [set(n.get("tags", [])) for n in manifest(service).get("network", [])]
            self.assertNotIn({"*"}, tags, f"{service}: network egress widened to a wildcard")

    def test_client_stream_declares_no_egress_at_all(self):
        # The bundled client is always offline and the bundled server is always
        # online-mode=false; see client-stream/NODE-REQUIREMENTS.md for why that
        # adds up to zero declared network need, not just a narrow one.
        self.assertEqual(manifest("client-stream").get("network", []), [])


if __name__ == "__main__":
    unittest.main()
