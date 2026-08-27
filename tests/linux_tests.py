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
        self.assertEqual(files, ["fallout4", "skyrim_se"])

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
            overwrite, new = swap.preview_downgrade(game, depot.parent)
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
