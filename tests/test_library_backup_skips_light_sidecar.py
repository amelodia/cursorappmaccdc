"""Il ripristino da Library non deve prendere il sidecar ``*_light_backup.enc``."""
from __future__ import annotations

from pathlib import Path

import main_app


def test_discover_skips_light_sidecar_backup(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(main_app, "_user_library_conti_support_dir", lambda: tmp_path)
    full = tmp_path / "conti_utente_abc_backup.enc"
    light = tmp_path / "conti_utente_abc_light_backup.enc"
    full.write_bytes(b"x" * 300)
    light.write_bytes(b"y" * 300)

    found = main_app._discover_library_backup_enc_files()

    assert [p.name for p in found] == ["conti_utente_abc_backup.enc"]


def test_light_backup_is_not_a_full_restore_target(tmp_path: Path) -> None:
    light = tmp_path / "conti_utente_abc_light_backup.enc"
    assert main_app.primary_enc_path_from_library_backup_filename(light) is None
    assert main_app._is_light_sidecar_backup_name(light)
    assert main_app._db_dict_is_light_sidecar({"light_sidecar_generated_at": "2026-10-16"})
    assert not main_app._db_dict_is_light_sidecar({"years": []})
