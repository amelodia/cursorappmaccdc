"""Dialogo di prova sulla rete locale: accoppiamento, righe nuove, stessa riga."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography.fernet import Fernet

import data_workspace
import light_enc_sidecar
import light_lan_sync


def _main_db() -> dict:
    return {
        "years": [
            {
                "year": 2026,
                "accounts": [{"code": "1", "name": "Cassa"}],
                "categories": [{"code": "10", "name": "Spesa"}],
                "records": [
                    {
                        "year": 2026,
                        "date_iso": "2026-11-20",
                        "amount_eur": "-5.00",
                        "note": "già sul mac",
                        "category_code": "10",
                        "account_primary_code": "1",
                        "legacy_registration_key": "APP:desktop:1",
                        "source_index": 1,
                        "registration_number": 1,
                        "conti_light_record_id": "desk-1",
                    }
                ],
            }
        ]
    }


class LightLanSyncTests(unittest.TestCase):
    def test_private_peer_only(self) -> None:
        self.assertTrue(light_lan_sync._private_peer("127.0.0.1"))
        self.assertTrue(light_lan_sync._private_peer("192.168.1.20"))
        self.assertFalse(light_lan_sync._private_peer("8.8.8.8"))

    def test_pair_push_pull_and_same_row(self) -> None:
        db = _main_db()

        def snapshot() -> dict:
            return {"years": db["years"], "user_profile": {"email": "a@b.c"}}

        def apply_records(records: list) -> tuple[int, dict]:
            light = light_lan_sync.light_db_from_records(records)
            n_new, n_up = light_enc_sidecar.merge_light_sidecar_into_main(db, light)
            return n_new + n_up, snapshot()

        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            key = Fernet.generate_key()
            key_path = folder / "conti_di_casa.key"
            key_path.write_bytes(key)
            server = light_lan_sync.LightLanServer(
                folder,
                key_path,
                snapshot=snapshot,
                apply_records=apply_records,
            )
            port = server.start()
            try:
                with light_lan_sync.LanConnection("127.0.0.1", port) as client:
                    bad = client.call({"op": "pair", "code": "000000"})
                    self.assertEqual(bad.get("op"), "error")
                with light_lan_sync.LanConnection("127.0.0.1", port) as client:
                    ok = client.call({"op": "pair", "code": server.pairing_code})
                    self.assertEqual(ok.get("op"), "pair_ok")
                    self.assertTrue(ok.get("token"))
                    token = ok["token"]
                    pushed = client.call(
                        {
                            "op": "push",
                            "records": [
                                {
                                    "year": 2026,
                                    "date_iso": "2026-11-21",
                                    "amount_eur": "-12.50",
                                    "note": "dal telefono",
                                    "category_code": "10",
                                    "account_primary_code": "1",
                                    "conti_light_record_id": "phone-1",
                                }
                            ],
                        }
                    )
                    self.assertEqual(pushed.get("op"), "push_ok")
                    self.assertGreaterEqual(int(pushed.get("accepted") or 0), 1)
                    notes = [
                        r.get("note")
                        for y in db["years"]
                        for r in y["records"]
                    ]
                    self.assertIn("dal telefono", notes)
                    self.assertIn("già sul mac", notes)
                    edited = client.call(
                        {
                            "op": "push",
                            "records": [
                                {
                                    "year": 2026,
                                    "date_iso": "2026-11-20",
                                    "amount_eur": "-5.00",
                                    "note": "corretta dal telefono",
                                    "category_code": "10",
                                    "account_primary_code": "1",
                                    "legacy_registration_key": "APP:desktop:1",
                                    "conti_light_record_id": "desk-1",
                                }
                            ],
                        }
                    )
                    self.assertEqual(edited.get("op"), "push_ok")
                with light_lan_sync.LanConnection("127.0.0.1", port) as again:
                    again_ok = again.call({"op": "pair", "token": token})
                    self.assertEqual(again_ok.get("op"), "pair_ok")
                    pulled = again.call({"op": "pull"})
                    self.assertEqual(pulled.get("op"), "pull_ok")
                    pulled_notes = [
                        r.get("note")
                        for y in pulled["light"]["years"]
                        for r in y["records"]
                    ]
                    self.assertIn("corretta dal telefono", pulled_notes)
                    self.assertEqual(
                        sum(1 for n in pulled_notes if n == "corretta dal telefono"),
                        1,
                    )
                    cancelled = again.call(
                        {
                            "op": "push",
                            "records": [
                                {
                                    "year": 2026,
                                    "date_iso": "2026-11-20",
                                    "amount_eur": "-5.00",
                                    "note": "corretta dal telefono",
                                    "category_code": "10",
                                    "account_primary_code": "1",
                                    "legacy_registration_key": "APP:desktop:1",
                                    "conti_light_record_id": "desk-1",
                                    "is_cancelled": True,
                                }
                            ],
                        }
                    )
                    self.assertEqual(cancelled.get("op"), "push_ok")
                    row = next(
                        r
                        for y in db["years"]
                        for r in y["records"]
                        if r.get("legacy_registration_key") == "APP:desktop:1"
                    )
                    self.assertTrue(row.get("is_cancelled"))
                    self.assertEqual(
                        sum(1 for y in db["years"] for r in y["records"]),
                        2,
                    )
                    light_lan_sync._data_revision = 0
                    light_lan_sync.bump_data_revision()
                    rev = again.call({"op": "revision"})
                    self.assertEqual(rev.get("revision"), 1)
            finally:
                server.stop()

    def test_isolated_backups_stay_inside_prova(self) -> None:
        data_workspace._isolated_process_workspace = False
        data_workspace._workspace_root = None
        try:
            with tempfile.TemporaryDirectory() as td:
                prova = Path(td) / "dati"
                prova.mkdir()
                data_workspace._isolated_process_workspace = True
                data_workspace.set_data_workspace_root(prova)
                import main_app

                support = main_app._user_library_conti_support_dir()
                self.assertEqual(support, prova.resolve() / "_support_prova")
                backup = main_app.user_local_backup_enc_path(prova / "conti_utente_abc.enc")
                self.assertTrue(str(backup).startswith(str(prova.resolve())))
                self.assertNotIn(
                    "Application Support/ContiDiCasa/conti_utente",
                    str(backup),
                )
                saldo = main_app._virtuale_saldo_path()
                self.assertTrue(str(saldo).startswith(str(prova.resolve())))
        finally:
            data_workspace._isolated_process_workspace = False
            data_workspace._workspace_root = None

    def test_everyday_support_dir_unchanged_without_isolation(self) -> None:
        data_workspace._isolated_process_workspace = False
        import main_app

        with patch.object(data_workspace, "using_isolated_process_workspace", return_value=False):
            path = main_app._user_library_conti_support_dir()
        self.assertEqual(
            path,
            Path.home() / "Library" / "Application Support" / "ContiDiCasa",
        )


class LightLanStateDirTests(unittest.TestCase):
    def test_temporary_folder_keeps_its_own_state(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            self.assertEqual(light_lan_sync.lan_state_dir(folder), folder.resolve())
            (folder / "PROVA_ISOLATA.txt").write_text("prova\n", encoding="utf-8")
            self.assertEqual(light_lan_sync.lan_state_dir(folder), folder.resolve())

    def test_live_workspace_keeps_lan_files_outside_the_data_folder(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            with (
                patch.object(data_workspace, "using_isolated_process_workspace", return_value=False),
                patch.object(data_workspace, "_workspace_root", None),
                patch.object(
                    data_workspace,
                    "_saved_workspace_path_without_writing",
                    return_value=folder.resolve(),
                ),
            ):
                state = light_lan_sync.lan_state_dir(folder)
            self.assertNotEqual(state.resolve(), folder.resolve())
            self.assertTrue(state.name == "lan")
            self.assertIn("ContiDiCasa", str(state))


class LightMdnsAnnouncementTests(unittest.TestCase):
    def test_packet_names_the_everyday_service_and_port(self) -> None:
        packet = light_lan_sync.mdns_announcement_packet("Conti di casa", 43210, "192.168.1.20")
        self.assertIn(bytes([len("Conti di casa")]) + b"Conti di casa", packet)
        self.assertIn(b"\x09_conticdc", packet)
        self.assertIn((43210).to_bytes(2, "big"), packet)
        self.assertIn(bytes([192, 168, 1, 20]), packet)

    def test_everyday_name_is_the_one_the_phone_looks_for(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            self.assertEqual(light_lan_sync.lan_service_name(folder), "Conti di casa")
            (folder / "PROVA_ISOLATA.txt").write_text("prova\n", encoding="utf-8")
            self.assertEqual(light_lan_sync.lan_service_name(folder), "Conti prova")


class LightPhoneWaitingFlagTests(unittest.TestCase):
    def test_flag_sits_in_the_dropbox_data_folder(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            path = light_lan_sync.phone_waiting_flag_path(folder)
            self.assertEqual(path, folder / "conti_light_da_inviare.flag")
            path.write_text("1\n", encoding="utf-8")
            self.assertTrue(light_lan_sync.phone_waiting_flag_present(folder))
            light_lan_sync.clear_phone_waiting_flag(folder)
            self.assertFalse(light_lan_sync.phone_waiting_flag_present(folder))


class LightExchangeNoticeTests(unittest.TestCase):
    def test_notice_names_direction_and_count(self) -> None:
        self.assertEqual(
            light_lan_sync.exchange_notice(),
            "Scambio riuscito. Nessuna modifica.",
        )
        self.assertEqual(
            light_lan_sync.exchange_notice(to_phone=1),
            "Scambio riuscito. 1 registrazione aggiunta o modificata da Desktop a Cellulare.",
        )
        self.assertEqual(
            light_lan_sync.exchange_notice(to_mac=2),
            "Scambio riuscito. 2 registrazioni aggiunte o modificate da Cellulare a Desktop.",
        )

    def test_phone_reports_the_same_sentence(self) -> None:
        seen: list[str] = []

        def snapshot() -> dict:
            return {"years": []}

        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            key_path = folder / "conti_di_casa.key"
            key_path.write_bytes(Fernet.generate_key())
            server = light_lan_sync.LightLanServer(
                folder,
                key_path,
                snapshot=snapshot,
                apply_records=lambda _records: (0, snapshot()),
                on_status=seen.append,
            )
            port = server.start()
            try:
                with light_lan_sync.LanConnection("127.0.0.1", port) as client:
                    client.call({"op": "pair", "code": server.pairing_code})
                    reply = client.call({"op": "result", "to_phone": 3, "to_mac": 0})
                    self.assertEqual(reply.get("op"), "result_ok")
            finally:
                server.stop()
        self.assertIn(
            "Scambio riuscito. 3 registrazioni aggiunte o modificate da Desktop a Cellulare.",
            seen,
        )


class LightPendingNoticeTests(unittest.TestCase):
    def test_closed_mac_marks_waiting_without_writing_rows(self) -> None:
        db = _main_db()
        applied = {"n": 0}

        def apply_records(records: list) -> tuple[int, dict]:
            applied["n"] += 1
            return 0, {"years": db["years"]}

        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            (folder / "PROVA_ISOLATA.txt").write_text("prova\n", encoding="utf-8")
            key_path = folder / "conti_di_casa.key"
            key_path.write_bytes(Fernet.generate_key())
            server = light_lan_sync.LightLanServer(
                folder,
                key_path,
                snapshot=lambda: {"years": db["years"]},
                apply_records=apply_records,
            )
            server.notice_only = True
            port = server.start()
            try:
                with light_lan_sync.LanConnection("127.0.0.1", port) as client:
                    ok = client.call({"op": "pair", "code": server.pairing_code})
                    self.assertEqual(ok.get("op"), "pair_ok")
                    refused = client.call(
                        {
                            "op": "push",
                            "records": [
                                {
                                    "year": 2026,
                                    "date_iso": "2026-11-22",
                                    "amount_eur": "-3.00",
                                    "note": "solo sul telefono",
                                    "conti_light_record_id": "phone-1",
                                }
                            ],
                        }
                    )
                    self.assertEqual(refused.get("error"), "app_chiusa")
                    self.assertEqual(light_lan_sync.read_light_pending_count(folder), 1)
                    self.assertEqual(applied["n"], 0)
                    self.assertEqual(len(db["years"][0]["records"]), 1)
                    cleared = client.call({"op": "pending", "count": 0})
                    self.assertEqual(cleared.get("op"), "pending_ok")
                    self.assertEqual(light_lan_sync.read_light_pending_count(folder), 0)
            finally:
                server.stop()

    def test_saved_push_clears_pending_flag(self) -> None:
        db = _main_db()

        def snapshot() -> dict:
            return {"years": db["years"]}

        def apply_records(records: list) -> tuple[int, dict]:
            light = light_lan_sync.light_db_from_records(records)
            light_enc_sidecar.merge_light_sidecar_into_main(db, light)
            return 1, snapshot()

        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            key_path = folder / "conti_di_casa.key"
            key_path.write_bytes(Fernet.generate_key())
            light_lan_sync.write_light_pending(folder, 2)
            server = light_lan_sync.LightLanServer(
                folder,
                key_path,
                snapshot=snapshot,
                apply_records=apply_records,
            )
            port = server.start()
            try:
                with light_lan_sync.LanConnection("127.0.0.1", port) as client:
                    client.call({"op": "pair", "code": server.pairing_code})
                    saved = client.call(
                        {
                            "op": "push",
                            "records": [
                                {
                                    "year": 2026,
                                    "date_iso": "2026-11-22",
                                    "amount_eur": "-3.00",
                                    "note": "arrivata",
                                    "conti_light_record_id": "phone-2",
                                }
                            ],
                        }
                    )
                    self.assertEqual(saved.get("op"), "push_ok")
                    self.assertEqual(light_lan_sync.read_light_pending_count(folder), 0)
            finally:
                server.stop()


if __name__ == "__main__":
    unittest.main()
