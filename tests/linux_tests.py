import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "linux"))

from game_downgrade import swap, updatelock


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


if __name__ == "__main__":
    unittest.main()
