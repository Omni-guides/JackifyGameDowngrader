import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "linux"))
if sys.platform == "win32":
    sys.modules["pty"] = ModuleType("pty")

from game_downgrade import cli, paths, steam_lifecycle, swap, updatelock


class LinuxTests(unittest.TestCase):
    def test_shared_games(self):
        files = sorted(path.stem for path in (ROOT / "games").glob("*.json"))
        self.assertEqual(files, ["fallout4", "fallout4_ck", "skyrim_se", "skyrim_se_ck"])

    def test_creation_kit_definitions_and_recommendations(self):
        skyrim = cli.load_game("skyrim_se_ck")
        fallout = cli.load_game("fallout4_ck")
        self.assertEqual(skyrim["appid"], 1946180)
        self.assertEqual(skyrim["versions"]["1.6.438"]["recommended_for"], ["1.6.640"])
        self.assertEqual(fallout["appid"], 1946160)
        self.assertEqual(fallout["versions"]["1.10.162"]["recommended_for"], ["1.10.163"])
        self.assertEqual(fallout["versions"]["1.10.982.3"]["recommended_for"], ["1.10.984"])
        self.assertEqual(fallout["versions"]["1.11.221"]["recommended_for"], ["1.11.221"])

    def test_fallout_manifest_selection_is_language_and_dlc_aware(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game_path = root / "Fallout 4"
            (game_path / "Data").mkdir(parents=True)
            (game_path / "Data" / "DLCRobot.esm").write_text("")
            acf = root / "appmanifest_377160.acf"
            install = cli.steam_paths.GameInstall(game_path, root, acf, None, "1.11.240", "english")
            game = cli.load_game("fallout4")
            manifests = cli._resolve_manifests(game, game["versions"]["1.11.221"], install)
            self.assertIn("377164", manifests)
            self.assertIn("435870", manifests)
            self.assertIn("435871", manifests)
            self.assertNotIn("435880", manifests)
            install.language = "german"
            with self.assertRaisesRegex(RuntimeError, "Supported language: english"):
                cli._resolve_manifests(game, game["versions"]["1.11.221"], install)

    def test_missing_creation_kit_returns_to_interactive_menu(self):
        game = cli.load_game("skyrim_se_ck")
        with patch(
            "game_downgrade.cli.steam_paths.find_game", return_value=None
        ), patch("builtins.input", return_value=""):
            result = cli.cmd_downgrade(
                argparse.Namespace(
                    game="skyrim_se_ck", version=None, dry_run=False,
                    no_backup=False, return_to_menu=True,
                )
            )
        self.assertEqual(cli.RETURN_TO_MENU, result)

    def test_interactive_menu_reopens_after_completed_operation(self):
        with patch("builtins.input", side_effect=["1", "", "6"]), patch(
            "game_downgrade.cli.cmd_downgrade",
            return_value=0,
        ) as downgrade:
            result = cli.cmd_interactive(argparse.Namespace())
        self.assertEqual(0, result)
        self.assertEqual(1, downgrade.call_count)

    def test_update_behavior_round_trip(self):
        text = '"apps"\n{\n"489830"\n{\n"AutoUpdateBehavior" "0"\n}\n}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "localconfig.vdf"
            path.write_text(text)
            prior = updatelock.set_manual_update(path, 489830)
            self.assertEqual(prior, "0")
            self.assertIn('"AutoUpdateBehavior"\t\t"1"', path.read_text())
            updatelock.revert_update_behavior(path, 489830, prior)
            self.assertIn('"AutoUpdateBehavior"\t\t"0"', path.read_text())

    def test_persistent_state_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_root = root / "old"
            old_state = old_root / "skyrim_se" / "state.json"
            old_state.parent.mkdir(parents=True)
            content = '{"version": "1.6.1170"}'
            old_state.write_text(content)
            with patch.object(paths, "ROOT_DATA_DIR", old_root), patch.dict(
                "os.environ", {"JGD_STATE_DIR": str(root / "state")}
            ):
                state_dir = paths.game_data_dir("skyrim_se")
            self.assertEqual(state_dir, root / "state" / "skyrim_se")
            self.assertEqual((state_dir / "state.json").read_text(), content)
            self.assertFalse(old_state.exists())

    def test_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game"
            depot = root / "content" / "depot_1"
            game.mkdir()
            depot.mkdir(parents=True)
            (game / "old.txt").write_text("old")
            (depot / "old.txt").write_text("new")
            (depot / "new.txt").write_text("new")
            stale = root / "content" / "depot_999"
            stale.mkdir()
            (stale / "stale.txt").write_text("stale")
            overwrite, new = swap.preview_downgrade(game, depot.parent)
            self.assertEqual(overwrite, ["old.txt"])
            self.assertEqual(new, ["new.txt", "stale.txt"])
            overwrite, new = swap.preview_downgrade(game, depot.parent, ["1"])
            self.assertEqual(overwrite, ["old.txt"])
            self.assertEqual(new, ["new.txt"])
            backup = swap.apply_downgrade(
                game, depot.parent, "1.0", "2.0", None, root / "state",
                create_backup=False,
                localconfigs=[{"path": "/one", "prior_value": "0"}, {"path": "/two", "prior_value": None}],
            )
            self.assertIsNone(backup)
            state = json.loads((root / "state" / "state.json").read_text())
            self.assertIsNone(state["backup_path"])
            self.assertEqual(len(state["localconfigs"]), 2)
            backup_dir = root / "backup"
            backup_dir.mkdir()
            (backup_dir / "original.txt").write_text("original")
            swap.reset_game_from_backup(game, backup_dir)
            self.assertTrue((game / "original.txt").is_file())
            self.assertTrue((backup_dir / "original.txt").is_file())

    def test_component_backup_restores_only_component_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "shared-game"
            depot = root / "content" / "depot_1"
            state_dir = root / "state"
            install.mkdir()
            depot.mkdir(parents=True)
            (install / "game.exe").write_text("game untouched")
            (install / "CreationKit.exe").write_text("new CK")
            (depot / "CreationKit.exe").write_text("old CK")
            (depot / "ck-added.ini").write_text("old setting")

            backup = swap.apply_component_downgrade(
                install, depot.parent, "1.0", "2.0", None, state_dir
            )
            self.assertEqual((install / "CreationKit.exe").read_text(), "old CK")
            self.assertEqual((install / "game.exe").read_text(), "game untouched")
            self.assertTrue(backup.is_dir())

            swap.restore_component_from_state(state_dir)
            self.assertEqual((install / "CreationKit.exe").read_text(), "new CK")
            self.assertEqual((install / "game.exe").read_text(), "game untouched")
            self.assertFalse((install / "ck-added.ini").exists())

    def test_component_no_backup_records_settings_only_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "shared-game"
            depot = root / "content" / "depot_1"
            state_dir = root / "state"
            install.mkdir()
            depot.mkdir(parents=True)
            (install / "CreationKit.exe").write_text("current CK")
            (depot / "CreationKit.exe").write_text("old CK")

            backup = swap.apply_component_downgrade(
                install, depot.parent, "1.0", "2.0", None, state_dir,
                create_backup=False,
            )

            self.assertIsNone(backup)
            self.assertEqual("old CK", (install / "CreationKit.exe").read_text())
            self.assertEqual([], swap.load_state(state_dir)["component_backup"])
            self.assertFalse((state_dir / "file-backup").exists())

    def test_component_retarget_retains_zero_one_and_many_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "shared-game"
            first_depot = root / "first-content" / "depot_1"
            second_depot = root / "second-content" / "depot_1"
            state_dir = root / "state"
            install.mkdir()
            first_depot.mkdir(parents=True)
            second_depot.mkdir(parents=True)
            (install / "CreationKit.exe").write_text("current CK")
            (install / "new-tool.exe").write_text("current tool")
            (first_depot / "CreationKit.exe").write_text("first old CK")
            (first_depot / "added.ini").write_text("first added file")

            swap.apply_component_downgrade(
                install, first_depot.parent, "1.0", "2.0", None, state_dir
            )
            first_state = swap.load_state(state_dir)
            self.assertEqual(2, len(first_state["component_backup"]))

            (second_depot / "CreationKit.exe").write_text("second old CK")
            (second_depot / "new-tool.exe").write_text("old tool")
            swap.apply_component_downgrade(
                install, second_depot.parent, "0.9", "1.0", None, state_dir,
                create_backup=False, existing_state=first_state,
            )
            second_state = swap.load_state(state_dir)
            self.assertEqual(3, len(second_state["component_backup"]))

            swap.restore_component_from_state(state_dir)
            self.assertEqual("current CK", (install / "CreationKit.exe").read_text())
            self.assertEqual("current tool", (install / "new-tool.exe").read_text())
            self.assertFalse((install / "added.ini").exists())

    def test_component_retarget_normalizes_legacy_single_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "shared-game"
            depot = root / "content" / "depot_1"
            state_dir = root / "state"
            backup_dir = state_dir / "file-backup"
            install.mkdir()
            depot.mkdir(parents=True)
            backup_dir.mkdir(parents=True)
            (install / "CreationKit.exe").write_text("first downgrade")
            (install / "tool.exe").write_text("current tool")
            (depot / "tool.exe").write_text("old tool")
            (backup_dir / "CreationKit.exe").write_text("original CK")
            legacy_state = {
                "game_path": str(install),
                "backup_path": None,
                "component_backup": {"path": "CreationKit.exe", "existed": True},
            }

            swap.apply_component_downgrade(
                install, depot.parent, "0.9", "1.0", None, state_dir,
                create_backup=False, existing_state=legacy_state,
            )
            self.assertEqual(2, len(swap.load_state(state_dir)["component_backup"]))

            swap.restore_component_from_state(state_dir)
            self.assertEqual("original CK", (install / "CreationKit.exe").read_text())
            self.assertEqual("current tool", (install / "tool.exe").read_text())

    def test_backup_copy_failure_leaves_settings_only_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game"
            depot = root / "content" / "depot_1"
            state_dir = root / "state"
            game.mkdir()
            depot.mkdir(parents=True)
            (game / "game.exe").write_text("current")
            (depot / "game.exe").write_text("old")

            with patch("game_downgrade.swap.shutil.copytree", side_effect=OSError("copy failed")):
                with self.assertRaises(OSError):
                    swap.apply_downgrade(
                        game, depot.parent, "1.0", "2.0", None, state_dir,
                        localconfigs=[{"path": "/config", "prior_value": "0"}],
                    )

            state = swap.load_state(state_dir)
            self.assertIsNotNone(state)
            self.assertIsNone(state["backup_path"])
            self.assertEqual("0", state["localconfigs"][0]["prior_value"])
            self.assertEqual("current", (game / "game.exe").read_text())
            self.assertFalse(any(root.glob(".jgd-backup-staging-*")))

    def test_component_backup_failure_leaves_restorable_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "shared-game"
            depot = root / "content" / "depot_1"
            state_dir = root / "state"
            install.mkdir()
            depot.mkdir(parents=True)
            (install / "CreationKit.exe").write_text("current")
            (depot / "CreationKit.exe").write_text("old")

            with patch("game_downgrade.swap.shutil.copy2", side_effect=OSError("copy failed")):
                with self.assertRaises(OSError):
                    swap.apply_component_downgrade(
                        install, depot.parent, "1.0", "2.0", None, state_dir,
                        localconfigs=[{"path": "/config", "prior_value": "0"}],
                    )

            state = swap.load_state(state_dir)
            self.assertEqual([], state["component_backup"])
            self.assertEqual("0", state["localconfigs"][0]["prior_value"])
            self.assertEqual("current", (install / "CreationKit.exe").read_text())
            self.assertFalse(any(state_dir.glob("file-backup-staging-*")))

    def test_backup_state_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game"
            depot = root / "content" / "depot_1"
            game.mkdir()
            depot.mkdir(parents=True)
            (game / "game.exe").write_text("old")
            (depot / "game.exe").write_text("new")
            backup = swap.apply_downgrade(
                game, depot.parent, "1.0", "2.0", None, root / "state"
            )
            self.assertIsNotNone(backup)
            marker = swap.load_backup_state(backup)
            self.assertEqual(marker["backup_path"], str(backup))
            swap.restore_from_state(root / "state")
            self.assertFalse((game / swap.BACKUP_STATE).exists())

    def test_retarget_with_missing_backup_continues_without_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game"
            depot = root / "content" / "depot_1"
            game.mkdir()
            depot.mkdir(parents=True)
            (game / "game.exe").write_text("old")
            (depot / "game.exe").write_text("new")
            state = {
                "game_path": str(game),
                "backup_path": str(root / "missing-backup"),
                "version": "1.0",
            }

            backup = swap.apply_downgrade(
                game, depot.parent, "2.0", "1.0", None, root / "state",
                create_backup=False,
                existing_state=state,
            )

            self.assertIsNone(backup)
            self.assertEqual((game / "game.exe").read_text(), "new")
            saved_state = swap.load_state(root / "state")
            self.assertIsNone(saved_state["backup_path"])

    def test_recover_missing_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game_path = root / "Skyrim Special Edition"
            game_path.mkdir()
            acf = root / "appmanifest_489830.acf"
            acf.write_text("test")
            for name in ("Skyrim Special Edition (1.6.1170.0)", "Skyrim Special Edition (1.7.99.0)"):
                backup = root / name
                backup.mkdir()
                (backup / "SkyrimSE.exe").write_text("test")
            install = cli.steam_paths.GameInstall(game_path, root, acf, None, "1.6.1170.0")
            game = {"appid": 489830, "main_exe": "SkyrimSE.exe", "name": "Skyrim Special Edition"}
            with patch("game_downgrade.cli.steam_paths.find_game", return_value=install), patch(
                "game_downgrade.cli.read_file_version", return_value=None
            ), patch("builtins.input", return_value="2"):
                state = cli._recover_state(game, root / "state")
            self.assertTrue(state["recovered"])
            self.assertTrue(state["backup_path"].endswith("Skyrim Special Edition (1.7.99.0)"))

    @patch("game_downgrade.steam_lifecycle._stop_process")
    @patch("game_downgrade.steam_lifecycle._wait_for_exit")
    @patch("game_downgrade.steam_lifecycle._run")
    @patch("game_downgrade.steam_lifecycle._is_flatpak_running", return_value=False)
    @patch("game_downgrade.steam_lifecycle._is_steam_deck", return_value=True)
    @patch("game_downgrade.steam_lifecycle.is_running", side_effect=[True, False, False])
    def test_stop_steam_deck(self, _running, _deck, _flatpak, run, _wait, stop_process):
        run.return_value.returncode = 0
        session = steam_lifecycle.stop("SkyrimSE.exe")
        self.assertTrue(session.running)
        self.assertTrue(session.steam_deck)
        run.assert_any_call(["systemctl", "--user", "stop", "app-steam@autostart.service"])
        stop_process.assert_called_once_with("SkyrimSE.exe")

    @patch("game_downgrade.steam_lifecycle.time.sleep")
    @patch("game_downgrade.steam_lifecycle.is_running", return_value=True)
    @patch("game_downgrade.steam_lifecycle.subprocess.Popen")
    def test_start_steam_deck(self, popen, _running, _sleep):
        session = steam_lifecycle.Session(True, True, False)
        self.assertTrue(steam_lifecycle.start(session))
        self.assertEqual(
            popen.call_args.args[0],
            ["systemctl", "--user", "restart", "app-steam@autostart.service"],
        )

    def test_managed_restart_flags(self):
        with patch("game_downgrade.cli.cmd_downgrade", return_value=0) as downgrade:
            self.assertEqual(
                cli.main(["downgrade", "--game", "skyrim_se", "--managed-restart"]),
                0,
            )
            self.assertTrue(downgrade.call_args.args[0].managed_restart)
        with patch("game_downgrade.cli.cmd_restore", return_value=0) as restore:
            self.assertEqual(
                cli.main(["restore", "--game", "skyrim_se", "--managed-restart"]),
                0,
            )
            self.assertTrue(restore.call_args.args[0].managed_restart)


if __name__ == "__main__":
    unittest.main()
