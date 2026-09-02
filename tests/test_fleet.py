import hashlib
import errno
import json
import os
import platform
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import herdr_harness.fleet as fleet_module
from herdr_harness.fleet import FleetError, FleetManager, _run_command, _tree_digest, _which
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
        self._write_executable("acli")
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
                        },
                        {
                            "id": "acli",
                            "adapter": "inventory",
                            "command": ["acli"],
                            "authCheck": True,
                            "authArgv": ["acli", "jira", "auth", "status"],
                            "readOnlyChecks": [
                                {
                                    "command": ["acli"],
                                    "args": ["jira", "auth", "status"],
                                    "timeoutSeconds": 5,
                                    "readOnly": True,
                                    "outputPolicy": "discard",
                                }
                            ],
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )

    def _write_executable(self, name):
        path = self.bin / name
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    @staticmethod
    def _write_executable_at(path, contents="#!/bin/sh\nexit 0\n"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def manager(self):
        return FleetManager(environ=self.environ)

    def _implicit_environment(self):
        environment = dict(self.environ)
        for name in (
            "HERDR_FLEET_CATALOG_PATH",
            "HERDR_FLEET_CHECKOUT_PATH",
            "HERDR_FLEET_REPO_PATH",
        ):
            environment.pop(name, None)
        return environment

    def _clone_checkout(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._git("clone", str(self.repo), str(path))
        return path

    def _add_accidental_gitlink(self):
        """Add a gitlink without .gitmodules, matching the real regression."""

        subrepo = Path(self.temporary.name) / "accidental-skill-repo"
        subrepo.mkdir()
        self._git("init", "-b", "main", str(subrepo))
        self._git("-C", str(subrepo), "config", "user.email", "fleet-tests@example.invalid")
        self._git("-C", str(subrepo), "config", "user.name", "Fleet Tests")
        (subrepo / "SKILL.md").write_text("accidental gitlink\n", encoding="utf-8")
        self._git("-C", str(subrepo), "add", ".")
        self._git("-C", str(subrepo), "commit", "-m", "accidental skill")
        revision = self._git("-C", str(subrepo), "rev-parse", "HEAD").stdout.strip()
        self._git(
            "-C",
            str(self.repo),
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{revision},skills/work/accidental-gitlink",
        )
        self._git("-C", str(self.repo), "commit", "-m", "record accidental gitlink")
        return subrepo, revision

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
        self.assertEqual(response["catalog"]["itemCounts"], {"skills": 2, "piExtensions": 1, "cli": 2})
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
        synced = manager.sync()
        self.assertEqual(synced["reconciliation"]["updated"], 1)
        old_state = manager.inventory()
        old_item = next(item for item in old_state["items"] if item["id"] == "skill:personal/foo")
        self.assertEqual(old_item["status"], "current")

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

    def _commit_catalog_change(self, relative_path, contents, message="catalog update"):
        path = self.repo / relative_path
        path.write_text(contents, encoding="utf-8")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", message)

    def test_sync_reconciliation_leaves_current_managed_items_untouched(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        manager.action("pi-package", "install")
        foo = manager.skills_root / "foo"
        extension = manager.pi_extensions_root / "package"
        before_foo = self._git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()

        response = manager.sync()

        self.assertEqual(response["reconciliation"]["attempted"], 0)
        self.assertEqual(response["reconciliation"]["updated"], 0)
        self.assertEqual(response["reconciliation"]["current"], 2)
        self.assertEqual(response["reconciliation"]["unchanged"], 2)
        self.assertEqual(
            {item["status"] for item in response["reconciliation"]["items"]},
            {"unchanged"},
        )
        self.assertEqual(foo.joinpath("SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")
        self.assertEqual(extension.joinpath("index.ts").read_text(encoding="utf-8"), "export {};\n")
        self.assertEqual(self._git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip(), before_foo)

    def test_sync_reconciliation_updates_only_an_unchanged_managed_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        old_digest = manager._load_state(strict=True)["managed"]["skill:personal/foo"]["digest"]
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "updated")
        self.assertEqual(outcome["state"], "current")
        self.assertEqual(response["reconciliation"]["attempted"], 1)
        self.assertEqual(response["reconciliation"]["updated"], 1)
        self.assertEqual(manager.skills_root.joinpath("foo/SKILL.md").read_text(encoding="utf-8"), "foo-v2\n")
        copies = [path for path in manager.quarantine_root.iterdir() if path.is_dir()]
        self.assertTrue(copies)
        self.assertIn("foo-v1\n", [path.joinpath("SKILL.md").read_text(encoding="utf-8") for path in copies])
        state = manager._load_state(strict=True)
        self.assertNotEqual(state["managed"]["skill:personal/foo"]["digest"], old_digest)

    def test_sync_reconciliation_refreshes_stale_record_for_current_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo"
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        # Simulate a target that is already current while its ownership record
        # was not persisted by an earlier operation.
        source = self.repo / "skills" / "personal" / "foo"
        target.joinpath("SKILL.md").write_text(source.joinpath("SKILL.md").read_text(encoding="utf-8"), encoding="utf-8")
        stale_state = manager._load_state(strict=True)
        stale_record = stale_state["managed"]["skill:personal/foo"]
        stale_record["catalogRevision"] = "stale-revision"
        stale_record["digest"] = "0" * 64
        manager._save_state(stale_state)

        response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "unchanged")
        self.assertEqual(outcome["state"], "current")
        self.assertEqual(response["reconciliation"]["attempted"], 0)
        refreshed = manager._load_state(strict=True)["managed"]["skill:personal/foo"]
        self.assertEqual(refreshed["catalogRevision"], response["catalogRevision"])
        self.assertEqual(refreshed["digest"], _tree_digest(target))
        self.assertEqual(list(manager.quarantine_root.iterdir()) if manager.quarantine_root.exists() else [], [])

    def test_sync_reconciliation_restores_managed_missing_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        (manager.skills_root / "foo").rename(manager.skills_root / "foo-removed")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "restored")
        self.assertEqual(outcome["state"], "current")
        self.assertEqual(outcome["reason"], "managed_target_missing")
        self.assertEqual((manager.skills_root / "foo/SKILL.md").read_text(encoding="utf-8"), "foo-v2\n")
        self.assertEqual(response["reconciliation"]["restored"], 1)
        self.assertIn("skill:personal/foo", manager._load_state(strict=True)["managed"])

    def test_sync_reconciliation_reports_missing_restore_failure_without_rollback_claim(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        (manager.skills_root / "foo").rename(manager.skills_root / "foo-removed")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        with mock.patch.object(
            manager,
            "_copy_item",
            side_effect=FleetError("injected restore failure", code="fleet_install_failed", status=503),
        ):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "failed")
        self.assertEqual(outcome["action"], "restore")
        self.assertFalse(outcome["rollback"]["restored"])
        self.assertEqual(response["reconciliation"]["restored"], 0)
        self.assertEqual(response["reconciliation"]["failed"], 1)
        self.assertFalse((manager.skills_root / "foo").exists())
        self.assertTrue((manager.skills_root / "foo-removed").exists())

    def test_sync_reconciliation_does_not_restore_after_explicit_uninstall(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        manager.action("skill:personal/foo", "remove")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        self.assertEqual(response["reconciliation"]["total"], 0)
        self.assertFalse((manager.skills_root / "foo").exists())
        self.assertNotIn("skill:personal/foo", manager._load_state(strict=True)["managed"])

    def test_sync_reconciliation_preserves_locally_drifted_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo" / "SKILL.md"
        target.write_text("local edit\n", encoding="utf-8")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "skipped")
        self.assertEqual(outcome["state"], "drifted")
        self.assertEqual(outcome["reason"], "local_drift")
        self.assertEqual(target.read_text(encoding="utf-8"), "local edit\n")
        self.assertEqual(list(manager.quarantine_root.iterdir()) if manager.quarantine_root.exists() else [], [])

    def test_sync_reconciliation_never_replaces_an_unmanaged_target(self):
        manager = self.sync_manager()
        manager.skills_root.mkdir(parents=True, exist_ok=True)
        target = manager.skills_root / "foo"
        target.mkdir()
        target.joinpath("SKILL.md").write_text("local copy\n", encoding="utf-8")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        self.assertEqual(response["reconciliation"]["total"], 0)
        self.assertEqual(target.joinpath("SKILL.md").read_text(encoding="utf-8"), "local copy\n")

    def test_sync_reconciliation_never_replaces_a_symlinked_managed_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo"
        outside = self.home / "outside"
        outside.mkdir()
        target.rename(self.home / "old-managed-copy")
        target.symlink_to(outside, target_is_directory=True)
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")

        response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "skipped")
        self.assertEqual(outcome["reason"], "target_symlink")
        self.assertTrue(target.is_symlink())
        self.assertEqual(target.resolve(), outside.resolve())
        self.assertTrue((self.home / "old-managed-copy").exists())

    def test_sync_reconciliation_continues_after_failure_and_rolls_back_item(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        manager.action("pi-package", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        self._commit_catalog_change("pi-extensions/package/index.ts", "export const v2 = true;\n", "extension update")
        original_copy = manager._copy_item

        def copy_or_fail(item, source, target):
            if item.id == "skill:personal/foo":
                raise FleetError("injected copy failure", code="fleet_install_failed", status=503)
            return original_copy(item, source, target)

        with mock.patch.object(manager, "_copy_item", side_effect=copy_or_fail):
            response = manager.sync()

        self.assertTrue(response["ok"])
        outcomes = {item["itemId"]: item for item in response["reconciliation"]["items"]}
        self.assertEqual(outcomes["pi-package"]["status"], "updated")
        self.assertEqual(outcomes["skill:personal/foo"]["status"], "failed")
        self.assertEqual(outcomes["skill:personal/foo"]["rollback"]["restored"], True)
        self.assertEqual(response["reconciliation"]["failed"], 1)
        self.assertEqual(response["reconciliation"]["rollbackRestored"], 1)
        self.assertEqual(manager.skills_root.joinpath("foo/SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")
        self.assertEqual(manager.pi_extensions_root.joinpath("package/index.ts").read_text(encoding="utf-8"), "export const v2 = true;\n")

    def test_sync_reconciliation_rolls_back_when_copy_reports_failure_after_replace(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        original_copy = manager._copy_item

        def copy_then_fail(item, source, target):
            original_copy(item, source, target)
            raise FleetError("post-copy failure", code="fleet_install_failed", status=503)

        with mock.patch.object(manager, "_copy_item", side_effect=copy_then_fail):
            response = manager.sync()

        outcome = response["reconciliation"]["items"][0]
        self.assertEqual(outcome["status"], "failed")
        self.assertTrue(outcome["rollback"]["restored"])
        self.assertEqual(manager.skills_root.joinpath("foo/SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_sync_response_keeps_inventory_and_exposes_bounded_reconciliation_shape(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        response = manager.sync()

        self.assertTrue(response["ok"])
        self.assertIn("items", response)
        self.assertIn("skills", response)
        self.assertIn("piExtensions", response)
        self.assertIn("cli", response)
        reconciliation = response["reconciliation"]
        self.assertEqual(
            {"counts", "items", "outcomes"}.issubset(reconciliation),
            True,
        )
        self.assertEqual(
            {"attempted", "updated", "current", "restored", "skippedDrifted", "failed"}.issubset(reconciliation["counts"]),
            True,
        )
        self.assertEqual(reconciliation["items"], reconciliation["outcomes"])
        self.assertNotIn("stdout", json.dumps(response))

    def test_sync_revalidates_checkout_after_fetch_before_any_install(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        original_sync_existing = manager._sync_existing

        def sync_then_dirty(checkout):
            original_sync_existing(checkout)
            (checkout / "post-fetch-hook-output").write_text("unexpected\n", encoding="utf-8")

        with mock.patch.object(manager, "_sync_existing", side_effect=sync_then_dirty):
            with self.assertRaises(FleetError) as raised:
                manager.sync()
        self.assertEqual(raised.exception.code, "catalog_dirty")
        self.assertEqual((manager.skills_root / "foo/SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_sync_revalidates_checkout_again_before_reconciliation(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        original_read_snapshot = manager._read_validated_catalog

        def read_then_dirty(checkout, revision):
            catalog = original_read_snapshot(checkout, revision)
            (checkout / "post-read-hook-output").write_text("unexpected\n", encoding="utf-8")
            return catalog

        with mock.patch.object(manager, "_read_validated_catalog", side_effect=read_then_dirty):
            with self.assertRaises(FleetError) as raised:
                manager.sync()
        self.assertEqual(raised.exception.code, "catalog_dirty")
        self.assertEqual((manager.skills_root / "foo/SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_deleted_managed_record_is_remove_only_tombstone_until_explicit_cleanup(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        source = self.repo / "skills/personal/foo/SKILL.md"
        source.unlink()
        source.parent.rmdir()
        self._git("-C", str(self.repo), "add", "-A")
        self._git("-C", str(self.repo), "commit", "-m", "remove catalog skill")

        response = manager.sync()
        tombstone = next(item for item in response["items"] if item.get("tombstone"))
        self.assertEqual(tombstone["ownership"], "managed")
        self.assertFalse(tombstone["installable"])
        self.assertEqual(tombstone["status"], "unknown")
        self.assertEqual(response["catalog"]["itemCounts"]["skills"], 1)
        self.assertEqual(response["reconciliation"]["skipped"], 1)
        with self.assertRaises(FleetError) as raised:
            manager.action(tombstone["id"], "update")
        self.assertEqual(raised.exception.code, "fleet_action_forbidden")

        removed = manager.action(tombstone["id"], "remove")
        self.assertEqual(removed["item"]["status"], "missing")
        self.assertNotIn("skill:personal/foo", manager._load_state(strict=True)["managed"])
        self.assertFalse((manager.skills_root / "foo").exists())

    def test_retargeted_same_id_keeps_old_target_as_deterministic_tombstone(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        manifest = json.loads((self.repo / "fleet.json").read_text(encoding="utf-8"))
        manifest["skills"] = [
            {
                "id": "skill:personal/foo",
                "name": "foo",
                "path": "skills/personal/foo",
                "target": "foo-renamed",
                "classification": "personal",
                "writable": True,
            }
        ]
        (self.repo / "fleet.json").write_text(json.dumps(manifest), encoding="utf-8")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", "retarget catalog skill")

        response = manager.sync()
        tombstones = [item for item in response["items"] if item.get("tombstone")]
        self.assertEqual(len(tombstones), 1)
        tombstone = tombstones[0]
        self.assertEqual(tombstone["tombstoneReason"], "catalog_item_retargeted")
        self.assertFalse(tombstone["installable"])
        self.assertEqual(response["catalog"]["itemCounts"]["skills"], 2)
        self.assertEqual(response["reconciliation"]["skipped"], 1)
        self.assertTrue((manager.skills_root / "foo").exists())
        self.assertNotIn(tombstone["id"], {item["id"] for item in response["skills"] if not item.get("tombstone")})

        # A retargeted item ID cannot reuse its stale ownership slot.  The
        # old target remains owned until its Remove-only tombstone is cleared.
        for action in ("install", "update", "adopt"):
            with self.assertRaises(FleetError) as raised:
                manager.action("skill:personal/foo", action)
            self.assertEqual(raised.exception.code, "fleet_action_forbidden")
        self.assertTrue((manager.skills_root / "foo").exists())
        self.assertFalse((manager.skills_root / "foo-renamed").exists())

        removed = manager.action(tombstone["id"], "remove")
        self.assertEqual(removed["item"]["status"], "missing")
        self.assertFalse((manager.skills_root / "foo").exists())
        self.assertNotIn("skill:personal/foo", manager._load_state(strict=True)["managed"])

        installed = manager.action("skill:personal/foo", "install")
        self.assertEqual(installed["item"]["status"], "current")
        self.assertEqual((manager.skills_root / "foo-renamed" / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_sync_reconciliation_uses_git_snapshot_after_worktree_source_edit(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        source = manager.checkout / "skills" / "personal" / "foo" / "SKILL.md"
        original_reconcile = manager._reconcile_managed_items

        def edit_worktree_then_reconcile(catalog, state):
            source.write_text("dirty after validation\n", encoding="utf-8")
            return original_reconcile(catalog, state)

        with mock.patch.object(manager, "_reconcile_managed_items", side_effect=edit_worktree_then_reconcile):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "updated")
        self.assertEqual((manager.skills_root / "foo" / "SKILL.md").read_text(encoding="utf-8"), "foo-v2\n")
        self.assertEqual(source.read_text(encoding="utf-8"), "dirty after validation\n")

    def test_action_install_uses_git_snapshot_after_worktree_source_edit(self):
        manager = self.sync_manager()
        source = manager.checkout / "skills" / "personal" / "foo" / "SKILL.md"
        original_copy = manager._copy_item

        def edit_worktree_then_copy(item, source_path, target):
            source.write_text("dirty during install\n", encoding="utf-8")
            return original_copy(item, source_path, target)

        with mock.patch.object(manager, "_copy_item", side_effect=edit_worktree_then_copy):
            response = manager.action("skill:personal/foo", "install")

        self.assertEqual(response["item"]["status"], "current")
        self.assertEqual((manager.skills_root / "foo" / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")
        self.assertEqual(source.read_text(encoding="utf-8"), "dirty during install\n")

    def test_malicious_managed_state_path_is_omitted_from_inventory_and_actions(self):
        manager = self.sync_manager()
        state = manager._load_state(strict=True)
        state["managed"]["evil"] = {
            "type": "skill",
            "source": "skills/../../outside",
            "target": "../outside",
            "destination": "agents",
            "digest": "0" * 64,
        }
        manager._save_state(state)

        response = manager.inventory()
        self.assertFalse(any(item.get("managedRecordId") == "evil" for item in response["items"]))
        with self.assertRaises(FleetError) as raised:
            manager.action("evil", "remove")
        self.assertEqual(raised.exception.code, "fleet_item_not_found")

    def test_tombstone_remove_cleans_missing_target_without_reinstalling_it(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        (manager.skills_root / "foo" / "SKILL.md").unlink()
        (manager.skills_root / "foo").rmdir()
        source = self.repo / "skills/personal/foo/SKILL.md"
        source.unlink()
        source.parent.rmdir()
        self._git("-C", str(self.repo), "add", "-A")
        self._git("-C", str(self.repo), "commit", "-m", "remove missing catalog skill")

        response = manager.sync()
        tombstone = next(item for item in response["items"] if item.get("tombstone"))
        removed = manager.action(tombstone["id"], "remove")
        self.assertEqual(removed["item"]["status"], "missing")
        self.assertNotIn("skill:personal/foo", manager._load_state(strict=True)["managed"])

    def test_tombstone_with_symlinked_target_is_visible_but_remove_is_guarded(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo"
        target.rename(manager.home / "old-managed-copy")
        outside = manager.home / "outside"
        outside.mkdir()
        target.symlink_to(outside, target_is_directory=True)
        source = self.repo / "skills/personal/foo/SKILL.md"
        source.unlink()
        source.parent.rmdir()
        self._git("-C", str(self.repo), "add", "-A")
        self._git("-C", str(self.repo), "commit", "-m", "remove symlinked catalog skill")

        response = manager.sync()
        tombstone = next(item for item in response["items"] if item.get("tombstone"))
        with self.assertRaises(FleetError) as raised:
            manager.action(tombstone["id"], "remove")
        self.assertEqual(raised.exception.code, "fleet_target_unmanaged")
        self.assertTrue(target.is_symlink())
        self.assertEqual(target.resolve(), outside.resolve())

    def test_tombstone_action_id_changes_deterministically_when_catalog_id_collides(self):
        record = {
            "id": "old-item",
            "type": "skill",
            "source": "skills/personal/old",
            "target": "old",
            "destination": "agents",
            "digest": "0" * 64,
        }
        first = FleetManager._tombstone_action_id(record, set())
        second = FleetManager._tombstone_action_id(record, {first})
        self.assertNotEqual(first, second)
        self.assertEqual(second, FleetManager._tombstone_action_id(record, {first}))

    def test_tombstone_action_id_exhausts_full_digest_collisions(self):
        record = {
            "id": "old-item",
            "type": "skill",
            "source": "skills/personal/old",
            "target": "old",
            "destination": "agents",
            "digest": "0" * 64,
        }
        identity = json.dumps(
            {
                "id": record["id"],
                "type": record["type"],
                "source": record["source"],
                "target": record["target"],
                "destination": record["destination"],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        digest = hashlib.sha256(identity).hexdigest()
        occupied = {
            "managed-tombstone:" + digest[:32],
            "managed-tombstone-record:" + digest[:32],
            "managed-tombstone-record:" + digest,
        }
        occupied.update(f"managed-tombstone-record:{digest}-{number}" for number in range(1, 9))

        candidate = FleetManager._tombstone_action_id(record, occupied)

        self.assertEqual(candidate, f"managed-tombstone-record:{digest}-9")
        self.assertNotIn(candidate, occupied)
        self.assertEqual(candidate, FleetManager._tombstone_action_id(record, occupied))

    def test_remove_repairs_state_after_atomic_state_replace_reports_failure(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo"
        real_replace = os.replace
        state_replace_failed = False

        def replace_then_fail_once(source, destination):
            nonlocal state_replace_failed
            result = real_replace(source, destination)
            if Path(destination) == manager.state_path and not state_replace_failed:
                state_replace_failed = True
                raise OSError("injected post-replace state failure")
            return result

        with mock.patch.object(fleet_module.os, "replace", side_effect=replace_then_fail_once):
            with self.assertRaises(FleetError) as raised:
                manager.action("skill:personal/foo", "remove")

        self.assertEqual(raised.exception.code, "fleet_state_write_failed")
        self.assertTrue(target.exists())
        self.assertEqual(target.joinpath("SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")
        state = manager._load_state(strict=True)
        self.assertIn("skill:personal/foo", state["managed"])
        self.assertEqual(state.get("quarantine", []), [])

    def test_remove_indexes_quarantine_when_post_move_guard_fails(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        target = manager.skills_root / "foo"
        real_move = fleet_module._exclusive_move
        raced = False

        def move_then_repopulate(source, destination):
            nonlocal raced
            result = real_move(source, destination)
            if not raced and Path(destination).parent == manager.quarantine_root:
                raced = True
                target.mkdir()
                (target / "SKILL.md").write_text("concurrent remove replacement\n", encoding="utf-8")
            return result

        with mock.patch.object(fleet_module, "_exclusive_move", side_effect=move_then_repopulate):
            with self.assertRaises(FleetError) as raised:
                manager.action("skill:personal/foo", "remove")

        self.assertEqual(raised.exception.code, "fleet_target_changed")
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "concurrent remove replacement\n")
        state = manager._load_state(strict=True)
        self.assertIn("skill:personal/foo", state["managed"])
        self.assertTrue(state.get("quarantine"))
        recovery = manager.quarantine_root / state["quarantine"][-1]["path"]
        self.assertEqual((recovery / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_explicit_update_restores_state_after_late_atomic_state_failure(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        before = manager._load_state(strict=True)
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        self._git("-C", str(manager.checkout), "fetch", "origin")
        self._git("-C", str(manager.checkout), "merge", "--ff-only", "origin/main")
        real_replace = os.replace
        state_replacements = 0

        def replace_then_fail_final(source, destination):
            nonlocal state_replacements
            result = real_replace(source, destination)
            if Path(destination) == manager.state_path:
                state_replacements += 1
                if state_replacements == 2:
                    raise OSError("injected post-replace state failure")
            return result

        with mock.patch.object(fleet_module.os, "replace", side_effect=replace_then_fail_final):
            with self.assertRaises(FleetError) as raised:
                manager.action("skill:personal/foo", "update")

        self.assertEqual(raised.exception.code, "fleet_state_write_failed")
        self.assertEqual((manager.skills_root / "foo" / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")
        state = manager._load_state(strict=True)
        self.assertEqual(state["managed"]["skill:personal/foo"]["digest"], before["managed"]["skill:personal/foo"]["digest"])
        self.assertEqual(state["catalog"], before["catalog"])
        self.assertTrue(state.get("quarantine"))
        failed = manager.quarantine_root / state["quarantine"][-1]["path"]
        self.assertEqual((failed / "SKILL.md").read_text(encoding="utf-8"), "foo-v2\n")

    def test_explicit_update_rollback_never_removes_concurrent_replacement(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        before = manager._load_state(strict=True)
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        self._git("-C", str(manager.checkout), "fetch", "origin")
        self._git("-C", str(manager.checkout), "merge", "--ff-only", "origin/main")
        target = manager.skills_root / "foo"
        original_copy = manager._copy_item

        def copy_then_replace(item, source, destination):
            original_copy(item, source, destination)
            (destination / "SKILL.md").unlink()
            destination.rmdir()
            destination.mkdir()
            (destination / "SKILL.md").write_text("concurrent explicit replacement\n", encoding="utf-8")
            raise FleetError("injected post-copy failure", code="fleet_install_failed", status=503)

        with mock.patch.object(manager, "_copy_item", side_effect=copy_then_replace):
            with self.assertRaises(FleetError) as raised:
                manager.action("skill:personal/foo", "update")

        self.assertEqual(raised.exception.code, "fleet_install_failed")
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "concurrent explicit replacement\n")
        state = manager._load_state(strict=True)
        self.assertEqual(state["managed"]["skill:personal/foo"]["digest"], before["managed"]["skill:personal/foo"]["digest"])
        self.assertTrue(state.get("quarantine"))
        old_copy = manager.quarantine_root / state["quarantine"][0]["path"]
        self.assertEqual((old_copy / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_exclusive_native_promotion_refuses_existing_destination(self):
        if platform.system() != "Darwin":
            self.skipTest("Darwin renamex_np coverage")
        source = self.home / "native-source"
        destination = self.home / "native-destination"
        source.mkdir()
        (source / "value").write_text("source\n", encoding="utf-8")
        destination.mkdir()
        (destination / "value").write_text("destination\n", encoding="utf-8")

        with self.assertRaises(OSError) as raised:
            fleet_module._exclusive_move(source, destination)

        self.assertEqual(raised.exception.errno, errno.EEXIST)
        self.assertTrue(source.exists())
        self.assertEqual((destination / "value").read_text(encoding="utf-8"), "destination\n")

    def test_copy_promotion_race_never_replaces_new_target(self):
        manager = self.sync_manager()
        manager._prepare_install_roots()
        catalog = manager._checkout_catalog()
        item = next(item for item in catalog.items if item.id == "skill:personal/foo")
        source, source_digest = manager._catalog_source(catalog, item)
        self.assertIsNotNone(source)
        self.assertIsNotNone(source_digest)
        target = manager.skills_root / "foo"
        original_move = fleet_module._exclusive_move
        raced = False

        def create_then_promote(source_path, destination):
            nonlocal raced
            if not raced and destination == target:
                raced = True
                destination.mkdir()
                (destination / "SKILL.md").write_text("created during promotion\n", encoding="utf-8")
            return original_move(source_path, destination)

        with mock.patch.object(fleet_module, "_exclusive_move", side_effect=create_then_promote):
            with self.assertRaises(FleetError) as raised:
                manager._copy_item(item, source, target)

        self.assertEqual(raised.exception.code, "fleet_target_conflict")
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "created during promotion\n")

    def test_restore_promotion_race_never_replaces_new_target(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        catalog = manager._checkout_catalog()
        item = next(item for item in catalog.items if item.id == "skill:personal/foo")
        target = manager.skills_root / "foo"
        identity, digest = manager._target_snapshot(target)
        destination = manager._quarantine_target(
            item,
            target,
            manager.skills_root,
            expected_identity=identity,
            expected_digest=digest,
        )
        original_move = fleet_module._exclusive_move

        def create_then_restore(source_path, destination_path):
            target.mkdir()
            (target / "SKILL.md").write_text("created during restore\n", encoding="utf-8")
            return original_move(source_path, destination_path)

        with mock.patch.object(fleet_module, "_exclusive_move", side_effect=create_then_restore):
            restored = manager._restore_quarantine_target(
                destination,
                target,
                manager.skills_root,
                expected_identity=identity,
                expected_digest=digest,
            )

        self.assertFalse(restored)
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "created during restore\n")
        self.assertTrue(destination.exists())

    def test_reconciliation_guards_concurrent_replacement_after_quarantine(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        target = manager.skills_root / "foo"
        real_move = fleet_module._exclusive_move
        raced = False

        def move_then_repopulate(source, destination):
            nonlocal raced
            result = real_move(source, destination)
            if not raced and Path(destination).parent == manager.quarantine_root:
                raced = True
                target.mkdir()
                (target / "SKILL.md").write_text("concurrent copy\n", encoding="utf-8")
            return result

        with mock.patch.object(fleet_module, "_exclusive_move", side_effect=move_then_repopulate):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "skipped")
        self.assertEqual(outcome["reason"], "target_changed_during_reconcile")
        self.assertFalse(outcome["rollback"]["restored"])
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "concurrent copy\n")
        state = manager._load_state(strict=True)
        recovery = state.get("quarantine", [])
        self.assertTrue(recovery)
        recovery_path = manager.quarantine_root / recovery[-1]["path"]
        self.assertTrue(recovery_path.exists())
        self.assertEqual((recovery_path / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

    def test_reconciliation_guards_target_swap_between_snapshot_and_quarantine(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        target = manager.skills_root / "foo"
        original_snapshot = manager._target_snapshot
        swapped = False

        def snapshot_then_swap(path):
            nonlocal swapped
            result = original_snapshot(path)
            if not swapped and path == target:
                swapped = True
                (path / "SKILL.md").unlink()
                path.rmdir()
                path.mkdir()
                (path / "SKILL.md").write_text("swapped before quarantine\n", encoding="utf-8")
            return result

        with mock.patch.object(manager, "_target_snapshot", side_effect=snapshot_then_swap):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "skipped")
        self.assertEqual(outcome["reason"], "target_changed_during_reconcile")
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "swapped before quarantine\n")

    def test_reconciliation_rollback_never_removes_concurrent_replacement(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        target = manager.skills_root / "foo"
        original_copy = manager._copy_item

        def copy_then_replace(item, source, destination):
            original_copy(item, source, destination)
            (destination / "SKILL.md").unlink()
            destination.rmdir()
            destination.mkdir()
            (destination / "SKILL.md").write_text("concurrent replacement\n", encoding="utf-8")
            raise FleetError("injected post-copy failure", code="fleet_install_failed", status=503)

        with mock.patch.object(manager, "_copy_item", side_effect=copy_then_replace):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "failed")
        self.assertFalse(outcome["rollback"]["restored"])
        self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "concurrent replacement\n")
        self.assertTrue(manager.quarantine_root.joinpath(next(iter(manager._load_state(strict=True)["quarantine"]))["path"]).exists())

    def test_quarantine_edit_is_restored_or_indexed_never_stranded(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        target = manager.skills_root / "foo"
        real_move = fleet_module._exclusive_move
        edited = False

        def move_then_edit(source, destination):
            nonlocal edited
            result = real_move(source, destination)
            if not edited and Path(destination).parent == manager.quarantine_root:
                edited = True
                (Path(destination) / "SKILL.md").write_text("edited while preserved\n", encoding="utf-8")
            return result

        with mock.patch.object(fleet_module, "_exclusive_move", side_effect=move_then_edit):
            response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "skipped")
        self.assertTrue(target.exists() or manager._load_state(strict=True).get("quarantine"))
        if target.exists():
            self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), "edited while preserved\n")

    def test_reconciliation_keeps_recovery_record_when_state_write_and_restore_fail(self):
        manager = self.sync_manager()
        manager.action("skill:personal/foo", "install")
        self._commit_catalog_change("skills/personal/foo/SKILL.md", "foo-v2\n")
        original_save = manager._save_state
        calls = 0

        def save_with_final_failure(state):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise FleetError("injected state write failure", code="fleet_state_write_failed", status=503)
            return original_save(state)

        with mock.patch.object(manager, "_save_state", side_effect=save_with_final_failure):
            with mock.patch.object(manager, "_restore_quarantine_target", return_value=False):
                response = manager.sync()

        outcome = next(item for item in response["reconciliation"]["items"] if item["itemId"] == "skill:personal/foo")
        self.assertEqual(outcome["status"], "failed")
        self.assertFalse(outcome["rollback"]["restored"])
        state = manager._load_state(strict=True)
        self.assertTrue(state.get("quarantine"))
        recovery = manager.quarantine_root / state["quarantine"][-1]["path"]
        self.assertTrue(recovery.exists())
        self.assertEqual((recovery / "SKILL.md").read_text(encoding="utf-8"), "foo-v1\n")

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

    def test_ignored_only_implicit_checkout_is_untouched_and_managed_checkout_is_promoted(self):
        environment = self._implicit_environment()
        user_checkout = self._clone_checkout(
            self.home / "Documents" / "Development" / "personal-claude-plugin"
        )
        before_revision = self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip()
        exclude = user_checkout / ".git" / "info" / "exclude"
        with exclude.open("a", encoding="utf-8") as handle:
            handle.write("fleet-ignored.txt\n")
        ignored_file = user_checkout / "fleet-ignored.txt"
        ignored_file.write_text("local ignored state\n", encoding="utf-8")
        self.assertEqual(self._git("-C", str(user_checkout), "status", "--porcelain").stdout, "")

        manager = FleetManager(environ=environment)
        response = manager.sync()

        managed_checkout = self.home / ".local" / "share" / "herdr-fleet" / "personal-claude-plugin"
        self.assertTrue(response["ok"])
        self.assertEqual(manager.checkout, managed_checkout.resolve())
        self.assertTrue((managed_checkout / "fleet.json").is_file())
        self.assertEqual(ignored_file.read_text(encoding="utf-8"), "local ignored state\n")
        after_revision = self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(after_revision, before_revision)
        self.assertEqual(self._git("-C", str(user_checkout), "status", "--porcelain").stdout, "")

    def test_clean_stale_implicit_checkout_is_fast_forwarded_on_sync(self):
        environment = self._implicit_environment()
        user_checkout = self._clone_checkout(
            self.home / "Code" / "ronnie3786" / "personal-claude-plugin"
        )
        before_revision = self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip()

        source = self.repo / "skills" / "personal" / "foo" / "SKILL.md"
        source.write_text("foo-v2\n", encoding="utf-8")
        self._git("-C", str(self.repo), "add", ".")
        self._git("-C", str(self.repo), "commit", "-m", "catalog update")
        remote_revision = self._git("-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()

        manager = FleetManager(environ=environment)
        response = manager.sync()

        self.assertTrue(response["ok"])
        self.assertEqual(manager.checkout, user_checkout.resolve())
        self.assertNotEqual(before_revision, remote_revision)
        self.assertEqual(
            self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip(),
            remote_revision,
        )
        self.assertEqual(
            (user_checkout / "skills" / "personal" / "foo" / "SKILL.md").read_text(encoding="utf-8"),
            "foo-v2\n",
        )
        self.assertFalse((self.home / ".local" / "share" / "herdr-fleet" / "personal-claude-plugin").exists())

    def test_accidental_gitlink_is_omitted_in_fresh_and_populated_checkouts(self):
        subrepo, revision = self._add_accidental_gitlink()
        manager = self.manager()
        fresh = manager.sync()
        self.assertEqual(fresh["catalog"]["itemCounts"]["skills"], 2)
        self.assertNotIn("skill:work/accidental-gitlink", {item["id"] for item in fresh["skills"]})

        # A populated nested checkout can appear on one machine when the
        # parent tree is an accidental gitlink.  It is not a catalog source,
        # and must not change the inventory reported for that same revision.
        populated = manager.checkout / "skills" / "work" / "accidental-gitlink"
        self._git("clone", str(subrepo), str(populated))
        self._git("-C", str(populated), "checkout", "--detach", revision)
        # Existing managed checkouts are intentionally rejected by the
        # selection guard before a sync can mutate them.  Exercise the
        # read-only parser directly to prove its immutable-tree omission is
        # still independent of the populated working tree.
        populated_catalog = manager._read_catalog(manager.checkout)
        populated_inventory = manager._sync_response(populated_catalog, state=manager._load_state())
        self.assertEqual(populated_inventory["catalog"]["itemCounts"]["skills"], 2)
        self.assertEqual(
            {item["id"] for item in populated_inventory["skills"]},
            {item["id"] for item in fresh["skills"]},
        )

    def test_implicit_populated_gitlink_is_untouched_and_managed_checkout_is_selected(self):
        subrepo, revision = self._add_accidental_gitlink()
        environment = self._implicit_environment()
        user_checkout = self._clone_checkout(
            self.home / "Documents" / "Development" / "personal-claude-plugin"
        )
        populated = user_checkout / "skills" / "work" / "accidental-gitlink"
        self._git("clone", str(subrepo), str(populated))
        self._git("-C", str(populated), "checkout", "--detach", revision)
        before_revision = self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip()
        before_status = self._git(
            "-C",
            str(user_checkout),
            "status",
            "--porcelain=v2",
            "--untracked-files=all",
            "--ignored=matching",
        ).stdout

        manager = FleetManager(environ=environment)
        response = manager.sync()

        managed_checkout = self.home / ".local" / "share" / "herdr-fleet" / "personal-claude-plugin"
        self.assertTrue(response["ok"])
        self.assertEqual(manager.checkout, managed_checkout.resolve())
        self.assertEqual(
            self._git("-C", str(user_checkout), "rev-parse", "HEAD").stdout.strip(),
            before_revision,
        )
        self.assertEqual(
            self._git(
                "-C",
                str(user_checkout),
                "status",
                "--porcelain=v2",
                "--untracked-files=all",
                "--ignored=matching",
            ).stdout,
            before_status,
        )
        self.assertTrue(populated.joinpath("SKILL.md").is_file())

    def test_explicit_populated_gitlink_checkout_fails_before_sync_mutation(self):
        subrepo, revision = self._add_accidental_gitlink()
        managed_checkout = self._clone_checkout(self.home / "managed-catalog")
        populated = managed_checkout / "skills" / "work" / "accidental-gitlink"
        self._git("clone", str(subrepo), str(populated))
        self._git("-C", str(populated), "checkout", "--detach", revision)
        before_revision = self._git("-C", str(managed_checkout), "rev-parse", "HEAD").stdout.strip()
        manager = self.manager()

        with self.assertRaises(FleetError) as raised:
            manager.sync()

        self.assertEqual(raised.exception.code, "catalog_checkout_invalid")
        self.assertEqual(
            self._git("-C", str(managed_checkout), "rev-parse", "HEAD").stdout.strip(),
            before_revision,
        )
        self.assertTrue(populated.joinpath("SKILL.md").is_file())

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

    def test_acli_auth_check_uses_exact_fixed_read_only_probe(self):
        manager = self.sync_manager()
        response = manager.action("acli", "checkAuth")
        self.assertEqual(response["item"]["auth"]["status"], "ok")
        self.assertEqual(response["item"]["authCheckAvailable"], True)

        parsed = manager._parse_catalog_items(
            self.repo,
            {
                "cliCatalog": [
                    {
                        "id": "acli",
                        "adapter": "inventory",
                        "command": ["acli"],
                        "readOnlyChecks": [
                            {
                                "command": ["acli"],
                                "args": ["jira", "auth", "status"],
                                "timeoutSeconds": 5,
                                "readOnly": True,
                                "outputPolicy": "discard",
                            }
                        ],
                    }
                ]
            },
        )[0]
        self.assertEqual(parsed.auth_argv, ("acli", "jira", "auth", "status"))
        self.assertTrue(parsed.auth_check)

        with self.assertRaises(FleetError) as raised:
            manager._parse_catalog_items(
                self.repo,
                {
                    "cliCatalog": [
                        {
                            "id": "acli",
                            "adapter": "inventory",
                            "command": ["acli"],
                            "readOnlyChecks": [
                                {
                                    "command": ["acli"],
                                    "args": ["jira", "auth", "whoami"],
                                    "timeoutSeconds": 5,
                                    "readOnly": True,
                                    "outputPolicy": "discard",
                                }
                            ],
                        }
                    ]
                },
            )
        self.assertEqual(raised.exception.code, "catalog_invalid")

    def test_launchd_path_falls_back_to_standard_homebrew_and_user_bins(self):
        """A minimal launchd PATH still finds the supported CLI locations."""

        homebrew_bin = self.home / "homebrew" / "bin"
        self._write_executable_at(homebrew_bin / "gh")
        self._write_executable_at(self.home / ".local" / "bin" / "claude")
        launchd_environment = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
        }

        with mock.patch("herdr_harness.fleet._STANDARD_EXECUTABLE_DIRECTORIES", (homebrew_bin,)):
            self.assertEqual(_which(launchd_environment, "gh"), str((homebrew_bin / "gh").resolve()))
            self.assertEqual(
                _which(launchd_environment, "claude"),
                str((self.home / ".local" / "bin" / "claude").resolve()),
            )

    def test_auth_check_runs_the_resolved_symlink_target(self):
        """Auth probes use the validated executable, not catalog path data."""

        homebrew_bin = self.home / "homebrew" / "bin"
        actual = self.home / "installed" / "gh"
        self._write_executable_at(
            actual,
            "#!/bin/sh\n"
            "[ \"$1\" = auth ] && [ \"$2\" = status ] || exit 42\n"
            "exit 0\n",
        )
        homebrew_bin.mkdir(parents=True, exist_ok=True)
        (homebrew_bin / "gh").symlink_to(actual)
        launchd_environment = dict(self.environ)
        launchd_environment.update({"HOME": str(self.home), "PATH": "/usr/bin:/bin"})
        manager = FleetManager(environ=launchd_environment)
        catalog = {
            "cliCatalog": [
                {
                    "id": "gh",
                    "adapter": "inventory",
                    "command": ["gh"],
                    "readOnlyChecks": [
                        {
                            "command": ["gh"],
                            "args": ["auth", "status"],
                            "timeoutSeconds": 5,
                            "readOnly": True,
                            "outputPolicy": "discard",
                        }
                    ],
                }
            ]
        }
        item = manager._parse_catalog_items(self.repo, catalog)[0]

        with (
            mock.patch("herdr_harness.fleet._STANDARD_EXECUTABLE_DIRECTORIES", (homebrew_bin,)),
            mock.patch("herdr_harness.fleet._run_command", wraps=_run_command) as run_command,
        ):
            auth = manager._run_auth_check(item)

        self.assertEqual(auth["status"], "ok")
        self.assertEqual(run_command.call_args.args[0], str(actual.resolve()))

    def test_command_resolution_ignores_relative_path_entries_and_invalid_targets(self):
        """Relative PATH entries, directories, and broken links never resolve."""

        relative_bin = Path(self.temporary.name) / "relative-bin"
        relative_bin.mkdir()
        self._write_executable_at(relative_bin / "relative-only")
        standard_bin = self.home / "homebrew" / "bin"
        standard_bin.mkdir(parents=True)
        (standard_bin / "broken").symlink_to(standard_bin / "missing")
        (standard_bin / "directory").mkdir()
        environment = {
            "HOME": str(self.home),
            "PATH": f":{relative_bin.name}",
        }

        with mock.patch("herdr_harness.fleet._STANDARD_EXECUTABLE_DIRECTORIES", (standard_bin,)):
            self.assertIsNone(_which(environment, "relative-only"))
            self.assertIsNone(_which(environment, "broken"))
            self.assertIsNone(_which(environment, "directory"))
            self.assertIsNone(_which(environment, "../not-a-command"))

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
        # The operator's fixture may have an initialized accidental gitlink in
        # its working tree.  Clone the committed parent tree so this schema
        # check is independent of that local population and exercises the same
        # state that a fresh machine receives.
        clean_fixture = Path(self.temporary.name) / "exact-catalog"
        self._git("clone", str(fixture), str(clean_fixture))
        manager = FleetManager(
            environ={
                "HOME": str(home),
                "HERDR_FLEET_CATALOG_PATH": str(clean_fixture),
                "HERDR_FLEET_CATALOG_REPOSITORY": str(fixture),
                "HERDR_FLEET_TEST_MODE": "1",
            }
        )
        response = manager.inventory()
        self.assertEqual(response["catalog"]["itemCounts"], {"skills": 172, "piExtensions": 7, "cli": 7})
        self.assertEqual(len(response["items"]), 186)
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
