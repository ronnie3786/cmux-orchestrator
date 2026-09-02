import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.fleet import FleetError, FleetManager
from herdr_harness.server import HTTPValidationError, make_handler


class FleetBackendTests(unittest.TestCase):
    """Hermetic coverage for catalog trust, inventory, and filesystem actions."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.home = root / "home"
        self.home.mkdir()
        self.repo = root / "catalog"
        self.repo.mkdir()
        self._write_catalog()
        self._git("init", "-b", "main", str(self.repo))
        self._git("-C", str(self.repo), "config", "user.email", "fleet-tests@example.invalid")
        self._git("-C", str(self.repo), "config", "user.name", "Fleet Tests")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", "catalog")
        self._git("-C", str(self.repo), "remote", "add", "origin", str(self.repo))
        self.bin = root / "bin"
        self.bin.mkdir()
        self._write_executable("slack")
        self.environ = dict(os.environ)
        self.environ.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.bin}:{os.environ.get('PATH', '')}",
                "HERDR_FLEET_CATALOG_REPOSITORY": str(self.repo),
                "HERDR_FLEET_TEST_MODE": "1",
                "HERDR_FLEET_CHECKOUT_PATH": str(self.home / "managed-catalog"),
                "HERDR_FLEET_STATE_PATH": str(self.home / "state.json"),
                "HERDR_FLEET_QUARANTINE_PATH": str(self.home / "quarantine"),
            }
        )

    @staticmethod
    def _git(*args):
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True)

    def _write_catalog(self):
        (self.repo / "skills" / "personal" / "foo").mkdir(parents=True)
        (self.repo / "skills" / "personal" / "foo" / "SKILL.md").write_text("foo-v1\n", encoding="utf-8")
        (self.repo / "skills" / "work" / "external").mkdir(parents=True)
        (self.repo / "skills" / "work" / "external" / "SKILL.md").write_text("external\n", encoding="utf-8")
        (self.repo / "skills" / ".config").mkdir(parents=True)
        (self.repo / "skills" / ".config" / "classifications.json").write_text(
            json.dumps({"foo": "personal", "external": "external"}), encoding="utf-8"
        )
        (self.repo / "pi-extensions" / "package").mkdir(parents=True)
        (self.repo / "pi-extensions" / "package" / "index.ts").write_text("export {};\n", encoding="utf-8")
        (self.repo / "fleet.json").write_text(
            json.dumps(
                {
                    "skillGroups": [
                        {
                            "id": "personal",
                            "path": "skills/personal",
                            "destination": "~/.agents/skills",
                            "classification": "personal",
                            "writable": True,
                            "discovery": "direct-child-directories",
                            "scanDepth": 1,
                            "targetPolicy": "flat",
                        },
                        {
                            "id": "work",
                            "path": "skills/work",
                            "destination": "~/.agents/skills",
                            "classification": "work",
                            "writable": True,
                            "discovery": "direct-child-directories",
                            "scanDepth": 1,
                            "targetPolicy": "flat",
                        },
                    ],
                    "schemaVersion": 1,
                    "catalogId": "herdr-fleet",
                    "piExtensions": {
                        "path": "pi-extensions",
                        "destination": "~/.pi/agent/extensions",
                        "entries": [{"id": "pi-package", "path": "package/", "kind": "directory"}],
                    },
                    "cliCatalog": [
                        {
                            "id": "slack",
                            "adapter": "inventory",
                            "command": ["slack"],
                            "authCheck": True,
                            "authArgv": ["slack", "auth", "list", "--no-color", "--skip-update"],
                            "readOnlyChecks": [
                                {
                                    "command": ["slack"],
                                    "args": ["auth", "list", "--no-color", "--skip-update"],
                                    "timeoutSeconds": 5,
                                    "readOnly": True,
                                    "outputPolicy": "discard",
                                }
                            ],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def _write_executable(self, name):
        path = self.bin / name
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def manager(self):
        return FleetManager(environ=self.environ)

    def sync_manager(self):
        manager = self.manager()
        result = manager.sync()
        self.assertTrue(result["ok"])
        return manager

    def test_inventory_is_read_only_and_catalog_shape_is_safe(self):
        manager = self.manager()
        before = sorted(self.home.rglob("*"))
        response = manager.inventory()
        self.assertEqual(response["catalog"]["state"], "notSynced")
        self.assertTrue(all(item["type"] in {"pi_extension", "cli"} for item in response["items"]))
        self.assertEqual(sorted(self.home.rglob("*")), before)

        manager = self.sync_manager()
        response = manager.inventory()
        self.assertEqual(response["catalog"]["itemCounts"], {"skills": 2, "piExtensions": 1, "cli": 1})
        self.assertNotIn("repository", response)
        self.assertNotIn("checkout", response)
        self.assertNotIn("hostname", response.get("machine", {}))
        package = next(item for item in response["piExtensions"] if item["id"] == "pi-package")
        self.assertEqual(package["target"], "~/.pi/agent/extensions/package")

    def test_root_skill_symlink_is_resolved_and_external_target_is_read_only(self):
        resolved = self.home / ".config" / "dox-agent" / "skills"
        resolved.mkdir(parents=True)
        (self.home / ".agents").mkdir()
        (self.home / ".agents" / "skills").symlink_to(resolved, target_is_directory=True)
        external_target = resolved / "external"
        external_target.symlink_to(self.repo / "skills" / "work" / "external", target_is_directory=True)

        manager = self.sync_manager()
        external = manager.inventory()["items"]
        external = next(item for item in external if item["id"] == "skill:work/external")
        self.assertEqual(external["ownership"], "external")
        self.assertFalse(external["managed"])
        self.assertFalse(external["installable"])
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:work/external", "install")
        self.assertEqual(raised.exception.code, "fleet_action_forbidden")

    def test_install_adopt_update_and_remove_use_quarantine(self):
        manager = self.sync_manager()
        target_root = manager.skills_root
        target = target_root / "foo"

        installed = manager.action("skill:personal/foo", "install")
        self.assertEqual(installed["item"]["status"], "current")
        self.assertTrue(installed["item"]["managed"])
        self.assertEqual(target.joinpath("SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

        # A changed catalog source makes the old recorded digest outdated.
        source = self.repo / "skills" / "personal" / "foo" / "SKILL.md"
        source.write_text("foo-v2\n", encoding="utf-8")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", "catalog update")
        manager.sync()
        old_state = manager.inventory()
        old_item = next(item for item in old_state["items"] if item["id"] == "skill:personal/foo")
        self.assertEqual(old_item["status"], "outdated")

        updated = manager.action("skill:personal/foo", "update")
        self.assertEqual(updated["item"]["status"], "current")
        quarantine = manager.quarantine_root
        old_copies = [path for path in quarantine.iterdir() if path.is_dir()]
        self.assertTrue(old_copies)
        self.assertIn("foo-v1\n", [path.joinpath("SKILL.md").read_text(encoding="utf-8") for path in old_copies])
        self.assertEqual(target.joinpath("SKILL.md").read_text(encoding="utf-8"), "foo-v2\n")

        manager.action("skill:personal/foo", "remove")
        self.assertFalse(target.exists())
        all_copies = [path for path in quarantine.iterdir() if path.is_dir()]
        self.assertGreaterEqual(len(all_copies), 2)
        self.assertEqual(stat.S_IMODE(quarantine.stat().st_mode), 0o700)
        self.assertIn("foo-v2\n", [path.joinpath("SKILL.md").read_text(encoding="utf-8") for path in all_copies])

    def test_production_rejects_local_repository_override(self):
        production_environment = dict(self.environ)
        production_environment.pop("HERDR_FLEET_TEST_MODE", None)
        with self.assertRaises(FleetError) as raised:
            FleetManager(environ=production_environment)
        self.assertEqual(raised.exception.code, "invalid_catalog_repository")

    def test_inventory_and_actions_reject_dirty_or_ignored_checkout(self):
        manager = self.sync_manager()
        exclude = manager.checkout / ".git" / "info" / "exclude"
        with exclude.open("a", encoding="utf-8") as handle:
            handle.write("fleet-ignored.txt\n")
        (manager.checkout / "fleet-ignored.txt").write_text("not catalog state\n", encoding="utf-8")
        inventory = manager.inventory()
        self.assertEqual(inventory["catalog"]["state"], "unavailable")
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "install")
        self.assertEqual(raised.exception.code, "catalog_dirty")

    def test_inventory_and_actions_reject_clean_stale_checkout(self):
        manager = self.sync_manager()
        self._git("-C", str(manager.checkout), "config", "user.email", "fleet-tests@example.invalid")
        self._git("-C", str(manager.checkout), "config", "user.name", "Fleet Tests")
        self._git("-C", str(manager.checkout), "commit", "--allow-empty", "-m", "local commit")
        inventory = manager.inventory()
        self.assertEqual(inventory["catalog"]["state"], "unavailable")
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "install")
        self.assertEqual(raised.exception.code, "catalog_checkout_stale")

    def test_inventory_and_actions_reject_origin_ahead_of_local_head(self):
        manager = self.sync_manager()
        source = self.repo / "skills" / "personal" / "foo" / "SKILL.md"
        source.write_text("foo-v2\n", encoding="utf-8")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", "remote catalog update")
        # Refresh only the tracking ref.  Local main remains at the previous
        # revision, so a read must reject the clean but stale checkout.
        self._git("-C", str(manager.checkout), "fetch", "origin")
        inventory = manager.inventory()
        self.assertEqual(inventory["catalog"]["state"], "unavailable")
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "install")
        self.assertEqual(raised.exception.code, "catalog_checkout_stale")

    def test_failed_clone_only_cleans_unique_temporary_sibling(self):
        bad_repo = Path(self.temporary.name) / "not-a-git-repository"
        bad_repo.mkdir()
        target = self.home / "clone-target"
        environment = dict(self.environ)
        environment.update(
            {
                "HERDR_FLEET_CATALOG_REPOSITORY": str(bad_repo),
                "HERDR_FLEET_CHECKOUT_PATH": str(target),
            }
        )
        with self.assertRaises(FleetError) as raised:
            FleetManager(environ=environment).sync()
        self.assertEqual(raised.exception.code, "catalog_clone_failed")
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.glob(f".{target.name}.fleet-clone-*")), [])

    def test_cli_checks_require_discarding_read_only_policy_and_are_inventory_only(self):
        manager = self.manager()
        base = {
            "cliCatalog": [
                {
                    "id": "slack",
                    "adapter": "inventory",
                    "command": ["slack"],
                    "readOnlyChecks": [
                        {
                            "command": ["slack"],
                            "args": ["auth", "list", "--no-color", "--skip-update"],
                            "timeoutSeconds": 5,
                            "readOnly": True,
                            "outputPolicy": "discard",
                        }
                    ],
                }
            ]
        }
        item = manager._parse_catalog_items(self.repo, base)[0]
        self.assertFalse(item.writable)
        self.assertEqual(item.auth_argv, ("slack", "auth", "list", "--no-color", "--skip-update"))
        self.assertEqual(item.auth_timeout, 5.0)
        self.assertEqual(len(item.read_only_checks), 1)
        for invalid in (
            {"readOnly": False, "outputPolicy": "discard"},
            {"readOnly": True, "outputPolicy": "keep"},
            {"readOnly": True, "outputPolicy": "discard", "timeoutSeconds": 16},
            {"readOnly": True, "outputPolicy": "discard", "command": ["other"]},
            {"readOnly": True, "outputPolicy": "discard", "args": ["auth", "status"]},
        ):
            invalid_catalog = {"cliCatalog": [{**base["cliCatalog"][0], "readOnlyChecks": [{**base["cliCatalog"][0]["readOnlyChecks"][0], **invalid}]}]}
            with self.assertRaises(FleetError) as raised:
                manager._parse_catalog_items(self.repo, invalid_catalog)
            self.assertEqual(raised.exception.code, "catalog_invalid")

        mismatched = {
            "cliCatalog": [
                {
                    **base["cliCatalog"][0],
                    "authArgv": ["slack", "auth", "list"],
                }
            ]
        }
        with self.assertRaises(FleetError) as raised:
            manager._parse_catalog_items(self.repo, mismatched)
        self.assertEqual(raised.exception.code, "catalog_invalid")

        manager = self.sync_manager()
        slack = next(item for item in manager.inventory()["cli"] if item["id"] == "slack")
        self.assertFalse(slack["installable"])
        with self.assertRaises(FleetError) as raised:
            manager.action("slack", "install")
        self.assertEqual(raised.exception.code, "fleet_action_forbidden")

    def test_identical_unmanaged_copy_can_be_adopted_but_symlink_cannot(self):
        manager = self.sync_manager()
        manager.skills_root.mkdir(parents=True)
        target = manager.skills_root / "foo"
        target.mkdir()
        target.joinpath("SKILL.md").write_text("foo-v1\n", encoding="utf-8")
        adopted = manager.action("skill:personal/foo", "install")
        self.assertEqual(adopted["action"], "adopt")
        self.assertEqual(adopted["item"]["ownership"], "managed")
        manager.action("skill:personal/foo", "remove")
        self.assertFalse(target.exists())

        outside = self.home / "outside"
        outside.mkdir()
        target.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "install")
        self.assertEqual(raised.exception.code, "fleet_target_unmanaged")
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "remove")
        self.assertEqual(raised.exception.code, "fleet_target_unmanaged")

    def test_check_auth_alias_discards_output_and_returns_refreshed_item(self):
        manager = self.sync_manager()
        response = manager.action("slack", "auth_check")
        self.assertEqual(response["action"], "checkAuth")
        self.assertEqual(response["item"]["auth"]["status"], "ok")
        self.assertNotIn("stdout", response["item"])
        self.assertIn("items", response["inventory"])

    def test_route_exposes_fleet_contract_without_network(self):
        manager = self.sync_manager()
        service = SimpleNamespace(environ=self.environ, fleet=manager)
        handler = make_handler(service, api_token="fleet-test-token")
        response = handler._route(None, "GET", ["api", "v1", "fleet"], {}, {})
        self.assertEqual(response["ok"], True)
        self.assertIn("catalog", response)
        self.assertIn("items", response)

    def test_catalog_rejects_traversal_and_nested_symlinks(self):
        manager = self.manager()
        with self.assertRaises(FleetError) as raised:
            manager._parse_catalog_items(self.repo, {"skills": [{"path": "../escape"}]})
        self.assertEqual(raised.exception.code, "invalid_fleet_path")

        outside = self.home / "outside-source"
        outside.mkdir()
        (self.repo / "skills" / "personal" / "foo" / "linked").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(FleetError) as raised:
            manager._read_catalog(self.repo)
        self.assertEqual(raised.exception.code, "catalog_invalid")

    def test_route_rejects_unsupported_body_and_action(self):
        manager = self.sync_manager()
        service = SimpleNamespace(environ=self.environ, fleet=manager)
        handler = make_handler(service, api_token="fleet-test-token")
        with self.assertRaises(HTTPValidationError):
            handler._route(
                None,
                "POST",
                ["api", "v1", "fleet", "items", "skill:personal/foo", "action"],
                {},
                {"action": "install", "source": "ignored"},
            )
        with self.assertRaises(FleetError) as raised:
            manager.action("skill:personal/foo", "reinstall")
        self.assertEqual(raised.exception.code, "invalid_fleet_action")

    def test_exact_catalog_fixture_schema_when_available(self):
        fixture = Path(os.environ.get("HERDR_FLEET_EXACT_CATALOG_FIXTURE", "/private/tmp/herdr-fleet-personal-claude-plugin"))
        if not fixture.is_dir() or not (fixture / "fleet.json").is_file():
            self.skipTest("exact local Fleet fixture is not available")
        home = Path(self.temporary.name) / "exact-home"
        home.mkdir()
        manager = FleetManager(environ={"HOME": str(home), "HERDR_FLEET_CATALOG_PATH": str(fixture)})
        response = manager.inventory()
        self.assertEqual(response["catalog"]["itemCounts"], {"skills": 171, "piExtensions": 7, "cli": 7})
        self.assertEqual(len(response["items"]), 185)
        rocketbot = [item for item in response["skills"] if item["id"].startswith("skill:rocketbot/")]
        self.assertTrue(rocketbot)
        self.assertTrue(all(item["target"].startswith("~/.hermes/profiles/rocketbot/skills/") for item in rocketbot))

    def test_manifest_is_required_and_identity_is_strict(self):
        manager = self.manager()
        manifest = self.repo / "fleet.json"
        manifest.unlink()
        with self.assertRaises(FleetError) as raised:
            manager._read_catalog(self.repo)
        self.assertEqual(raised.exception.code, "catalog_invalid")


if __name__ == "__main__":
    unittest.main()
