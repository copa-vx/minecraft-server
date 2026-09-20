"""service.json, checked against its own entrypoint.sh.

The two are written by hand and nothing joins them: `service.json` is what a node
reads to decide what it will accept and which ports it will open; `entrypoint.sh`
is what actually reads an env var or binds a port. They drift in both directions,
silently:

- Declared and never read -- an operator passes it at `nodo execute -e`, the node
  accepts it, and it changes nothing.
- Read and never declared -- the entrypoint has a knob the node will refuse to
  pass, so it is stuck at its default with no way to say otherwise.
- A slot declared on a port nothing binds -- a firewall hole with nobody behind it.
"""
import json
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `X=$(trim "${MINECRAFT_Y:-default}")`, `X="${MINECRAFT_Y:-default}"`, or the bare
# `"${MINECRAFT_Y}"` -- how this entrypoint takes a value from the environment. A
# mention inside a fail() message is plain text, not `${...}`, so it does not match.
_READ = re.compile(r'\$\{(MINECRAFT_[A-Z_]+)(?::-[^}]*)?\}')


def manifest():
    with open(os.path.join(ROOT, ".service", "service.json")) as handle:
        return json.load(handle)


def entrypoint():
    with open(os.path.join(ROOT, "service", "entrypoint.sh")) as handle:
        return handle.read()


class TestLayout(unittest.TestCase):
    def test_the_service_is_complete(self):
        for relative in (".service/service.json", ".service/pack_config.json",
                          ".service/Dockerfile", "service/entrypoint.sh",
                          "NODE-REQUIREMENTS.md", "README.md"):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, relative)),
                             f"missing {relative}")

    def test_entry_path_points_at_the_file_that_exists(self):
        entry = manifest()["init"]["entry_path"]
        self.assertTrue(
            os.path.isfile(os.path.join(ROOT, *entry)),
            f"init.entry_path {entry} is not a file in the tree. It packs fine "
            "and the instance can never start.",
        )


class TestEnvironment(unittest.TestCase):
    def test_everything_declared_is_read(self):
        declared = set(manifest().get("envs", []))
        read = set(_READ.findall(entrypoint()))
        unused = declared - read
        self.assertFalse(
            unused,
            f"declared in service.json and never read by entrypoint.sh: {sorted(unused)}. "
            "The node will accept these at `nodo execute -e` and they will change nothing.",
        )

    def test_everything_read_is_declared(self):
        declared = set(manifest().get("envs", []))
        read = set(_READ.findall(entrypoint()))
        undeclared = read - declared
        self.assertFalse(
            undeclared,
            f"read by entrypoint.sh and not declared in service.json: {sorted(undeclared)}. "
            "The node will refuse to pass these, so they are stuck at their defaults.",
        )


class TestSlot(unittest.TestCase):
    def test_exactly_one_slot_speaking_the_declared_port(self):
        slots = manifest()["api"]
        self.assertEqual(len(slots), 1, "expected exactly one slot")
        slot = slots[0]
        self.assertEqual(slot["transport"], "tcp")
        self.assertIn(
            f'SERVER_PORT={slot["port"]}', entrypoint().replace(" ", ""),
            f"slot {slot['port']} is declared and does not match SERVER_PORT in entrypoint.sh",
        )

    def test_server_properties_is_not_left_to_pick_its_own_port(self):
        # server.properties defaults server-port to 25565 on its own if the key is
        # missing; writing it explicitly is what keeps the manifest and the running
        # server from silently disagreeing on which port is actually open.
        self.assertIn("server-port=", entrypoint())


class TestEula(unittest.TestCase):
    def test_the_eula_is_refused_by_default_not_defaulted(self):
        # Mojang's EULA has to be an explicit, informed acceptance. A `:-true`
        # fallback here would accept it on the operator's behalf.
        self.assertNotRegex(entrypoint(), r'MINECRAFT_EULA:-true')


class TestNetwork(unittest.TestCase):
    def test_network_is_scoped_not_wildcarded(self):
        # This service's egress need is enumerable -- a fixed Mojang hostname --
        # unlike a browser's. A "*" here would be a regression to the easy answer.
        tags = [set(n.get("tags", [])) for n in manifest().get("network", [])]
        self.assertNotIn({"*"}, tags, "network egress widened to a wildcard")


if __name__ == "__main__":
    unittest.main()
