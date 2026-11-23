"""Dialogo fra il desktop e Conti Light, sulla rete locale.

Il Mac è l'unico che scrive il database. Il telefono invia solo le righe
cambiate e le conserva finché il Mac non conferma il salvataggio.
Il database resta nella cartella dati (su Dropbox per l'uso normale).
I file di accoppiamento e di avviso dell'uso normale restano fuori da Dropbox.
"""

from __future__ import annotations

import ipaddress
import json
import os
import secrets
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from cryptography.fernet import Fernet, InvalidToken

SERVICE_TYPE = "_conticdc._tcp"
_MDNS_ADDR = "224.0.0.251"
_MDNS_PORT = 5353
MAX_MESSAGE_BYTES = 16 * 1024 * 1024
PEER_FILE_NAME = "lan_prova_peer.json"
PENDING_FILE_NAME = "lan_light_pending.json"
PHONE_WAITING_FLAG = "conti_light_da_inviare.flag"
GUI_LOCK_NAME = "lan_gui_ascolto.txt"
PID_FILE_NAME = "lan_avviso_light.pid"
_data_revision = 0


def bump_data_revision() -> int:
    """Segna che il database è cambiato. Il telefono lo chiede senza riscaricare tutto."""
    global _data_revision
    _data_revision += 1
    return _data_revision


def current_data_revision() -> int:
    return _data_revision


def _mdns_encode_name(name: str) -> bytes:
    out = b""
    for part in name.strip(".").split("."):
        raw = part.encode("utf-8")
        if len(raw) > 63:
            raw = raw[:63]
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def _mdns_rr(name: str, rtype: int, ttl: int, rdata: bytes) -> bytes:
    return _mdns_encode_name(name) + struct.pack("!HHIH", rtype, 1, ttl, len(rdata)) + rdata


def lan_service_name(data_dir: Path) -> str:
    if (Path(data_dir) / "PROVA_ISOLATA.txt").is_file():
        return "Conti prova"
    return "Conti di casa"


def _lan_ipv4() -> str:
    """Indirizzo della rete usata dal computer, non un adattatore virtuale."""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.0.2.1", 9))
            ip = str(probe.getsockname()[0])
        finally:
            probe.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    return ""


def mdns_announcement_packet(name: str, port: int, ip: str, *, ttl: int = 120) -> bytes:
    """Risposta mDNS che presenta Conti di casa sulla rete locale."""
    service = f"{SERVICE_TYPE}.local."
    instance = f"{name}.{SERVICE_TYPE}.local."
    host_label = socket.gethostname().split(".")[0]
    host_label = "".join(ch if ch.isalnum() or ch == "-" else "-" for ch in host_label).strip("-")
    host = f"{host_label or 'conti-di-casa'}.local."
    records = [
        _mdns_rr(service, 12, ttl, _mdns_encode_name(instance)),
        _mdns_rr(instance, 33, ttl, struct.pack("!HHH", 0, 0, port) + _mdns_encode_name(host)),
        _mdns_rr(instance, 16, ttl, b"\x00"),
        _mdns_rr(host, 1, ttl, socket.inet_aton(ip)),
    ]
    header = struct.pack("!HHHHHH", 0, 0x8400, 0, len(records), 0, 0)
    return header + b"".join(records)


class _WindowsMdnsAnnouncer:
    """Annuncio Bonjour senza dns-sd, che su Windows non c'è."""

    def __init__(self, name: str, port: int) -> None:
        self.name = name
        self.port = port
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._sock: socket.socket | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="conti-light-mdns", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        sock = self._sock
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        thread = self._thread
        if thread is not None:
            thread.join(timeout=2)

    def _send(self, sock: socket.socket, packet: bytes) -> None:
        try:
            sock.sendto(packet, (_MDNS_ADDR, _MDNS_PORT))
        except OSError:
            pass

    def _run(self) -> None:
        ip = _lan_ipv4()
        if not ip or self.port <= 0:
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self._sock = sock
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except OSError:
            pass
        try:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        except OSError:
            pass
        bound = False
        try:
            sock.bind(("", _MDNS_PORT))
            membership = struct.pack("4s4s", socket.inet_aton(_MDNS_ADDR), socket.inet_aton("0.0.0.0"))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
            bound = True
        except OSError:
            bound = False
        sock.settimeout(0.4)
        needle = _mdns_encode_name(f"{SERVICE_TYPE}.local.")
        interval = 1.0
        next_send = 0.0
        try:
            while not self._stop.is_set():
                now = time.monotonic()
                if now >= next_send:
                    self._send(sock, mdns_announcement_packet(self.name, self.port, ip))
                    next_send = now + interval
                    interval = min(interval * 2, 30.0)
                if not bound:
                    self._stop.wait(0.4)
                    continue
                try:
                    data, _addr = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if len(data) < 12 or data[2] & 0x80:
                    continue
                if needle in data:
                    self._send(sock, mdns_announcement_packet(self.name, self.port, ip))
        finally:
            goodbye = mdns_announcement_packet(self.name, self.port, ip, ttl=0)
            self._send(sock, goodbye)
            try:
                sock.close()
            except OSError:
                pass
            self._sock = None


def lan_state_dir(data_dir: Path) -> Path:
    """Cartella dei file di rete (token, avviso, pid).

    La prova isolata li tiene nella propria cartella. L'app normale li tiene
    in Application Support, così non finiscono su Dropbox insieme al database.
    Una cartella temporanea che non è la cartella dati vera resta com'è.
    """
    data_dir = Path(data_dir).expanduser()
    try:
        resolved = data_dir.resolve()
    except OSError:
        resolved = data_dir
    if (resolved / "PROVA_ISOLATA.txt").is_file() or (data_dir / "PROVA_ISOLATA.txt").is_file():
        return resolved
    try:
        import data_workspace

        if data_workspace.using_isolated_process_workspace():
            return resolved
        root = getattr(data_workspace, "_workspace_root", None)
        if root is not None:
            live = Path(root).expanduser().resolve()
        else:
            saved = data_workspace._saved_workspace_path_without_writing()
            live = None if saved is None else Path(saved).expanduser().resolve()
    except Exception:
        return resolved
    if live is None or resolved != live:
        return resolved
    if sys.platform == "win32":
        base = (os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA") or "").strip()
        state = (Path(base) if base else Path.home() / "AppData" / "Local") / "ContiDiCasa" / "lan"
    else:
        state = Path.home() / "Library" / "Application Support" / "ContiDiCasa" / "lan"
    state.mkdir(parents=True, exist_ok=True)
    return state


def _exchange_phrase(count: int, direction: str) -> str:
    if count == 1:
        return f"1 registrazione aggiunta o modificata da {direction}."
    return f"{count} registrazioni aggiunte o modificate da {direction}."


def exchange_notice(*, to_phone: int = 0, to_mac: int = 0) -> str:
    """Testo dell'avviso di scambio: nessuna modifica, oppure il verso e il numero."""
    parts: list[str] = []
    if to_phone > 0:
        parts.append(_exchange_phrase(to_phone, "Desktop a Cellulare"))
    if to_mac > 0:
        parts.append(_exchange_phrase(to_mac, "Cellulare a Desktop"))
    if not parts:
        return "Scambio riuscito. Nessuna modifica."
    return "Scambio riuscito. " + " ".join(parts)

SnapshotFn = Callable[[], dict]
ApplyFn = Callable[[list[dict]], tuple[int, dict]]


def _private_peer(host: str) -> bool:
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return bool(ip.is_private or ip.is_loopback)


def _frame(obj: dict) -> bytes:
    body = json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_MESSAGE_BYTES:
        raise ValueError("messaggio troppo grande")
    return len(body).to_bytes(4, "big") + body


def _read_frame(conn: socket.socket) -> dict:
    header = _read_exact(conn, 4)
    size = int.from_bytes(header, "big")
    if size <= 0 or size > MAX_MESSAGE_BYTES:
        raise ValueError("lunghezza non valida")
    body = _read_exact(conn, size)
    data = json.loads(body.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("messaggio non valido")
    return data


def _read_exact(conn: socket.socket, size: int) -> bytes:
    buf = bytearray()
    while len(buf) < size:
        chunk = conn.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("connessione chiusa")
        buf.extend(chunk)
    return bytes(buf)


def seal(obj: dict, key: bytes) -> dict:
    token = Fernet(key).encrypt(
        json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    )
    return {"op": "sealed", "payload": token.decode("ascii")}


def open_sealed(msg: dict, key: bytes) -> dict:
    payload = msg.get("payload")
    if not isinstance(payload, str) or not payload:
        raise ValueError("messaggio cifrato vuoto")
    try:
        raw = Fernet(key).decrypt(payload.encode("ascii"))
    except (InvalidToken, ValueError) as exc:
        raise ValueError("messaggio non decifrabile") from exc
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("messaggio non valido")
    return data


def light_db_from_records(records: list) -> dict:
    """Raggruppa le righe inviate dal telefono nel formato anni del sidecar."""
    by_year: dict[int, list] = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        try:
            year = int(rec.get("year") or 0)
        except (TypeError, ValueError):
            continue
        if not (1500 <= year <= 3000):
            continue
        by_year.setdefault(year, []).append(rec)
    years = [
        {"year": year, "accounts": [], "categories": [], "records": rows}
        for year, rows in sorted(by_year.items())
    ]
    return {"years": years}


class LightLanServer:
    """Ascolta sulla rete locale. Un telefono alla volta, dopo l'accoppiamento."""

    def __init__(
        self,
        data_dir: Path,
        key_path: Path,
        *,
        snapshot: SnapshotFn,
        apply_records: ApplyFn,
        on_status: Callable[[str], None] | None = None,
    ) -> None:
        self.data_dir = Path(data_dir)
        self.key_path = Path(key_path)
        self.snapshot = snapshot
        self.apply_records = apply_records
        self.on_status = on_status or (lambda _text: None)
        self.notice_only = False
        self.pairing_code = f"{secrets.randbelow(1_000_000):06d}"
        self._token = self._load_token()
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._advertiser: subprocess.Popen | None = None
        self._mdns: _WindowsMdnsAnnouncer | None = None
        self._phone_seen = False
        self._stop = threading.Event()
        self.port = 0

    def peer_path(self) -> Path:
        return lan_state_dir(self.data_dir) / PEER_FILE_NAME

    def has_paired_phone(self) -> bool:
        """Vero dopo il primo accoppiamento: il telefono rientra col token, senza il codice."""
        return bool(self._token)

    def phone_seen(self) -> bool:
        """Vero se il cellulare si è collegato da quando questo ascolto è partito."""
        return self._phone_seen

    def start(self) -> int:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", 0))
        sock.listen(1)
        sock.settimeout(0.5)
        self._sock = sock
        self.port = int(sock.getsockname()[1])
        self._stop.clear()
        self._thread = threading.Thread(target=self._serve, name="conti-light-lan", daemon=True)
        self._thread.start()
        self._advertise()
        self.on_status(f"In ascolto sulla rete locale, porta {self.port}.")
        return self.port

    def stop(self) -> None:
        self._stop.set()
        sock = self._sock
        self._sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        adv = self._advertiser
        self._advertiser = None
        if adv is not None:
            adv.terminate()
            try:
                adv.wait(timeout=1)
            except subprocess.TimeoutExpired:
                adv.kill()
        mdns = self._mdns
        self._mdns = None
        if mdns is not None:
            mdns.stop()

    def _load_token(self) -> str:
        path = self.peer_path()
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return ""
        token = raw.get("token") if isinstance(raw, dict) else ""
        return str(token or "")

    def _store_token(self, token: str) -> None:
        path = self.peer_path()
        path.write_text(json.dumps({"token": token}), encoding="utf-8")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        self._token = token

    def _advertise(self) -> None:
        name = lan_service_name(self.data_dir)
        if os.name != "posix":
            self._mdns = _WindowsMdnsAnnouncer(name, self.port)
            self._mdns.start()
            return
        try:
            self._advertiser = subprocess.Popen(
                [
                    "dns-sd",
                    "-R",
                    name,
                    SERVICE_TYPE,
                    "local.",
                    str(self.port),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            self._advertiser = None

    def _serve(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                conn, addr = sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            host = str(addr[0])
            if not _private_peer(host):
                conn.close()
                continue
            threading.Thread(
                target=self._handle,
                args=(conn,),
                name="conti-light-lan-conn",
                daemon=True,
            ).start()

    def _handle(self, conn: socket.socket) -> None:
        paired = False
        try:
            key = self.key_path.read_bytes()
        except OSError:
            key = b""
        try:
            conn.settimeout(60)
            while not self._stop.is_set():
                msg = _read_frame(conn)
                if msg.get("op") == "sealed":
                    if not key:
                        conn.sendall(_frame({"op": "error", "error": "chiave assente"}))
                        return
                    msg = open_sealed(msg, key)
                op = str(msg.get("op") or "")
                reply, paired = self._dispatch(msg, op, paired)
                if paired or reply.get("op") == "pair_ok":
                    self._phone_seen = True
                failed_unpaired = reply.get("op") == "error" and not paired
                if paired and reply.get("op") != "pair_ok" and key:
                    reply = seal(reply, key)
                conn.sendall(_frame(reply))
                if failed_unpaired:
                    return
        except (OSError, ValueError, json.JSONDecodeError, ConnectionError, InvalidToken):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _dispatch(self, msg: dict, op: str, paired: bool) -> tuple[dict, bool]:
        if op == "pair":
            return self._pair(msg)
        if not paired and not self._token_ok(msg):
            return {"op": "error", "error": "non accoppiato"}, False
        if op == "pending":
            return self._pending(msg), True
        if op == "result":
            if not self.notice_only:
                self.on_status(
                    exchange_notice(
                        to_phone=_nonneg_int(msg.get("to_phone")),
                        to_mac=_nonneg_int(msg.get("to_mac")),
                    )
                )
            return {"op": "result_ok"}, True
        if self.notice_only:
            if op == "push":
                records = msg.get("records")
                count = len(records) if isinstance(records, list) else 0
                if count > 0:
                    write_light_pending(self.data_dir, count)
                return {"op": "error", "error": "app_chiusa"}, True
            return {"op": "mac_closed", "error": "app_chiusa"}, True
        if op == "revision":
            return {"op": "revision_ok", "revision": current_data_revision()}, True
        if op == "pull":
            quiet = bool(msg.get("quiet"))
            if not quiet:
                self.on_status("Scambio in corso: preparo l'elenco per il cellulare.")
            light = self.snapshot()
            revision = current_data_revision()
            if isinstance(light, dict):
                revision = int(light.pop("_lan_revision", revision))
            return {"op": "pull_ok", "light": light, "revision": revision}, True
        if op == "push":
            records = msg.get("records")
            if not isinstance(records, list):
                return {"op": "error", "error": "elenco registrazioni mancante"}, True
            self.on_status("Scambio in corso: arrivano registrazioni dal telefono.")
            accepted, light = self.apply_records(records)
            revision = current_data_revision()
            if isinstance(light, dict):
                revision = int(light.pop("_lan_revision", revision))
            clear_light_pending(self.data_dir)
            arrived = len(records)
            self.on_status(exchange_notice(to_mac=arrived if arrived > 0 else accepted))
            return {
                "op": "push_ok",
                "accepted": accepted,
                "light": light,
                "revision": revision,
            }, True
        return {"op": "error", "error": "operazione sconosciuta"}, paired

    def _pending(self, msg: dict) -> dict:
        try:
            count = int(msg.get("count") or 0)
        except (TypeError, ValueError):
            count = 0
        if count > 0:
            write_light_pending(self.data_dir, count)
        else:
            clear_light_pending(self.data_dir)
        return {"op": "pending_ok", "count": max(0, count)}

    def _token_ok(self, msg: dict) -> bool:
        token = str(msg.get("token") or "")
        return bool(token) and token == self._token

    def _pair(self, msg: dict) -> tuple[dict, bool]:
        code = str(msg.get("code") or "").strip()
        token = str(msg.get("token") or "")
        if token and token == self._token:
            self.on_status("Collegamento riuscito: il telefono di prova è di nuovo collegato.")
            return self._pair_ok(self._token), True
        if self._token and code != self.pairing_code:
            self.on_status("Codice di accoppiamento necessario per un telefono non ancora collegato.")
        if code != self.pairing_code:
            return {"op": "error", "error": "codice di accoppiamento errato"}, False
        new_token = secrets.token_urlsafe(32)
        self._store_token(new_token)
        self.on_status("Collegamento riuscito: il telefono di prova è collegato.")
        return self._pair_ok(new_token), True

    def _pair_ok(self, token: str) -> dict:
        try:
            key = self.key_path.read_bytes().decode("ascii")
        except (OSError, UnicodeDecodeError):
            key = ""
        return {"op": "pair_ok", "token": token, "fernet_key": key}


class LanConnection:
    """Una connessione, lo stesso formato che userà Conti Light."""

    def __init__(self, host: str, port: int, *, timeout: float = 30) -> None:
        self._conn = socket.create_connection((host, port), timeout=timeout)
        self._conn.settimeout(timeout)
        self._key = b""

    def call(self, message: dict) -> dict:
        outgoing = message
        if self._key and message.get("op") != "pair":
            outgoing = seal(message, self._key)
        self._conn.sendall(_frame(outgoing))
        reply = _read_frame(self._conn)
        if reply.get("op") == "sealed":
            reply = open_sealed(reply, self._key)
        if reply.get("op") == "pair_ok":
            raw = str(reply.get("fernet_key") or "")
            if raw:
                self._key = raw.encode("ascii")
        return reply

    def close(self) -> None:
        try:
            self._conn.close()
        except OSError:
            pass

    def __enter__(self) -> "LanConnection":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()


def _nonneg_int(value: object) -> int:
    try:
        return max(0, int(value))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def write_light_pending(data_dir: Path, count: int) -> None:
    """Segna che sul telefono ci sono registrazioni non ancora salvate dal Mac. Senza il loro contenuto."""
    if count <= 0:
        clear_light_pending(data_dir)
        return
    path = lan_state_dir(data_dir) / PENDING_FILE_NAME
    path.write_text(
        json.dumps(
            {"count": int(count), "at": datetime.now(timezone.utc).isoformat()},
            ensure_ascii=True,
        ),
        encoding="utf-8",
    )
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def clear_light_pending(data_dir: Path) -> None:
    try:
        (lan_state_dir(data_dir) / PENDING_FILE_NAME).unlink()
    except OSError:
        pass


def phone_waiting_flag_path(data_dir: Path) -> Path:
    """Segnaposto su Dropbox: il cellulare ha dati e il desktop non era raggiungibile."""
    return Path(data_dir) / PHONE_WAITING_FLAG


def phone_waiting_flag_present(data_dir: Path) -> bool:
    return phone_waiting_flag_path(data_dir).is_file()


def clear_phone_waiting_flag(data_dir: Path) -> None:
    try:
        phone_waiting_flag_path(data_dir).unlink()
    except OSError:
        pass


def read_light_pending_count(data_dir: Path) -> int:
    path = lan_state_dir(data_dir) / PENDING_FILE_NAME
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return 0
    if not isinstance(raw, dict):
        return 0
    try:
        return max(0, int(raw.get("count") or 0))
    except (TypeError, ValueError):
        return 0


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def stop_notice_listener(data_dir: Path) -> None:
    """Chiude l'ascolto lasciato acceso a programma chiuso, così la finestra può usare la rete."""
    pid_path = lan_state_dir(data_dir) / PID_FILE_NAME
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        pid = 0
    if _pid_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        for _ in range(30):
            if not _pid_alive(pid):
                break
            time.sleep(0.1)
        if _pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    try:
        pid_path.unlink()
    except OSError:
        pass


def prepare_gui_listen(data_dir: Path) -> None:
    """La finestra è aperta: l'ascolto ridotto deve lasciare la rete."""
    lock = lan_state_dir(data_dir) / GUI_LOCK_NAME
    lock.write_text("desktop\n", encoding="utf-8")
    try:
        os.chmod(lock, 0o600)
    except OSError:
        pass
    stop_notice_listener(data_dir)


def leave_notice_listener(data_dir: Path) -> None:
    """A programma chiuso resta solo il segnaposto, non il database."""
    data_dir = Path(data_dir)
    try:
        (lan_state_dir(data_dir) / GUI_LOCK_NAME).unlink()
    except OSError:
        pass
    spawn_notice_listener(data_dir)


def spawn_notice_listener(data_dir: Path) -> None:
    data_dir = Path(data_dir)
    pid_path = lan_state_dir(data_dir) / PID_FILE_NAME
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        pid = 0
    if _pid_alive(pid):
        return
    script = Path(__file__).resolve().parent / "scripts" / "avviso_light_prova.py"
    if not script.is_file():
        return
    subprocess.Popen(
        [sys.executable, str(script), str(data_dir)],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def serve_notice_until_gui(data_dir: Path) -> None:
    """Ascolta solo per segnare che il telefono ha registrazioni in attesa. Non scrive il database."""
    data_dir = Path(data_dir).expanduser().resolve()
    state = lan_state_dir(data_dir)
    if (state / GUI_LOCK_NAME).exists():
        return
    key = data_dir / "conti_di_casa.key"
    if not key.is_file():
        return
    pid_path = state / PID_FILE_NAME
    pid_path.write_text(str(os.getpid()), encoding="utf-8")
    try:
        os.chmod(pid_path, 0o600)
    except OSError:
        pass
    server = LightLanServer(
        data_dir,
        key,
        snapshot=lambda: {},
        apply_records=lambda _records: (0, {}),
    )
    server.notice_only = True

    def _stop(_signum: int, _frame: object) -> None:
        server._stop.set()

    signal.signal(signal.SIGTERM, _stop)
    server.start()
    try:
        while not server._stop.is_set():
            if (state / GUI_LOCK_NAME).exists():
                break
            time.sleep(0.4)
    finally:
        server.stop()
        try:
            if pid_path.read_text(encoding="utf-8").strip() == str(os.getpid()):
                pid_path.unlink()
        except OSError:
            pass
