"""La sessione di prova non registra la propria cartella come cartella operativa."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import data_workspace


def _reset() -> None:
    data_workspace._workspace_root = None
    data_workspace._isolated_process_workspace = False


class IsolatedWorkspaceTests(unittest.TestCase):
    def tearDown(self) -> None:
        _reset()

    def test_override_ignored_without_env(self) -> None:
        _reset()
        with patch.dict("os.environ", {}, clear=False):
            import os

            os.environ.pop("CONTI_DATA_WORKSPACE", None)
            self.assertIsNone(data_workspace.process_workspace_override_path())

    def test_isolated_session_does_not_write_operational_config(self) -> None:
        _reset()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config = root / "config" / "data_workspace.json"
            config.parent.mkdir()
            operational = root / "operativa"
            operational.mkdir()
            config.write_text(
                json.dumps({"workspace_path": str(operational)}) + "\n",
                encoding="utf-8",
            )
            prova = root / "prova"
            prova.mkdir()
            (prova / "conti_di_casa.key").write_bytes(b"test-key")
            (prova / "conti_utente_abc.enc").write_bytes(b"enc")
            (prova / "PROVA_ISOLATA.txt").write_text("prova\n", encoding="utf-8")
            with (
                patch.object(data_workspace, "_iter_workspace_config_paths", lambda: [config]),
                patch.dict("os.environ", {"CONTI_DATA_WORKSPACE": str(prova)}),
            ):
                chosen = data_workspace.process_workspace_override_path()
                self.assertEqual(chosen, prova.resolve())
                data_workspace._isolated_process_workspace = True
                data_workspace.set_data_workspace_root(chosen)
                data_workspace.save_last_login_email("altro@example.com")
                data_workspace.save_workspace_path(chosen)
                stored = json.loads(config.read_text(encoding="utf-8"))
                self.assertEqual(stored["workspace_path"], str(operational))
                self.assertNotIn("last_login_email", stored)
                with self.assertRaises(RuntimeError):
                    data_workspace.set_data_workspace_root(operational)
                self.assertEqual(data_workspace.data_dir(), prova.resolve())

    def test_override_refuses_operational_folder(self) -> None:
        _reset()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            operational = root / "operativa"
            operational.mkdir()
            (operational / "conti_di_casa.key").write_bytes(b"k")
            (operational / "conti_utente_abc.enc").write_bytes(b"e")
            (operational / "PROVA_ISOLATA.txt").write_text("no\n", encoding="utf-8")
            config = root / "data_workspace.json"
            config.write_text(
                json.dumps({"workspace_path": str(operational.resolve())}) + "\n",
                encoding="utf-8",
            )
            with (
                patch.object(data_workspace, "_iter_workspace_config_paths", lambda: [config]),
                patch.dict("os.environ", {"CONTI_DATA_WORKSPACE": str(operational)}),
            ):
                with self.assertRaises(RuntimeError):
                    data_workspace.process_workspace_override_path()


if __name__ == "__main__":
    unittest.main()
