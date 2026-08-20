import customtkinter as ctk
from PIL import Image, ImageTk
import tkinter as tk
from tkinter import messagebox
import sys
import time
from datetime import datetime, timedelta
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
import threading
import logging
import unicodedata
import json
import os
import re
import socket
from pathlib import Path
from collections import deque
import firebase_admin
from firebase_admin import credentials, db as admin_db, auth as admin_auth
from google import genai

# ── APPLICATION PATHS ─────────────────────────────────────────────────
# PyInstaller extrait les ressources intégrées dans un dossier temporaire
# (_MEIPASS), alors que sys.executable désigne le véritable fichier .exe.
SOURCE_DIR = Path(__file__).resolve().parent
IS_FROZEN = bool(getattr(sys, "frozen", False))
EXECUTABLE_DIR = (
    Path(sys.executable).resolve().parent if IS_FROZEN else SOURCE_DIR
)
RESOURCE_DIR = Path(getattr(sys, "_MEIPASS", SOURCE_DIR))

# Les fichiers modifiables sont conservés dans AppData afin que l'application
# puisse écrire même si le .exe est installé dans Program Files.
APP_DATA_DIR = Path(
    os.getenv("LOCALAPPDATA", str(EXECUTABLE_DIR))
) / "WaterMonitoring"
APP_DATA_DIR.mkdir(parents=True, exist_ok=True)


def resource_path(filename: str) -> Path:
    """Retourne le chemin d'une ressource intégrée par PyInstaller."""
    return RESOURCE_DIR / filename


# ── Optional Windows-only imports ────────────────────────────────────
try:
    import winsound
    HAS_WINSOUND = True
except ImportError:
    HAS_WINSOUND = False

try:
    from plyer import notification
    HAS_PLYER = True
except ImportError:
    HAS_PLYER = False

# ── LOGGING ──────────────────────────────────────────────────────────
log_handlers = [
    logging.FileHandler(APP_DATA_DIR / "app_errors.log", encoding="utf-8")
]
if sys.stdout is not None:
    log_handlers.append(logging.StreamHandler(sys.stdout))

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=log_handlers,
)
logger = logging.getLogger("WaterMonitor")


def handle_error(func):
    import functools
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception as e:
            logger.error(f"Erreur dans {func.__name__}: {e}", exc_info=True)
            messagebox.showerror("Erreur", f"Erreur dans '{func.__name__}':\n{e}")
    return wrapper

# ── SENSOR RANGES ─────────────────────────────────────────────────────
SENSOR_RANGES = {
    "temperature": {"min": 10.0, "max": 18.0,  "unit": "°C"},
    "turbidite":   {"min": 0.0,  "max": 100.0,  "unit": "NTU"},
    "ph":          {"min": 7.5,  "max": 8.5,    "unit": ""},
    "ec":          {"min": 0.0,  "max": 3.0,  "unit": "mS/cm"},
}

ALERT_COOLDOWN  = 60
DATA_FILE       = APP_DATA_DIR / "sensor_history.json"
SAVE_INTERVAL   = 1      # sauvegarder dès qu’une nouvelle mesure est ajoutée
MAX_HISTORY_DAYS = 365
READ_INTERVAL_MS = 60_000   # lecture et mise à jour des graphes toutes les 1 minute
FIREBASE_POLL_SECONDS = 60  # lecture Firebase toutes les 1 minute

# ── GSM / ESP8266 CONFIGURATION ───────────────────────────────────────
ESP8266_IP = "192.168.3.144"
ESP8266_PORT = 80
SOCKET_TIMEOUT = 5
MAX_RECIPIENTS = 5
GSM_CONFIG_FILE = APP_DATA_DIR / "gsm_recipients.json"

MODE_DISPLAY_TO_CODE = {
    "Activé": "ON",
    "Désactivé": "OFF",
    "Backup": "BACKUP",
}
MODE_CODE_TO_DISPLAY = {value: key for key, value in MODE_DISPLAY_TO_CODE.items()}


def normalize_phone_number(number: str) -> str:
    """Normalise un numéro au format international."""
    number = str(number).strip()
    number = re.sub(r"[\s\-()]", "", number)
    if number.startswith("00216"):
        number = "+216" + number[5:]
    if re.fullmatch(r"\d{8}", number):
        number = "+216" + number
    return number


def is_valid_phone_number(number: str) -> bool:
    """Accepte + suivi de 8 à 15 chiffres."""
    return bool(re.fullmatch(r"\+[1-9]\d{7,14}", number))

# ── Shared data between threads ───────────────────────────────────────
latest_data: dict[str, dict] = {
    "temperature": {"value": 0.0, "date": "", "time": "", "ts": None},
    "ec":          {"value": 0.0, "date": "", "time": "", "ts": None},
    "turbidity":   {"value": 0.0, "date": "", "time": "", "ts": None},
    "ph":          {"value": 0.0, "date": "", "time": "", "ts": None},
}
data_lock = threading.Lock()


# ── FIREBASE ADMIN SDK ────────────────────────────────────────────────
FIREBASE_KEY_NAME = "test-66a11-firebase-adminsdk-fbsvc-2727ca005e.json"


def find_firebase_key() -> Path:
    """
    Recherche la clé Firebase sans l'intégrer dans le .exe.

    Priorité :
      1. variable GOOGLE_APPLICATION_CREDENTIALS ;
      2. fichier JSON placé à côté du .exe (ou du script en développement).
    """
    configured_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    candidates = []

    if configured_path:
        candidates.append(Path(configured_path).expanduser())

    candidates.append(EXECUTABLE_DIR / FIREBASE_KEY_NAME)

    # En mode développement, évite d'ajouter deux fois le même chemin.
    source_candidate = SOURCE_DIR / FIREBASE_KEY_NAME
    if source_candidate not in candidates:
        candidates.append(source_candidate)

    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate.is_file():
            return candidate

    checked_paths = "\n".join(f"  • {path}" for path in candidates)
    raise FileNotFoundError(
        "Clé Firebase introuvable.\n\n"
        f"Nom attendu : {FIREBASE_KEY_NAME}\n\n"
        "Placez le fichier JSON à côté du programme, ou configurez "
        "GOOGLE_APPLICATION_CREDENTIALS.\n\n"
        f"Emplacements vérifiés :\n{checked_paths}"
    )


def initialize_firebase_admin() -> None:
    """Initialise Firebase et affiche une erreur lisible en mode .exe."""
    try:
        firebase_key_path = find_firebase_key()
        credential = credentials.Certificate(str(firebase_key_path))

        try:
            firebase_admin.get_app()
        except ValueError:
            firebase_admin.initialize_app(credential, {
                "databaseURL": "https://test-66a11-default-rtdb.firebaseio.com"
            })

        logger.info("Firebase initialisé avec succès.")
    except Exception as error:
        logger.critical("Impossible d'initialiser Firebase.", exc_info=True)
        try:
            messagebox.showerror(
                "Configuration Firebase manquante",
                str(error),
            )
        finally:
            raise SystemExit(1) from error


initialize_firebase_admin()


def _safe_float(v) -> float:
    try:
        if v is None:
            return 0.0
        if isinstance(v, str):
            # Firebase peut envoyer "7,5" ou "7.5"
            v = v.strip().replace(",", ".")
        return float(v)
    except (ValueError, TypeError):
        return 0.0


def _get_ci(d: dict, *names, default=None):
    """Lecture insensible à la casse : value/Value/VALUE, date/Date..."""
    if not isinstance(d, dict):
        return default
    lower_map = {str(k).lower(): v for k, v in d.items()}
    for name in names:
        key = str(name).lower()
        if key in lower_map:
            return lower_map[key]
    return default


def _parse_firebase_timestamp(date_str: str, time_str: str):
    """
    Convertit le format Firebase :
        date = "13/05/2026"
        time = "16:10"
    vers un objet datetime.
    """
    try:
        if not date_str or not time_str:
            return None
        return datetime.strptime(f"{date_str} {time_str}", "%d/%m/%Y %H:%M")
    except Exception:
        return None


def _extract_sensor_packet(node) -> dict:
    """
    Extrait value, date, time et ts depuis un noeud Firebase.
    Structure attendue :
        capteurs/ph/date
        capteurs/ph/time
        capteurs/ph/value
    """
    if isinstance(node, dict):
        date_str = str(_get_ci(node, "date", default=""))
        time_str = str(_get_ci(node, "time", "heure", default=""))
        return {
            "value": _safe_float(_get_ci(node, "value", "valeur", default=0)),
            "date": date_str,
            "time": time_str,
            "ts": _parse_firebase_timestamp(date_str, time_str),
        }

    return {"value": _safe_float(node), "date": "", "time": "", "ts": None}


_NODE_KEY = {
    "ec":           "ec",
    "conductivite": "ec",
    "conductivity": "ec",
    "ph":           "ph",
    "temp":         "temperature",
    "temperature":  "temperature",
    "turbidite":    "turbidity",
    "turbidity":    "turbidity",
    "turb":         "turbidity",
}


def _normalize_key(name) -> str:
    return str(name).strip().lower()


def stream_handler(message):
    global latest_data
    try:
        path  = message.get("path", "")
        data  = message.get("data")
        event = message.get("event", "")

        logger.debug(
            f"Firebase stream | event={event!r} path={path!r} data={str(data)[:120]}"
        )

        if data is None:
            return

        with data_lock:
            # Cas 1 : lecture complète de capteurs/
            if path == "/":
                if not isinstance(data, dict):
                    return

                for raw_node_name, node_value in data.items():
                    node_name = _normalize_key(raw_node_name)
                    if node_name in _NODE_KEY:
                        dest_key = _NODE_KEY[node_name]
                        latest_data[dest_key] = _extract_sensor_packet(node_value)
                return

            # Cas 2 : modification partielle comme /ph/value ou /ec/time
            parts = path.lstrip("/").split("/")
            if not parts or parts[0] == "":
                return

            node_name = _normalize_key(parts[0])
            if node_name not in _NODE_KEY:
                return

            dest_key = _NODE_KEY[node_name]

            # Exemple : /ph reçoit tout le dictionnaire {date, time, value}
            if len(parts) == 1:
                latest_data[dest_key] = _extract_sensor_packet(data)
                return

            field = _normalize_key(parts[1])

            if field in ("value", "valeur"):
                latest_data[dest_key]["value"] = _safe_float(data)
            elif field == "date":
                latest_data[dest_key]["date"] = str(data)
            elif field in ("time", "heure"):
                latest_data[dest_key]["time"] = str(data)
            else:
                return

            # Recalcul du timestamp si date ou time changent
            date_str = latest_data[dest_key].get("date", "")
            time_str = latest_data[dest_key].get("time", "")
            latest_data[dest_key]["ts"] = _parse_firebase_timestamp(date_str, time_str)

    except Exception as e:
        logger.error(f"Erreur stream Firebase: {e}", exc_info=True)


def fetch_firebase_once() -> bool:
    """Lit capteurs/ une seule fois et remplit latest_data."""
    try:
        ref = admin_db.reference("capteurs")
        data = ref.get()
        logger.debug(f"Firebase initial/poll read data={str(data)[:300]}")
        if data and isinstance(data, dict):
            stream_handler({"event": "put", "path": "/", "data": data})
            return True
    except Exception as e:
        logger.error(f"Firebase read error: {e}", exc_info=True)
    return False


def start_firebase_stream():
    logger.info("Firebase Admin SDK connected — polling capteurs/")
    while True:
        fetch_firebase_once()
        time.sleep(FIREBASE_POLL_SECONDS)


threading.Thread(target=start_firebase_stream, daemon=True).start()

def ask_gemini_ai(prompt: str) -> str:
    """
    Envoie une question à Gemini et retourne la réponse.
    La clé API doit être stockée dans la variable d'environnement GEMINI_API_KEY.
    """

    api_key = os.getenv("GEMINI_API_KEY", "").strip()

    if not api_key:
        return (
            "La clé API Gemini n'est pas configurée.\n\n"
            "Ajoutez-la avec PowerShell :\n"
            'setx GEMINI_API_KEY "TA_CLE_API_ICI"\n\n'
            "Puis fermez et relancez le logiciel."
        )

    try:
        client = genai.Client(api_key=api_key)

        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt
        )

        if response and response.text:
            return response.text.strip()

        return "Je n'ai pas reçu de réponse claire depuis l'assistant AI."

    except Exception as e:
        logger.error(f"Erreur Gemini AI: {e}", exc_info=True)
        return (
            "Erreur lors de la connexion avec l'assistant AI.\n"
            f"Détail : {e}"
        )
# ─────────────────────────────────────────────
# DONNÉES PERSISTANTES
# ─────────────────────────────────────────────
class DataStorage:
    """
    Sauvegarde chaque mesure avec un horodatage complet ISO 8601.
    Fichier JSON local  →  sensor_history.json
    Format d'une entrée : { "ts": "2025-06-14T15:32:07",
                            "t": 14.2, "u": 23.5, "p": 7.9, "e": 85.3 }
    """

    def __init__(self, filepath: str = DATA_FILE):
        self.filepath = filepath
        self.records: list[dict] = []
        self._load()

    # ── Persistance ──────────────────────────────────────────────────
    def _normalize_record(self, r: dict) -> dict | None:
        """
        Corrige les anciennes entrées de sensor_history.json.
        Certaines anciennes versions du fichier peuvent ne pas contenir p, e, u ou t.
        Cette fonction évite le KeyError dans État du Système et les statistiques.
        """
        if not isinstance(r, dict):
            return None

        ts = r.get("ts")
        if not ts:
            return None

        try:
            datetime.fromisoformat(ts)
        except Exception:
            return None

        return {
            "ts": ts,
            "t": _safe_float(r.get("t", r.get("temperature", 0))),
            "u": _safe_float(r.get("u", r.get("turbidity", r.get("turbidite", 0)))),
            "p": _safe_float(r.get("p", r.get("ph", 0))),
            "e": _safe_float(r.get("e", r.get("ec", 0))),
            "ts_temp": r.get("ts_temp", ""),
            "ts_turb": r.get("ts_turb", ""),
            "ts_ph": r.get("ts_ph", ""),
            "ts_ec": r.get("ts_ec", ""),
        }

    def _load(self):
        if not os.path.exists(self.filepath):
            logger.info("Aucun historique trouvé — démarrage vierge.")
            return
        try:
            with open(self.filepath, "r", encoding="utf-8") as f:
                raw = json.load(f)

            if not isinstance(raw, list):
                raw = []

            cutoff = datetime.now() - timedelta(days=MAX_HISTORY_DAYS)
            cleaned = []

            for item in raw:
                rec = self._normalize_record(item)
                if rec is None:
                    continue
                try:
                    if datetime.fromisoformat(rec["ts"]) >= cutoff:
                        cleaned.append(rec)
                except Exception:
                    continue

            self.records = cleaned
            logger.info(f"Historique chargé : {len(self.records)} entrées.")
        except Exception as e:
            logger.error(f"Erreur chargement historique : {e}")
            self.records = []

    def save(self):
        try:
            with open(self.filepath, "w", encoding="utf-8") as f:
                json.dump(self.records, f, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Erreur sauvegarde : {e}")

    # ── Ajout d'une mesure ────────────────────────────────────────────
    def add(self, temperature: float, turbidity: float,
            ph: float, ec: float, firebase_ts=None, timestamps_by_sensor=None):
        """
        Ajoute une mesure à l'historique.
        - firebase_ts : timestamp principal venant de Firebase.
        - timestamps_by_sensor : timestamps individuels de chaque capteur.
        """
        ts = firebase_ts if firebase_ts else datetime.now()
        timestamps_by_sensor = timestamps_by_sensor or {}

        self.records.append({
            "ts": ts.isoformat(timespec="seconds"),
            "t":  round(temperature, 3),
            "u":  round(turbidity,   3),
            "p":  round(ph,          3),
            "e":  round(ec,          3),

            # Horodatage individuel de chaque capteur depuis Firebase
            "ts_temp": timestamps_by_sensor.get("temperature", ""),
            "ts_turb": timestamps_by_sensor.get("turbidity", ""),
            "ts_ph":   timestamps_by_sensor.get("ph", ""),
            "ts_ec":   timestamps_by_sensor.get("ec", ""),
        })

    # ── Filtrage par période ──────────────────────────────────────────
    PERIOD_DELTA = {
        "EN DIRECT": timedelta(minutes=10),   # 10 dernières minutes
        "1H":        timedelta(hours=1),
        "24H":       timedelta(hours=24),
        "7J":        timedelta(days=7),
        "30J":       timedelta(days=30),
        "1AN":       timedelta(days=365),
    }

    def get_range(self, period: str) -> list[dict]:
        delta  = self.PERIOD_DELTA.get(period, timedelta(hours=24))
        cutoff = datetime.now() - delta
        data = []

        for item in self.records:
            rec = self._normalize_record(item)
            if rec is None:
                continue
            try:
                if datetime.fromisoformat(rec["ts"]) >= cutoff:
                    data.append(rec)
            except Exception:
                continue

        return data

    def get_stats(self, period: str) -> dict | None:
        data = self.get_range(period)
        if not data:
            return None

        temps = [_safe_float(r.get("t", 0)) for r in data]
        turbs = [_safe_float(r.get("u", 0)) for r in data]
        phs   = [_safe_float(r.get("p", 0)) for r in data]
        ecs   = [_safe_float(r.get("e", 0)) for r in data]

        def s(lst):
            if not lst:
                return {"min": 0, "max": 0, "avg": 0}
            return {"min": min(lst), "max": max(lst),
                    "avg": sum(lst) / len(lst)}

        return {"count": len(data),
                "temp": s(temps), "turb": s(turbs),
                "ph":   s(phs),   "ec":   s(ecs)}


# ── ALERT MANAGER ─────────────────────────────────────────────────────
class AlertManager:
    def __init__(self):
        self._last_alert: dict[str, float] = {}
        self.banner_widget = None
        self.enable_toast  = True
        self.enable_popup  = True
        self.enable_sound  = True

    def _is_cooldown(self, key: str) -> bool:
        return (time.time() - self._last_alert.get(key, 0)) < ALERT_COOLDOWN

    def _record(self, key: str):
        self._last_alert[key] = time.time()

    def send_toast(self, title: str, message: str):
        if not HAS_PLYER:
            return
        try:
            notification.notify(title=title, message=message,
                                app_name="Water Monitor", timeout=8)
        except Exception as e:
            logger.warning(f"Toast non envoyé : {e}")

    def send_banner(self, message: str, level: str = "warning"):
        if self.banner_widget:
            color = "#CC2200" if level == "critical" else "#CC7700"
            self.banner_widget.show(message, color)

    def play_sound(self, critical: bool = False):
        if not HAS_WINSOUND:
            return
        try:
            if critical:
                for _ in range(3):
                    winsound.Beep(1200, 300)
                    time.sleep(0.1)
            else:
                winsound.Beep(800, 500)
        except Exception as e:
            logger.warning(f"Son non joué : {e}")

    def trigger(self, key: str, title: str, message: str, critical: bool = False):
        if self._is_cooldown(key):
            return
        self._record(key)
        level = "critical" if critical else "warning"
        logger.warning(f"ALERTE [{key}] : {message}")
        if self.enable_toast:
            threading.Thread(target=self.send_toast,
                             args=(title, message), daemon=True).start()
        if self.enable_popup:
            self.send_banner(message, level)
        if self.enable_sound:
            threading.Thread(target=self.play_sound,
                             args=(critical,), daemon=True).start()

    def clear(self):
        if self.banner_widget:
            self.banner_widget.hide()


# ── ALERT BANNER ──────────────────────────────────────────────────────
class AlertBanner(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="#CC7700", corner_radius=0, height=40)
        self._visible = False
        self.label = ctk.CTkLabel(self, text="", font=("Arial", 13, "bold"),
                                  text_color="#FFFFFF")
        self.label.pack(side=tk.LEFT, padx=20, pady=8)
        ctk.CTkButton(self, text="✕", width=30, height=28,
                      fg_color="transparent", hover_color="#AA5500",
                      text_color="#FFFFFF", command=self.hide).pack(
            side=tk.RIGHT, padx=10)

    def show(self, message: str, color: str = "#CC7700"):
        self.configure(fg_color=color)
        self.label.configure(text=f"⚠️ {message}")
        if not self._visible:
            self.pack(fill=tk.X)
            self._visible = True

    def hide(self):
        if self._visible:
            self.pack_forget()
            self._visible = False


# ── SENSOR DATA MODEL ─────────────────────────────────────────────────
class SensorSimulator:
    MAX_POINTS = 100

    def __init__(self, alert_manager: AlertManager = None):
        self.alert_manager  = alert_manager
        self.temperature    = 0.0
        self.ec             = 0.0
        self.turbidity      = 0.0
        self.ph             = 0.0

        # Ringbuffers EN DIRECT. Chaque capteur garde son propre timestamp Firebase.
        # C’est important parce qu’un capteur peut être mis à jour chaque minute,
        # alors qu’un autre peut rester inchangé pendant plusieurs heures.
        self.temp_time_data      = deque(maxlen=self.MAX_POINTS)
        self.ec_time_data        = deque(maxlen=self.MAX_POINTS)
        self.turbidity_time_data = deque(maxlen=self.MAX_POINTS)
        self.ph_time_data        = deque(maxlen=self.MAX_POINTS)

        self.temp_data      = deque(maxlen=self.MAX_POINTS)
        self.ec_data        = deque(maxlen=self.MAX_POINTS)
        self.turbidity_data = deque(maxlen=self.MAX_POINTS)
        self.ph_data        = deque(maxlen=self.MAX_POINTS)

        # Gardé seulement pour compatibilité avec d’anciennes parties du code.
        self.time_data      = deque(maxlen=self.MAX_POINTS)

        # Stockage persistant avec horodatage complet
        self.storage        = DataStorage()
        self._save_counter  = 0

        # Signature précédente pour éviter d’ajouter la même mesure plusieurs fois.
        # Une nouvelle mesure est ajoutée seulement si value/date/time change dans Firebase.
        self._last_sensor_signature: dict[str, tuple] = {}

    def clear_history(self):
        """Efface l'historique local et les données affichées en direct."""

        # 1) Effacer l'historique JSON
        self.storage.records.clear()
        self.storage.save()

        # 2) Effacer les données EN DIRECT
        self.temp_time_data.clear()
        self.ec_time_data.clear()
        self.turbidity_time_data.clear()
        self.ph_time_data.clear()

        self.temp_data.clear()
        self.ec_data.clear()
        self.turbidity_data.clear()
        self.ph_data.clear()

        self.time_data.clear()

        # 3) Réinitialiser les signatures pour accepter une nouvelle première lecture
        self._last_sensor_signature.clear()

        logger.info("Historique effacé par l'utilisateur.")

    def _packet_signature(self, packet: dict) -> tuple:
        return (
            round(_safe_float(packet.get("value", 0.0)), 6),
            str(packet.get("date", "")),
            str(packet.get("time", "")),
        )

    def _packet_timestamp(self, packet: dict) -> datetime:
        return packet.get("ts") or datetime.now()

    def update(self) -> bool:
        with data_lock:
            packets = {
                "temperature": latest_data["temperature"].copy(),
                "ec":          latest_data["ec"].copy(),
                "turbidity":   latest_data["turbidity"].copy(),
                "ph":          latest_data["ph"].copy(),
            }

        # Si Firebase n'a pas encore répondu, on n'initialise pas l'historique avec des 0.
        firebase_not_ready = all(
            _safe_float(p.get("value", 0.0)) == 0.0
            and not p.get("date")
            and not p.get("time")
            for p in packets.values()
        )
        if firebase_not_ready:
            logger.debug("Firebase pas encore prêt : affichage conservé, pas d'ajout de 0.")
            return False

        # Valeurs actuelles affichées dans "État du Système"
        self.temperature = _safe_float(packets["temperature"].get("value", 0.0))
        self.ec          = _safe_float(packets["ec"].get("value", 0.0))
        self.turbidity   = _safe_float(packets["turbidity"].get("value", 0.0))
        self.ph          = _safe_float(packets["ph"].get("value", 0.0))

        current_signatures = {
            key: self._packet_signature(packet)
            for key, packet in packets.items()
        }

        changed_sensors = [
            key for key, sig in current_signatures.items()
            if self._last_sensor_signature.get(key) != sig
        ]

        # Première lecture : on initialise les signatures et on ajoute une première mesure.
        first_read = not self._last_sensor_signature

        # S’il n’y a aucun changement dans Firebase, on n’ajoute rien au graphe ni au JSON.
        if not changed_sensors and not first_read:
            self._check_alerts()
            return False

        self._last_sensor_signature = current_signatures

        sensor_values = {
            "temperature": self.temperature,
            "ec":          self.ec,
            "turbidity":   self.turbidity,
            "ph":          self.ph,
        }

        sensor_time_deques = {
            "temperature": self.temp_time_data,
            "ec":          self.ec_time_data,
            "turbidity":   self.turbidity_time_data,
            "ph":          self.ph_time_data,
        }
        sensor_value_deques = {
            "temperature": self.temp_data,
            "ec":          self.ec_data,
            "turbidity":   self.turbidity_data,
            "ph":          self.ph_data,
        }

        # En EN DIRECT, on ajoute seulement le(s) capteur(s) réellement modifié(s).
        # Au premier démarrage, on ajoute tous les capteurs pour remplir l’interface.
        sensors_to_append = list(packets.keys()) if first_read else changed_sensors
        for key in sensors_to_append:
            ts = self._packet_timestamp(packets[key])
            sensor_time_deques[key].append(ts)
            sensor_value_deques[key].append(sensor_values[key])
            self.time_data.append(ts)

        valid_times = [self._packet_timestamp(packets[k]) for k in sensors_to_append]
        main_ts = max(valid_times) if valid_times else datetime.now()

        timestamps_by_sensor = {
            "temperature": packets["temperature"]["ts"].isoformat(timespec="seconds") if packets["temperature"].get("ts") else "",
            "ec":          packets["ec"]["ts"].isoformat(timespec="seconds")          if packets["ec"].get("ts") else "",
            "turbidity":   packets["turbidity"]["ts"].isoformat(timespec="seconds")   if packets["turbidity"].get("ts") else "",
            "ph":          packets["ph"]["ts"].isoformat(timespec="seconds")          if packets["ph"].get("ts") else "",
        }

        # Enregistrement persistant seulement si Firebase a changé
        self.storage.add(
            self.temperature,
            self.turbidity,
            self.ph,
            self.ec,
            firebase_ts=main_ts,
            timestamps_by_sensor=timestamps_by_sensor,
        )

        self._save_counter += 1
        if self._save_counter >= SAVE_INTERVAL:
            self.storage.save()
            self._save_counter = 0

        self._check_alerts()
        return True

    def _check_alerts(self):
        if not self.alert_manager:
            return
        am        = self.alert_manager
        any_alert = False
        r         = SENSOR_RANGES

        if self.temperature < r["temperature"]["min"]:
            am.trigger("temperature_low", "⚠️ Alerte Température",
                       f"Température trop basse : {self.temperature:.1f} {r['temperature']['unit']} "
                       f"(min : {r['temperature']['min']})")
            any_alert = True
        elif self.temperature > r["temperature"]["max"]:
            am.trigger("temperature_high", "⚠️ Alerte Température",
                       f"Température critique : {self.temperature:.1f} {r['temperature']['unit']} "
                       f"(max : {r['temperature']['max']})",
                       critical=self.temperature > r["temperature"]["max"] + 12)
            any_alert = True
        if self.ph < r["ph"]["min"]:
            am.trigger("ph_low", "⚠️ Alerte PH",
                       f"PH trop acide : {self.ph:.2f} (min : {r['ph']['min']})")
            any_alert = True
        elif self.ph > r["ph"]["max"]:
            am.trigger("ph_high", "⚠️ Alerte PH",
                       f"PH trop basique : {self.ph:.2f} (max : {r['ph']['max']})")
            any_alert = True
        if self.turbidity > r["turbidite"]["max"]:
            am.trigger("turbidity", "⚠️ Alerte Turbidité",
                       f"Eau trouble : {self.turbidity:.2f} {r['turbidite']['unit']} "
                       f"(max : {r['turbidite']['max']})")
            any_alert = True
        if self.ec < r["ec"]["min"]:
            am.trigger("ec_low", "⚠️ Alerte Conductivité (EC)",
                       f"EC trop faible : {self.ec:.3f} {r['ec']['unit']} "
                       f"(min : {r['ec']['min']})")
            any_alert = True
        elif self.ec > r["ec"]["max"]:
            am.trigger("ec_high", "⚠️ Alerte Conductivité (EC)",
                       f"EC trop élevé : {self.ec:.3f} {r['ec']['unit']} "
                       f"(max : {r['ec']['max']})",
                       critical=self.ec > r["ec"]["max"] * 4)
            any_alert = True
        if not any_alert:
            am.clear()

    def get_system_status(self) -> str:
        r      = SENSOR_RANGES
        alerts = []
        if self.temperature < r["temperature"]["min"] or self.temperature > r["temperature"]["max"]:
            alerts.append(f"Température {self.temperature:.1f}°C")
        if self.ph < r["ph"]["min"] or self.ph > r["ph"]["max"]:
            alerts.append(f"PH {self.ph:.2f}")
        if self.turbidity < r["turbidite"]["min"] or self.turbidity > r["turbidite"]["max"]:
            alerts.append(f"Turbidité {self.turbidity:.2f}")
        if self.ec < r["ec"]["min"] or self.ec > r["ec"]["max"]:
            alerts.append(f"EC {self.ec:.3f}")
        return ("⚠️ ALERTE : " + " | ".join(alerts)) if alerts else "✓ Système normal"


# ─────────────────────────────────────────────
# DASHBOARD VIEW — sélection de période
# ─────────────────────────────────────────────
class DashboardView(ctk.CTkFrame):
    """
    Graphiques 2×2 avec sélection de période.
    • EN DIRECT → déque en mémoire (mise à jour fluide 1 s)
    • Autres    → historique persistant (sensor_history.json)
    """

    def _clear_history_confirm(self):
        confirm = messagebox.askyesno(
            "Confirmer l'effacement",
            "Voulez-vous vraiment effacer tout l'historique local ?\n\n"
            "Cette action va vider le fichier sensor_history.json et les graphes EN DIRECT.",
            icon="warning"
        )

        if not confirm:
            return

        self.sensor.clear_history()

        # Nettoyer les graphes visuellement
        for key, _, color, rkey in self.SENSORS:
            ax = self._ax[key]
            ax.clear()
            ax.text(
                0.5, 0.5,
                "Historique effacé",
                transform=ax.transAxes,
                ha="center",
                va="center",
                color="#AAAAAA",
                fontsize=10
            )
            self._style_ax(ax, self.DATE_FMT[self.current_period], rkey, key, color)

        self.mpl_canvas.draw()

        self._stats_lbl.configure(text="Historique effacé.")
        self._count_lbl.configure(
            text=f"Total enregistrements : 0  |  Affichés : 0  |  Fichier : {DATA_FILE}"
        )

        messagebox.showinfo("Succès", "L'historique a été effacé avec succès.")
    PERIODS = ["EN DIRECT", "1H", "24H", "7J", "30J", "1AN"]
    PERIOD_LABELS = {
        "EN DIRECT": "En direct",
        "1H":        "1 Heure",
        "24H":       "24 Heures",
        "7J":        "7 Jours",
        "30J":       "30 Jours",
        "1AN":       "1 An",
    }
    DATE_FMT = {
        "EN DIRECT": "%H:%M:%S",
        "1H":        "%H:%M",
        "24H":       "%H:%M",
        "7J":        "%a %d",
        "30J":       "%d/%m",
        "1AN":       "%b %Y",
    }

    # (key dans DataStorage, label, couleur, clé SENSOR_RANGES)
    SENSORS = [
        ("t", "Température", "#FF6B6B", "temperature"),
        ("e", "EC",          "#4ECDC4", "ec"),
        ("u", "Turbidité",   "#FFD93D", "turbidite"),
        ("p", "pH",          "#95E1D3", "ph"),
    ]

    def __init__(self, master, sensor: SensorSimulator):
        super().__init__(master, fg_color='#55829f', corner_radius=0)
        self.sensor         = sensor
        self.current_period = "EN DIRECT"
        self._setup_ui()

    # ── Construction de l'interface ───────────────────────────────────
    def _setup_ui(self):
        # Titre
        ctk.CTkLabel(
            self,
            text="Tableau de Bord — Évolution des Capteurs",
            font=("Arial", 20, "bold"),
            text_color="#FFFFFF"
        ).pack(pady=(12, 4))

        # ── Barre de périodes ─────────────────────────────────────────
        period_bar = ctk.CTkFrame(self, fg_color="#3d5a6b", corner_radius=8)
        period_bar.pack(padx=16, pady=(0, 6), fill=tk.X)
        ctk.CTkLabel(
            period_bar, text="  Période :",
            font=("Arial", 12, "bold"), text_color="#AADDFF"
        ).pack(side=tk.LEFT, padx=(10, 4), pady=6)

        self._period_btns: dict[str, ctk.CTkButton] = {}
        for p in self.PERIODS:
            btn = ctk.CTkButton(
                period_bar,
                text=self.PERIOD_LABELS[p],
                width=80,
                height=28,
                font=("Arial", 11),
                corner_radius=6,
                fg_color="#006666" if p == self.current_period else "#2d4a5b",
                hover_color="#009999",
                command=lambda period=p: self._set_period(period),
            )
            btn.pack(side=tk.LEFT, padx=4, pady=6)
            self._period_btns[p] = btn

        ctk.CTkButton(
            period_bar,
            text="🗑️ Effacer historique",
            width=150,
            height=28,
            font=("Arial", 11, "bold"),
            corner_radius=6,
            fg_color="#880000",
            hover_color="#AA0000",
            command=self._clear_history_confirm,
        ).pack(side=tk.RIGHT, padx=10, pady=6)

        # ── Barre de statistiques ────────────────────────────────────
        self._stats_frame = ctk.CTkFrame(self, fg_color="#2d4a5b", corner_radius=6)
        self._stats_frame.pack(padx=16, pady=(0, 4), fill=tk.X)
        self._stats_lbl = ctk.CTkLabel(
            self._stats_frame,
            text="En attente de données…",
            font=("Arial", 10), text_color="#AADDFF"
        )
        self._stats_lbl.pack(padx=12, pady=5)

        # ── Graphiques matplotlib ────────────────────────────────────
        plt.style.use('dark_background')
        self._fig, self._axes = plt.subplots(2, 2, figsize=(10, 5.4))
        self._fig.patch.set_facecolor('#55829f')
        self._fig.subplots_adjust(
            hspace=0.42, wspace=0.30,
            left=0.07, right=0.97, top=0.93, bottom=0.12
        )
        self._ax = {
            "t": self._axes[0][0],
            "e": self._axes[0][1],
            "u": self._axes[1][0],
            "p": self._axes[1][1],
        }
        r = SENSOR_RANGES
        for key, label, color, rkey in self.SENSORS:
            ax = self._ax[key]
            lo = r[rkey]["min"]
            hi = r[rkey]["max"]
            unit = r[rkey]["unit"]
            title = f"{label} ({unit})" if unit else label
            ax.set_title(title, color='white', fontsize=10, fontweight='bold', pad=6)
            ax.set_facecolor('#2d4a5b')
            ax.tick_params(colors='white', labelsize=7)
            ax.grid(True, alpha=0.3, color='white', linestyle='--', linewidth=0.5)
            ax.axhspan(lo, hi, alpha=0.12, color='lime')
            ax.axhline(hi, color='red',    linewidth=1, linestyle='--', alpha=0.6)
            if lo > 0:
                ax.axhline(lo, color='orange', linewidth=1, linestyle='--', alpha=0.6)
            for spine in ax.spines.values():
                spine.set_color('white')
                spine.set_linewidth(0.5)

        self.mpl_canvas = FigureCanvasTkAgg(self._fig, self)
        self.mpl_canvas.get_tk_widget().pack(
            fill=tk.BOTH, expand=True, padx=10, pady=(0, 6))

        # Pied de page : compteur
        self._count_lbl = ctk.CTkLabel(
            self, text="",
            font=("Arial", 9), text_color="#AAAAAA"
        )
        self._count_lbl.pack(pady=(0, 4))

    # ── Changement de période ────────────────────────────────────────
    def _set_period(self, period: str):
        self.current_period = period
        for p, btn in self._period_btns.items():
            btn.configure(fg_color="#006666" if p == period else "#2d4a5b")
        self.update_graphs()

    # ── Style commun des axes ────────────────────────────────────────
    def _style_ax(self, ax, fmt: str, rkey: str, key: str, color: str):
        r     = SENSOR_RANGES
        lo    = r[rkey]["min"]
        hi    = r[rkey]["max"]
        unit  = r[rkey]["unit"]
        label = self._label_for(key)
        title = f"{label} ({unit})" if unit else label

        ax.set_facecolor('#2d4a5b')
        ax.tick_params(colors='white', labelsize=7)
        ax.grid(True, alpha=0.3, color='white', linestyle='--', linewidth=0.5)
        ax.axhspan(lo, hi, alpha=0.12, color='lime')
        ax.axhline(hi, color='red',    linewidth=1, linestyle='--', alpha=0.55,
                   label=f"Max {hi}")
        if lo > 0:
            ax.axhline(lo, color='orange', linewidth=1, linestyle='--',
                       alpha=0.55, label=f"Min {lo}")
        ax.set_title(title, color='white', fontsize=10, fontweight='bold', pad=6)
        ax.set_ylabel(unit, color='white', fontsize=8)
        for spine in ax.spines.values():
            spine.set_color('white')
            spine.set_linewidth(0.5)
        try:
            ax.xaxis.set_major_formatter(mdates.DateFormatter(fmt))
            self._fig.autofmt_xdate(rotation=28)
        except Exception:
            pass

    def _label_for(self, key: str) -> str:
        return next(label for k, label, _, _ in self.SENSORS if k == key)

    def _series_from_records(self, records: list[dict], value_key: str, ts_key: str):
        """
        Retourne (timestamps, values) pour un seul capteur.
        On utilise le timestamp individuel du capteur, pas seulement le timestamp global.
        Les doublons consécutifs sont ignorés pour éviter de tracer la même valeur plusieurs fois
        quand un autre capteur seulement a changé.
        """
        timestamps = []
        values = []
        last_pair = None

        for r in records:
            ts_raw = r.get(ts_key) or r.get("ts")
            if not ts_raw:
                continue
            try:
                ts = datetime.fromisoformat(ts_raw)
            except Exception:
                continue

            val = _safe_float(r.get(value_key, 0))
            pair = (ts.isoformat(timespec="seconds"), round(val, 6))
            if pair == last_pair:
                continue

            timestamps.append(ts)
            values.append(val)
            last_pair = pair

        return timestamps, values

    # ── Mise à jour des graphiques ────────────────────────────────────
    def update_graphs(self):
        period = self.current_period
        fmt    = self.DATE_FMT[period]

        # ── Source de données ─────────────────────────────────────────
        if period == "EN DIRECT":
            # Ringbuffers en mémoire : chaque capteur utilise son propre timestamp Firebase.
            live = {
                "t": (list(self.sensor.temp_time_data),      list(self.sensor.temp_data)),
                "e": (list(self.sensor.ec_time_data),        list(self.sensor.ec_data)),
                "u": (list(self.sensor.turbidity_time_data), list(self.sensor.turbidity_data)),
                "p": (list(self.sensor.ph_time_data),        list(self.sensor.ph_data)),
            }
            if all(len(x) < 1 for x, _ in live.values()):
                return
            count = max((len(x) for x, _ in live.values()), default=0)
        else:
            # Historique persistant filtré par période
            records = self.sensor.storage.get_range(period)
            if len(records) < 2:
                for key, _, color, rkey in self.SENSORS:
                    ax = self._ax[key]
                    ax.clear()
                    ax.text(0.5, 0.5,
                            f"Pas assez de données\npour « {self.PERIOD_LABELS[period]} »",
                            transform=ax.transAxes,
                            ha='center', va='center',
                            color='#AAAAAA', fontsize=10)
                    self._style_ax(ax, fmt, rkey, key, "")
                self.mpl_canvas.draw()
                self._stats_lbl.configure(
                    text=f"  Aucune donnée pour « {self.PERIOD_LABELS[period]} »")
                return

            # Pour l’axe X, chaque capteur utilise son propre timestamp Firebase :
            # t → ts_temp, e → ts_ec, u → ts_turb, p → ts_ph.
            live = {
                "t": self._series_from_records(records, "t", "ts_temp"),
                "e": self._series_from_records(records, "e", "ts_ec"),
                "u": self._series_from_records(records, "u", "ts_turb"),
                "p": self._series_from_records(records, "p", "ts_ph"),
            }
            count = max((len(x) for x, _ in live.values()), default=0)

        # ── Tracé ──────────────────────────────────────────────────────
        for key, label, color, rkey in self.SENSORS:
            ax = self._ax[key]
            timestamps, y = live[key]
            ax.clear()
            if len(timestamps) >= 1:
                ax.plot(timestamps, y, color=color, linewidth=1.8, marker="o", markersize=3, zorder=3)
                if len(timestamps) >= 2:
                    ax.fill_between(timestamps, y, alpha=0.22, color=color)
            else:
                ax.text(0.5, 0.5, "Pas de nouvelle mesure",
                        transform=ax.transAxes, ha="center", va="center",
                        color="#AAAAAA", fontsize=10)
            self._style_ax(ax, fmt, rkey, key, color)

        self.mpl_canvas.draw()

        # ── Mise à jour de la barre de stats ───────────────────────────
        stats = (self.sensor.storage.get_stats(period)
                 if period != "EN DIRECT"
                 else self._live_stats())

        total = len(self.sensor.storage.records)
        self._count_lbl.configure(
            text=f"Total enregistrements : {total}  |  "
                 f"Affichés : {count}  |  "
                 f"Fichier : {DATA_FILE}"
        )
        if stats:
            r = SENSOR_RANGES
            self._stats_lbl.configure(
                text=(
                    f"  [{self.PERIOD_LABELS[period]}]  "
                    f"🌡 {stats['temp']['min']:.1f} / {stats['temp']['avg']:.1f} / {stats['temp']['max']:.1f} {r['temperature']['unit']}    "
                    f"💧 Turb {stats['turb']['min']:.1f} / {stats['turb']['avg']:.1f} / {stats['turb']['max']:.1f}    "
                    f"⚗ pH {stats['ph']['min']:.2f} / {stats['ph']['avg']:.2f} / {stats['ph']['max']:.2f}    "
                    f"⚡ EC {stats['ec']['min']:.1f} / {stats['ec']['avg']:.1f} / {stats['ec']['max']:.1f} {r['ec']['unit']}"
                    f"   (min / moy / max)"
                )
            )
        else:
            self._stats_lbl.configure(text="En attente de données…")

    def _live_stats(self) -> dict | None:
        """Stats calculées depuis les ringbuffers EN DIRECT."""
        if not any([self.sensor.temp_data, self.sensor.turbidity_data, self.sensor.ph_data, self.sensor.ec_data]):
            return None

        def s(lst):
            lst = list(lst)
            if not lst:
                return {"min": 0.0, "max": 0.0, "avg": 0.0}
            return {"min": min(lst), "max": max(lst), "avg": sum(lst) / len(lst)}

        return {
            "temp": s(self.sensor.temp_data),
            "turb": s(self.sensor.turbidity_data),
            "ph":   s(self.sensor.ph_data),
            "ec":   s(self.sensor.ec_data),
        }


# ── SYSTEM STATUS VIEW ────────────────────────────────────────────────
class SystemStatusView(ctk.CTkFrame):
    def __init__(self, master, sensor: SensorSimulator):
        super().__init__(master, fg_color='#55829f', corner_radius=0)
        self.sensor = sensor
        self.setup_ui()

    def setup_ui(self):
        ctk.CTkLabel(self, text="État du Système - Temps Réel",
                     font=("Arial", 22, "bold"), text_color="#FFFFFF").pack(pady=20)

        status_frame = ctk.CTkFrame(self, fg_color='#3d5a6b', corner_radius=10)
        status_frame.pack(pady=10, padx=20, fill=tk.X)
        ctk.CTkLabel(status_frame, text="État :", font=("Arial", 16, "bold"),
                     text_color="#FFFFFF").pack(side=tk.LEFT, padx=20, pady=15)
        self.status_label = ctk.CTkLabel(status_frame, text="...",
                                          font=("Arial", 14), text_color="#AAFFAA")
        self.status_label.pack(side=tk.LEFT, padx=10)

        # Horodatage dernière mesure
        self._last_ts = ctk.CTkLabel(
            status_frame, text="",
            font=("Arial", 10), text_color="#AADDFF")
        self._last_ts.pack(side=tk.RIGHT, padx=20)

        readings_frame = ctk.CTkFrame(self, fg_color='transparent')
        readings_frame.pack(pady=20, padx=20, fill=tk.BOTH, expand=True)

        r = SENSOR_RANGES
        self.sensor_displays = []
        sensors = [
            ("Température",       r["temperature"]["unit"], "#FF6B6B",
             r["temperature"]["min"], r["temperature"]["max"]),
            ("EC (Conductivité)", r["ec"]["unit"],          "#4ECDC4",
             r["ec"]["min"],          r["ec"]["max"]),
            ("Turbidité",         r["turbidite"]["unit"],   "#FFD93D",
             r["turbidite"]["min"],    r["turbidite"]["max"]),
            ("pH",                r["ph"]["unit"],           "#95E1D3",
             r["ph"]["min"],           r["ph"]["max"]),
        ]
        for i, (name, unit, color, lo, hi) in enumerate(sensors):
            frame = ctk.CTkFrame(readings_frame, fg_color='#3d5a6b', corner_radius=10)
            frame.grid(row=i // 2, column=i % 2, padx=10, pady=10, sticky="nsew")
            ctk.CTkLabel(frame, text=name, font=("Arial", 14, "bold"),
                          text_color=color).pack(pady=(15, 2))
            interval = f"[{lo} – {hi} {unit}]".strip() if unit else f"[{lo} – {hi}]"
            ctk.CTkLabel(frame, text=interval, font=("Arial", 10),
                          text_color="#AAAAAA").pack(pady=(0, 4))
            val_lbl = ctk.CTkLabel(frame, text="0.0",
                                    font=("Arial", 32, "bold"), text_color="#FFFFFF")
            val_lbl.pack(pady=5)
            ctk.CTkLabel(frame, text=unit, font=("Arial", 12),
                          text_color="#CCCCCC").pack(pady=(0, 4))
            # Mini stats 24h
            stats_lbl = ctk.CTkLabel(frame, text="",
                                      font=("Arial", 9), text_color="#AAAAAA")
            stats_lbl.pack(pady=(0, 12))
            self.sensor_displays.append((val_lbl, stats_lbl))

        for i in range(2):
            readings_frame.grid_columnconfigure(i, weight=1)
            readings_frame.grid_rowconfigure(i, weight=1)
        self.update_display()

    def update_display(self):
        r      = SENSOR_RANGES
        values = [
            (self.sensor.temperature, "temperature"),
            (self.sensor.ec,          "ec"),
            (self.sensor.turbidity,   "turbidite"),
            (self.sensor.ph,          "ph"),
        ]
        stats = self.sensor.storage.get_stats("24H")
        for (lbl, slbl), (val, key) in zip(self.sensor_displays, values):
            lo = r[key]["min"]
            hi = r[key]["max"]
            lbl.configure(
                text=f"{val:.3f}",
                text_color="#FF4444" if (val < lo or val > hi) else "#FFFFFF",
            )
            if stats:
                k = {"temperature": "temp", "ec": "ec",
                     "turbidite":   "turb", "ph": "ph"}[key]
                d = stats[k]
                slbl.configure(
                    text=f"24h  Min {d['min']:.1f}  Moy {d['avg']:.1f}  Max {d['max']:.1f}"
                )
        self.status_label.configure(text=self.sensor.get_system_status())
        recs = self.sensor.storage.records
        if recs:
            self._last_ts.configure(
                text=f"🕒 {recs[-1]['ts']}  |  {len(recs)} enreg.")


# ── CHATBOT VIEW ──────────────────────────────────────────────────────
class ChatBotView(ctk.CTkFrame):
    def __init__(self, master, sensor: SensorSimulator):
        super().__init__(master, fg_color='#55829f', corner_radius=0)
        self.sensor = sensor
        self.setup_ui()

    def setup_ui(self):
        ctk.CTkLabel(
            self,
            text="Assistant AI - Diagnostic Qualité d'Eau",
            font=("Arial", 22, "bold"),
            text_color="#FFFFFF"
        ).pack(pady=20)

        chat_frame = ctk.CTkFrame(self, fg_color='#3d5a6b', corner_radius=10)
        chat_frame.pack(pady=10, padx=20, fill=tk.BOTH, expand=True)

        self.chat_display = ctk.CTkTextbox(
            chat_frame,
            font=("Arial", 12),
            fg_color='#2d4a5b',
            text_color='#FFFFFF',
            wrap=tk.WORD
        )
        self.chat_display.pack(padx=10, pady=10, fill=tk.BOTH, expand=True)

        input_frame = ctk.CTkFrame(self, fg_color='transparent')
        input_frame.pack(pady=10, padx=20, fill=tk.X)

        self.input_entry = ctk.CTkEntry(
            input_frame,
            placeholder_text="Pose une question à l'assistant AI...",
            font=("Arial", 12),
            height=40
        )
        self.input_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))
        self.input_entry.bind("<Return>", lambda e: self.send_message())

        self.send_button = ctk.CTkButton(
            input_frame,
            text="Envoyer",
            command=self.send_message,
            font=("Arial", 12, "bold"),
            fg_color='#008080',
            hover_color='#80ffff',
            width=100,
            height=40
        )
        self.send_button.pack(side=tk.RIGHT)

        self.add_message(
            "Assistant AI",
            "Bonjour ! Je suis l'assistant AI du système de suivi de qualité d'eau.\n"
            "Je peux analyser les valeurs actuelles, expliquer les alertes, "
            "donner un diagnostic simple et proposer des recommandations."
        )

    def add_message(self, sender: str, message: str):
        ts = datetime.now().strftime("%H:%M:%S")
        self.chat_display.insert(tk.END, f"[{ts}] {sender}:\n{message}\n\n")
        self.chat_display.see(tk.END)

    def send_message(self):
        raw = self.input_entry.get().strip()

        if not raw:
            return

        self.add_message("Vous", raw)
        self.input_entry.delete(0, tk.END)

        self.send_button.configure(state="disabled", text="Analyse...")
        self.add_message("Assistant AI", "Analyse en cours...")

        threading.Thread(
            target=self._generate_ai_response_thread,
            args=(raw,),
            daemon=True
        ).start()

    def _generate_ai_response_thread(self, raw: str):
        response = self.generate_response(raw)

        self.after(0, lambda: self._display_ai_response(response))

    def _display_ai_response(self, response: str):
        self.add_message("Assistant AI", response)
        self.send_button.configure(state="normal", text="Envoyer")

    def _safe_stats_text(self, period: str = "24H") -> str:
        try:
            stats = self.sensor.storage.get_stats(period)

            if not stats:
                return "Aucune statistique disponible pour cette période."

            return (
                f"Statistiques {period} :\n"
                f"- Température : min {stats['temp']['min']:.2f}, "
                f"moy {stats['temp']['avg']:.2f}, max {stats['temp']['max']:.2f}\n"
                f"- Turbidité : min {stats['turb']['min']:.2f}, "
                f"moy {stats['turb']['avg']:.2f}, max {stats['turb']['max']:.2f}\n"
                f"- pH : min {stats['ph']['min']:.2f}, "
                f"moy {stats['ph']['avg']:.2f}, max {stats['ph']['max']:.2f}\n"
                f"- EC : min {stats['ec']['min']:.2f}, "
                f"moy {stats['ec']['avg']:.2f}, max {stats['ec']['max']:.2f}"
            )

        except Exception as e:
            return f"Statistiques non disponibles : {e}"

    def _last_timestamp_text(self) -> str:
        try:
            recs = self.sensor.storage.records

            if not recs:
                return "Aucun timestamp enregistré."

            last = recs[-1]

            return (
                f"Dernier timestamp général : {last.get('ts', 'non disponible')}\n"
                f"Timestamp température : {last.get('ts_temp', 'non disponible')}\n"
                f"Timestamp turbidité : {last.get('ts_turb', 'non disponible')}\n"
                f"Timestamp pH : {last.get('ts_ph', 'non disponible')}\n"
                f"Timestamp EC : {last.get('ts_ec', 'non disponible')}"
            )

        except Exception as e:
            return f"Timestamp non disponible : {e}"

    def generate_response(self, raw: str) -> str:
        r = SENSOR_RANGES

        current_status = self.sensor.get_system_status()
        stats_text = self._safe_stats_text("24H")
        timestamp_text = self._last_timestamp_text()

        prompt = f"""
Tu es un assistant AI intégré dans un système industriel de suivi de qualité d'eau
pour un circuit fermé de refroidissement.

Ton rôle :
- analyser les valeurs des capteurs ;
- expliquer l'état du système ;
- détecter les valeurs hors intervalle ;
- proposer des recommandations simples ;
- répondre en français ;
- être clair, court et technique ;
- ne pas inventer de valeurs absentes ;
- préciser si une donnée est manquante ou ancienne.

Valeurs actuelles du système :
- Température : {self.sensor.temperature:.3f} °C
- pH : {self.sensor.ph:.3f}
- Turbidité : {self.sensor.turbidity:.3f} NTU
- EC / Conductivité : {self.sensor.ec:.3f} µS/cm

Intervalles recommandés :
- Température : {r["temperature"]["min"]} à {r["temperature"]["max"]} °C
- pH : {r["ph"]["min"]} à {r["ph"]["max"]}
- Turbidité : {r["turbidite"]["min"]} à {r["turbidite"]["max"]} NTU
- EC : {r["ec"]["min"]} à {r["ec"]["max"]} µS/cm

État calculé par le logiciel :
{current_status}

{stats_text}

Horodatage des dernières mesures :
{timestamp_text}

Question de l'utilisateur :
{raw}

Réponse attendue :
Donne une réponse utile pour un opérateur ou un administrateur.
Si une valeur est hors plage, explique la cause possible et propose une action de vérification.
"""

        return ask_gemini_ai(prompt)

# ── GSM / SMS CONFIGURATION VIEW ──────────────────────────────────────
class GSMConfigurationView(ctk.CTkFrame):
    """Configuration des destinataires SMS et envoi TCP direct vers l'ESP8266.

    Important :
    - l'adresse ESP8266 est fixe et non configurable depuis l'interface ;
    - aucun test de connexion séparé n'est effectué ;
    - le bouton Envoyer ouvre directement le socket ;
    - le payload contient 2 lignes : GSM_MODE:<mode> puis la liste JSON ;
    - aucune réponse de l'ESP8266 n'est attendue.
    """

    BG = "#55829f"
    CARD = "#3d5a6b"
    CARD_DARK = "#2d4a5b"
    ACCENT = "#008080"
    ACCENT_HOVER = "#00a0a0"
    SUCCESS = "#35d07f"
    WARNING = "#ffcc66"
    DANGER = "#ff6b6b"
    MUTED = "#b7d5e8"

    def __init__(self, master):
        super().__init__(master, fg_color=self.BG, corner_radius=0)
        self.recipients: list[dict] = []
        self.gsm_mode = "ON"
        self.mode_buttons: dict[str, ctk.CTkButton] = {}

        self._setup_ui()
        self._load_local_file()
        self._sync_ui_from_state()
        self._render_recipients()

    # ── UI ────────────────────────────────────────────────────────────
    def _setup_ui(self):
        page = ctk.CTkScrollableFrame(
            self,
            fg_color=self.BG,
            corner_radius=0,
            scrollbar_button_color="#3d5a6b",
            scrollbar_button_hover_color="#4c6f82",
        )
        page.pack(fill=tk.BOTH, expand=True)
        self.page = page

        header = ctk.CTkFrame(page, fg_color="transparent")
        header.pack(fill=tk.X, padx=24, pady=(18, 10))

        ctk.CTkLabel(
            header,
            text="📱  Communication GSM / SMS",
            font=("Arial", 24, "bold"),
            text_color="#FFFFFF",
        ).pack(anchor="w")

        ctk.CTkLabel(
            header,
            text=(
                "Gestion du mode GSM et des destinataires SMS, puis envoi direct "
                "vers l'ESP8266."
            ),
            font=("Arial", 11),
            text_color=self.MUTED,
        ).pack(anchor="w", pady=(4, 0))

        # ── Cartes résumé ─────────────────────────────────────────────
        summary = ctk.CTkFrame(page, fg_color="transparent")
        summary.pack(fill=tk.X, padx=18, pady=(0, 10))
        for i in range(3):
            summary.grid_columnconfigure(i, weight=1)

        self.mode_metric = self._metric_card(
            summary, 0, "MODE GSM", "ON", "📶", self.SUCCESS
        )
        self.connection_metric = self._metric_card(
            summary,
            1,
            "ESP8266 FIXE",
            f"{ESP8266_IP}:{ESP8266_PORT}",
            "🌐",
            "#AADDFF",
        )
        self.contacts_metric = self._metric_card(
            summary, 2, "CONTACTS ACTIFS", f"0 / {MAX_RECIPIENTS}", "👥", "#AADDFF"
        )

        # ── Réglages ─────────────────────────────────────────────────
        settings = ctk.CTkFrame(page, fg_color="transparent")
        settings.pack(fill=tk.X, padx=18, pady=4)
        settings.grid_columnconfigure(0, weight=1)
        settings.grid_columnconfigure(1, weight=1)

        # Mode GSM
        mode_card = ctk.CTkFrame(settings, fg_color=self.CARD, corner_radius=12)
        mode_card.grid(row=0, column=0, sticky="nsew", padx=(0, 6), pady=4)

        ctk.CTkLabel(
            mode_card,
            text="Mode de fonctionnement",
            font=("Arial", 15, "bold"),
            text_color="#FFFFFF",
        ).pack(anchor="w", padx=16, pady=(14, 4))

        ctk.CTkLabel(
            mode_card,
            text="Choisissez le mode GSM à mémoriser dans la configuration locale.",
            font=("Arial", 10),
            text_color=self.MUTED,
        ).pack(anchor="w", padx=16, pady=(0, 10))

        mode_row = ctk.CTkFrame(mode_card, fg_color="transparent")
        mode_row.pack(fill=tk.X, padx=12, pady=4)

        for mode, label in [
            ("ON", "✓ Activé"),
            ("OFF", "✕ Désactivé"),
            ("BACKUP", "↻ Backup"),
        ]:
            btn = ctk.CTkButton(
                mode_row,
                text=label,
                height=38,
                corner_radius=8,
                fg_color=self.CARD_DARK,
                hover_color=self.ACCENT_HOVER,
                font=("Arial", 11, "bold"),
                command=lambda m=mode: self._set_mode(m),
            )
            btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=4)
            self.mode_buttons[mode] = btn

        self.mode_info_label = ctk.CTkLabel(
            mode_card,
            text="",
            justify="left",
            anchor="w",
            font=("Arial", 10),
            text_color=self.MUTED,
            wraplength=360,
        )
        self.mode_info_label.pack(fill=tk.X, padx=16, pady=(10, 14))

        # ESP8266 : IP fixe, aucun champ modifiable, aucun bouton de test
        net_card = ctk.CTkFrame(settings, fg_color=self.CARD, corner_radius=12)
        net_card.grid(row=0, column=1, sticky="nsew", padx=(6, 0), pady=4)

        ctk.CTkLabel(
            net_card,
            text="Connexion ESP8266",
            font=("Arial", 15, "bold"),
            text_color="#FFFFFF",
        ).pack(anchor="w", padx=16, pady=(14, 4))

        ctk.CTkLabel(
            net_card,
            text="Adresse fixe utilisée automatiquement lors de l'envoi.",
            font=("Arial", 10),
            text_color=self.MUTED,
        ).pack(anchor="w", padx=16, pady=(0, 10))

        endpoint_box = ctk.CTkFrame(net_card, fg_color=self.CARD_DARK, corner_radius=9)
        endpoint_box.pack(fill=tk.X, padx=14, pady=(4, 8))

        ctk.CTkLabel(
            endpoint_box,
            text="Adresse IP",
            font=("Arial", 9, "bold"),
            text_color=self.MUTED,
        ).grid(row=0, column=0, sticky="w", padx=12, pady=(10, 2))

        ctk.CTkLabel(
            endpoint_box,
            text=ESP8266_IP,
            font=("Consolas", 13, "bold"),
            text_color="#FFFFFF",
        ).grid(row=1, column=0, sticky="w", padx=12, pady=(0, 10))

        ctk.CTkLabel(
            endpoint_box,
            text="Port",
            font=("Arial", 9, "bold"),
            text_color=self.MUTED,
        ).grid(row=0, column=1, sticky="w", padx=12, pady=(10, 2))

        ctk.CTkLabel(
            endpoint_box,
            text=str(ESP8266_PORT),
            font=("Consolas", 13, "bold"),
            text_color="#FFFFFF",
        ).grid(row=1, column=1, sticky="w", padx=12, pady=(0, 10))

        ctk.CTkLabel(
            net_card,
            text="Aucun test préalable : la connexion est ouverte uniquement au clic sur Envoyer.",
            font=("Arial", 9),
            text_color=self.MUTED,
            wraplength=360,
            justify="left",
        ).pack(anchor="w", padx=16, pady=(4, 14))

        # ── Contacts ──────────────────────────────────────────────────
        contacts_card = ctk.CTkFrame(page, fg_color=self.CARD, corner_radius=12)
        contacts_card.pack(fill=tk.BOTH, expand=True, padx=18, pady=(8, 6))

        contacts_head = ctk.CTkFrame(contacts_card, fg_color="transparent")
        contacts_head.pack(fill=tk.X, padx=16, pady=(13, 5))

        ctk.CTkLabel(
            contacts_head,
            text="Destinataires des alertes SMS",
            font=("Arial", 15, "bold"),
            text_color="#FFFFFF",
        ).pack(side=tk.LEFT)

        self.contacts_count_label = ctk.CTkLabel(
            contacts_head,
            text=f"0 / {MAX_RECIPIENTS} enregistré(s)",
            font=("Arial", 10),
            text_color=self.MUTED,
        )
        self.contacts_count_label.pack(side=tk.RIGHT)

        input_row = ctk.CTkFrame(contacts_card, fg_color=self.CARD_DARK, corner_radius=9)
        input_row.pack(fill=tk.X, padx=14, pady=8)
        input_row.grid_columnconfigure(0, weight=1)
        input_row.grid_columnconfigure(1, weight=1)

        self.name_entry = ctk.CTkEntry(
            input_row,
            placeholder_text="Nom / fonction (ex. Maintenance)",
            height=38,
        )
        self.name_entry.grid(row=0, column=0, padx=(10, 5), pady=10, sticky="ew")

        self.number_entry = ctk.CTkEntry(
            input_row,
            placeholder_text="+21650610318",
            height=38,
        )
        self.number_entry.grid(row=0, column=1, padx=5, pady=10, sticky="ew")
        self.number_entry.bind("<Return>", lambda _e: self._add_recipient())

        ctk.CTkButton(
            input_row,
            text="＋ Ajouter",
            width=105,
            height=38,
            fg_color=self.ACCENT,
            hover_color=self.ACCENT_HOVER,
            font=("Arial", 11, "bold"),
            command=self._add_recipient,
        ).grid(row=0, column=2, padx=(5, 10), pady=10)

        self.recipients_frame = ctk.CTkScrollableFrame(
            contacts_card,
            fg_color=self.CARD_DARK,
            corner_radius=9,
            height=185,
            label_text="Contacts enregistrés",
            label_text_color=self.MUTED,
        )
        self.recipients_frame.pack(fill=tk.BOTH, expand=True, padx=14, pady=(4, 12))
        self.recipients_frame.grid_columnconfigure(1, weight=1)

        # ── Aperçu + envoi ────────────────────────────────────────────
        send_card = ctk.CTkFrame(page, fg_color=self.CARD, corner_radius=12)
        send_card.pack(fill=tk.X, padx=18, pady=(6, 18))
        send_card.grid_columnconfigure(0, weight=1)

        preview_box = ctk.CTkFrame(send_card, fg_color="transparent")
        preview_box.grid(row=0, column=0, sticky="ew", padx=14, pady=12)

        ctk.CTkLabel(
            preview_box,
            text="Aperçu de la liste envoyée",
            font=("Arial", 12, "bold"),
            text_color="#FFFFFF",
        ).pack(anchor="w")

        ctk.CTkLabel(
            preview_box,
            text="Deux lignes TCP : GSM_MODE:<mode> puis la liste JSON des numéros.",
            font=("Arial", 9),
            text_color=self.MUTED,
        ).pack(anchor="w", pady=(2, 6))

        self.payload_preview = ctk.CTkTextbox(
            preview_box,
            height=70,
            fg_color="#1f3440",
            text_color="#DDF6FF",
            font=("Consolas", 11),
            wrap="none",
        )
        self.payload_preview.pack(fill=tk.X)
        self.payload_preview.configure(state="disabled")

        send_actions = ctk.CTkFrame(send_card, fg_color="transparent")
        send_actions.grid(row=0, column=1, sticky="ns", padx=(0, 14), pady=12)

        self.send_button = ctk.CTkButton(
            send_actions,
            text="📤 Envoyer configuration",
            width=190,
            height=44,
            fg_color=self.ACCENT,
            hover_color=self.ACCENT_HOVER,
            font=("Arial", 12, "bold"),
            command=self._send_to_esp8266,
        )
        self.send_button.pack(pady=(18, 6))

        self.send_status_label = ctk.CTkLabel(
            send_actions,
            text="Prêt à envoyer",
            width=190,
            font=("Arial", 9),
            text_color=self.MUTED,
            wraplength=190,
        )
        self.send_status_label.pack()

    def _metric_card(self, parent, col, title, value, icon, value_color):
        card = ctk.CTkFrame(parent, fg_color=self.CARD, corner_radius=11)
        card.grid(row=0, column=col, sticky="ew", padx=6, pady=4)

        top = ctk.CTkFrame(card, fg_color="transparent")
        top.pack(fill=tk.X, padx=14, pady=(11, 0))

        ctk.CTkLabel(top, text=icon, font=("Arial", 20)).pack(side=tk.LEFT)
        ctk.CTkLabel(
            top,
            text=title,
            font=("Arial", 9, "bold"),
            text_color=self.MUTED,
        ).pack(side=tk.LEFT, padx=8)

        lbl = ctk.CTkLabel(
            card,
            text=value,
            font=("Arial", 16, "bold"),
            text_color=value_color,
            anchor="w",
        )
        lbl.pack(fill=tk.X, padx=14, pady=(2, 11))
        return lbl

    # ── Mode GSM ──────────────────────────────────────────────────────
    def _set_mode(self, mode: str):
        if mode not in ("ON", "OFF", "BACKUP"):
            mode = "ON"
        self.gsm_mode = mode
        self._update_mode_ui()
        self._update_preview()
        self._save_local_file(silent=True)

    def _update_mode_ui(self):
        mode_info = {
            "ON": ("GSM activé.", self.SUCCESS),
            "OFF": ("GSM désactivé dans la configuration locale.", self.DANGER),
            "BACKUP": ("GSM mémorisé comme solution de secours.", self.WARNING),
        }

        text, color = mode_info[self.gsm_mode]

        for mode, btn in self.mode_buttons.items():
            if mode == self.gsm_mode:
                btn.configure(
                    fg_color=self.ACCENT,
                    border_width=1,
                    border_color="#8ff7f7",
                )
            else:
                btn.configure(fg_color=self.CARD_DARK, border_width=0)

        self.mode_info_label.configure(text=text, text_color=color)
        self.mode_metric.configure(text=self.gsm_mode, text_color=color)

    # ── Destinataires ─────────────────────────────────────────────────
    def _add_recipient(self):
        name = self.name_entry.get().strip()
        number = normalize_phone_number(self.number_entry.get())

        if not name:
            messagebox.showwarning(
                "Nom manquant",
                "Entre le nom ou la fonction du destinataire.",
            )
            return

        if not is_valid_phone_number(number):
            messagebox.showerror(
                "Numéro invalide",
                "Utilise un numéro comme +21650610318.",
            )
            return

        if len(self.recipients) >= MAX_RECIPIENTS:
            messagebox.showwarning(
                "Limite atteinte",
                f"Maximum : {MAX_RECIPIENTS} numéros.",
            )
            return

        if any(r.get("number") == number for r in self.recipients):
            messagebox.showwarning(
                "Numéro existant",
                "Ce numéro est déjà enregistré.",
            )
            return

        self.recipients.append(
            {
                "name": name,
                "number": number,
                "enabled": True,
            }
        )

        self.name_entry.delete(0, tk.END)
        self.number_entry.delete(0, tk.END)

        self._save_local_file(silent=True)
        self._render_recipients()

    def _delete_recipient(self, index: int):
        if 0 <= index < len(self.recipients):
            del self.recipients[index]
            self._save_local_file(silent=True)
            self._render_recipients()

    def _update_enabled(self, index: int, value: bool):
        if 0 <= index < len(self.recipients):
            self.recipients[index]["enabled"] = bool(value)
            self._save_local_file(silent=True)
            self._update_summary()
            self._update_preview()

    def _render_recipients(self):
        for widget in self.recipients_frame.winfo_children():
            widget.destroy()

        if not self.recipients:
            ctk.CTkLabel(
                self.recipients_frame,
                text="Aucun destinataire enregistré. Ajoute un contact ci-dessus.",
                font=("Arial", 11),
                text_color="#9fb7c6",
            ).grid(row=0, column=0, columnspan=4, padx=10, pady=24)
        else:
            for index, recipient in enumerate(self.recipients):
                enabled_var = ctk.BooleanVar(value=recipient.get("enabled", True))

                checkbox = ctk.CTkCheckBox(
                    self.recipients_frame,
                    text="",
                    width=28,
                    variable=enabled_var,
                    fg_color=self.ACCENT,
                    hover_color=self.ACCENT_HOVER,
                    command=lambda i=index, v=enabled_var: self._update_enabled(i, v.get()),
                )
                checkbox.grid(row=index, column=0, padx=(8, 4), pady=7)

                ctk.CTkLabel(
                    self.recipients_frame,
                    text=recipient.get("name", "Sans nom"),
                    font=("Arial", 11, "bold"),
                    text_color="#FFFFFF",
                    anchor="w",
                ).grid(row=index, column=1, padx=6, pady=7, sticky="ew")

                ctk.CTkLabel(
                    self.recipients_frame,
                    text=recipient.get("number", ""),
                    font=("Consolas", 10),
                    text_color=self.MUTED,
                    anchor="w",
                ).grid(row=index, column=2, padx=6, pady=7, sticky="w")

                ctk.CTkButton(
                    self.recipients_frame,
                    text="Supprimer",
                    width=82,
                    height=28,
                    fg_color="#7d3030",
                    hover_color="#a03f3f",
                    font=("Arial", 9),
                    command=lambda i=index: self._delete_recipient(i),
                ).grid(row=index, column=3, padx=8, pady=7)

        self._update_summary()
        self._update_preview()

    # ── Sauvegarde locale ─────────────────────────────────────────────
    def _save_local_file(self, silent: bool = False):
        # L'IP et le port ne sont volontairement PAS sauvegardés :
        # ils restent fixes dans ESP8266_IP / ESP8266_PORT.
        data = {
            "gsm_mode": self.gsm_mode,
            "recipients": self.recipients,
        }

        try:
            GSM_CONFIG_FILE.write_text(
                json.dumps(data, indent=4, ensure_ascii=False),
                encoding="utf-8",
            )
        except OSError as error:
            logger.error(f"Erreur sauvegarde GSM : {error}", exc_info=True)
            if not silent:
                messagebox.showerror(
                    "Erreur",
                    f"Impossible de sauvegarder la configuration GSM :\n{error}",
                )

    def _load_local_file(self):
        if not GSM_CONFIG_FILE.exists():
            return

        try:
            data = json.loads(GSM_CONFIG_FILE.read_text(encoding="utf-8"))

            loaded_mode = str(data.get("gsm_mode", "ON")).upper()
            self.gsm_mode = (
                loaded_mode
                if loaded_mode in ("ON", "OFF", "BACKUP")
                else "ON"
            )

            recipients = data.get("recipients", [])
            cleaned: list[dict] = []

            if isinstance(recipients, list):
                for recipient in recipients[:MAX_RECIPIENTS]:
                    if not isinstance(recipient, dict):
                        continue

                    name = str(recipient.get("name", "")).strip()
                    number = normalize_phone_number(
                        str(recipient.get("number", ""))
                    )
                    enabled = bool(recipient.get("enabled", True))

                    if name and is_valid_phone_number(number):
                        cleaned.append(
                            {
                                "name": name,
                                "number": number,
                                "enabled": enabled,
                            }
                        )

            self.recipients = cleaned

        except (OSError, json.JSONDecodeError) as error:
            logger.error(
                f"Erreur lecture configuration GSM : {error}",
                exc_info=True,
            )
            messagebox.showerror(
                "Configuration GSM",
                f"Impossible de lire la configuration locale :\n{error}",
            )

    def _sync_ui_from_state(self):
        self._update_mode_ui()
        self._update_summary()
        self._update_preview()

    # ── Protocole TCP ─────────────────────────────────────────────────
    def _active_numbers(self) -> list[str]:
        return [
            recipient["number"]
            for recipient in self.recipients
            if recipient.get("enabled", True) and recipient.get("number")
        ]

    def _build_payload(self) -> str:
        """Construit le protocole attendu par l'ESP8266 : mode + liste JSON."""
        mode_line = f"GSM_MODE:{self.gsm_mode}\n"
        list_line = json.dumps(
            self._active_numbers(),
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n"
        return mode_line + list_line

    def _update_preview(self):
        if not hasattr(self, "payload_preview"):
            return

        payload = self._build_payload()
        self.payload_preview.configure(state="normal")
        self.payload_preview.delete("1.0", tk.END)
        self.payload_preview.insert("1.0", payload)
        self.payload_preview.configure(state="disabled")

    def _update_summary(self):
        active = len(self._active_numbers())
        total = len(self.recipients)

        self.contacts_metric.configure(text=f"{active} / {MAX_RECIPIENTS}")
        self.contacts_count_label.configure(
            text=(
                f"{total} / {MAX_RECIPIENTS} enregistré(s)  •  "
                f"{active} actif(s)"
            )
        )

    def _send_to_esp8266(self):
        """Envoie directement MODE + LISTE. Aucun test préalable, aucun recv()."""
        phone_list = self._active_numbers()

        # ON et BACKUP ont besoin d'au moins un destinataire actif.
        # OFF peut être envoyé avec une liste vide pour désactiver le GSM.
        if self.gsm_mode != "OFF" and not phone_list:
            self.send_status_label.configure(
                text="Aucun numéro actif",
                text_color=self.WARNING,
            )
            messagebox.showwarning(
                "Liste vide",
                "Ajoute ou active au moins un destinataire pour le mode ON/BACKUP.",
            )
            return

        self._save_local_file(silent=True)
        payload = self._build_payload()

        self.send_button.configure(state="disabled", text="Envoi...")
        self.send_status_label.configure(
            text=f"Envoi vers {ESP8266_IP}:{ESP8266_PORT}...",
            text_color=self.WARNING,
        )

        # Thread uniquement pour ne pas bloquer l'interface Tkinter pendant connect().
        # Ce n'est PAS un test de connexion : l'envoi est tenté immédiatement.
        threading.Thread(
            target=self._send_worker,
            args=(payload, len(phone_list)),
            daemon=True,
        ).start()

    def _send_worker(self, payload: str, count: int):
        try:
            # TCP brut : on ouvre, on envoie les 2 lignes, puis on ferme.
            with socket.create_connection(
                (ESP8266_IP, ESP8266_PORT),
                timeout=SOCKET_TIMEOUT,
            ) as client:
                client.sendall(payload.encode("utf-8"))

            # IMPORTANT : aucun client.recv().
            logger.info(
                "Configuration GSM envoyée vers %s:%s | destinataires=%s | payload=%s",
                ESP8266_IP,
                ESP8266_PORT,
                count,
                payload.strip(),
            )

            self.after(
                0,
                lambda: self._finish_send(
                    True,
                    count,
                    "Configuration envoyée",
                    payload,
                ),
            )

        except ConnectionRefusedError:
            self.after(
                0,
                lambda: self._finish_send(
                    False,
                    count,
                    "Connexion refusée",
                    payload,
                ),
            )

        except socket.timeout:
            self.after(
                0,
                lambda: self._finish_send(
                    False,
                    count,
                    "ESP8266 inaccessible (timeout)",
                    payload,
                ),
            )

        except OSError as error:
            logger.error(f"Erreur réseau GSM : {error}", exc_info=True)
            msg = str(error)
            self.after(
                0,
                lambda m=msg: self._finish_send(
                    False,
                    count,
                    f"Erreur réseau : {m}",
                    payload,
                ),
            )

    def _finish_send(self, ok: bool, count: int, message: str, payload: str):
        self.send_button.configure(state="normal", text="📤 Envoyer configuration")

        color = self.SUCCESS if ok else self.DANGER
        self.send_status_label.configure(text=message, text_color=color)

        if ok:
            messagebox.showinfo(
                "Configuration GSM envoyée",
                f"Mode : {self.gsm_mode}\n"
                f"{count} numéro(s) envoyé(s) à l'ESP8266.\n\n"
                f"Destination : {ESP8266_IP}:{ESP8266_PORT}\n"
                f"Données :\n{payload.strip()}",
            )
        else:
            messagebox.showerror(
                "Erreur de communication",
                f"{message}\n\n"
                f"ESP8266 : {ESP8266_IP}:{ESP8266_PORT}",
            )


# ── USER MANAGEMENT VIEW ──────────────────────────────────────────────
class UserManagementView(ctk.CTkFrame):
    ROLES = ["viewer", "operator", "admin"]

    def __init__(self, master):
        super().__init__(master, fg_color='#55829f', corner_radius=0)
        self._users:        list[dict]           = []
        self._selected_uid: str | None           = None
        self._selected_row: ctk.CTkFrame | None  = None
        self._setup_ui()
        self._load_users()

    def _setup_ui(self):
        header = ctk.CTkFrame(self, fg_color="transparent")
        header.pack(fill=tk.X, padx=20, pady=(15, 5))
        ctk.CTkLabel(header, text="👥  Gestion des Utilisateurs",
                     font=("Arial", 22, "bold"), text_color="#FFFFFF").pack(side=tk.LEFT)
        ctk.CTkButton(header, text="⟳  Actualiser", width=130, height=36,
                      fg_color="#006666", hover_color="#009999",
                      font=("Arial", 13),
                      command=self._load_users).pack(side=tk.RIGHT, padx=5)

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill=tk.BOTH, expand=True, padx=20, pady=10)
        body.grid_columnconfigure(0, weight=3)
        body.grid_columnconfigure(1, weight=2)
        body.grid_rowconfigure(0, weight=1)

        list_frame = ctk.CTkFrame(body, fg_color='#3d5a6b', corner_radius=10)
        list_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        ctk.CTkLabel(list_frame, text="Utilisateurs enregistrés",
                     font=("Arial", 14, "bold"), text_color="#AADDFF").pack(
            pady=(12, 6), padx=15, anchor="w")

        col_frame = ctk.CTkFrame(list_frame, fg_color="#2d4a5b")
        col_frame.pack(fill=tk.X, padx=10, pady=(0, 4))
        for txt, w in [("Email", 260), ("Rôle", 80), ("Statut", 75), ("Créé le", 110)]:
            ctk.CTkLabel(col_frame, text=txt, width=w,
                         font=("Arial", 11, "bold"),
                         text_color="#80CCFF", anchor="w").pack(side=tk.LEFT, padx=6)

        self._list_scroll = ctk.CTkScrollableFrame(
            list_frame, fg_color="transparent", height=360)
        self._list_scroll.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)

        self._status_var = tk.StringVar(value="Chargement…")
        ctk.CTkLabel(list_frame, textvariable=self._status_var,
                     font=("Arial", 11), text_color="#AAAAAA").pack(
            anchor="w", padx=15, pady=(4, 10))

        detail = ctk.CTkFrame(body, fg_color='#3d5a6b', corner_radius=10)
        detail.grid(row=0, column=1, sticky="nsew")

        ctk.CTkLabel(detail, text="➕  Ajouter un utilisateur",
                     font=("Arial", 14, "bold"), text_color="#AADDFF").pack(
            pady=(15, 8), padx=15, anchor="w")
        self._new_email  = self._labeled_entry(detail, "Email")
        self._new_passwd = self._labeled_entry(detail, "Mot de passe", show="*")
        self._new_name   = self._labeled_entry(detail, "Nom d'affichage (opt.)")

        role_row = ctk.CTkFrame(detail, fg_color="transparent")
        role_row.pack(fill=tk.X, padx=15, pady=4)
        ctk.CTkLabel(role_row, text="Rôle", font=("Arial", 12),
                     text_color="#CCDDEE", width=140, anchor="w").pack(side=tk.LEFT)
        self._new_role = ctk.CTkOptionMenu(
            role_row, values=self.ROLES,
            fg_color="#005555", button_color="#007777",
            button_hover_color="#009999", font=("Arial", 12))
        self._new_role.set("viewer")
        self._new_role.pack(side=tk.LEFT, fill=tk.X, expand=True)

        ctk.CTkButton(detail, text="✅  Créer l'utilisateur",
                      fg_color="#007755", hover_color="#009966",
                      font=("Arial", 13, "bold"), height=38,
                      command=self._create_user).pack(fill=tk.X, padx=15, pady=(12, 6))

        ctk.CTkFrame(detail, height=2, fg_color="#2d4a5b").pack(fill=tk.X, padx=15, pady=10)

        ctk.CTkLabel(detail, text="🔧  Utilisateur sélectionné",
                     font=("Arial", 14, "bold"), text_color="#AADDFF").pack(
            pady=(4, 6), padx=15, anchor="w")
        self._sel_label = ctk.CTkLabel(detail, text="(aucune sélection)",
                                        font=("Arial", 12), text_color="#CCCCCC",
                                        wraplength=240)
        self._sel_label.pack(padx=15, pady=(0, 8), anchor="w")

        rc_row = ctk.CTkFrame(detail, fg_color="transparent")
        rc_row.pack(fill=tk.X, padx=15, pady=4)
        ctk.CTkLabel(rc_row, text="Nouveau rôle", font=("Arial", 12),
                     text_color="#CCDDEE", width=140, anchor="w").pack(side=tk.LEFT)
        self._edit_role = ctk.CTkOptionMenu(
            rc_row, values=self.ROLES,
            fg_color="#005555", button_color="#007777",
            button_hover_color="#009999", font=("Arial", 12))
        self._edit_role.set("viewer")
        self._edit_role.pack(side=tk.LEFT, fill=tk.X, expand=True)

        ctk.CTkButton(detail, text="💾  Enregistrer le rôle",
                      fg_color="#005588", hover_color="#0077AA",
                      font=("Arial", 12), height=36,
                      command=self._save_role).pack(fill=tk.X, padx=15, pady=4)
        ctk.CTkButton(detail, text="🔒  Désactiver l'accès",
                      fg_color="#775500", hover_color="#998800",
                      font=("Arial", 12), height=36,
                      command=lambda: self._toggle_user(disable=True)).pack(
            fill=tk.X, padx=15, pady=4)
        ctk.CTkButton(detail, text="🔓  Réactiver l'accès",
                      fg_color="#005533", hover_color="#007744",
                      font=("Arial", 12), height=36,
                      command=lambda: self._toggle_user(disable=False)).pack(
            fill=tk.X, padx=15, pady=4)
        ctk.CTkButton(detail, text="🗑️  Supprimer l'utilisateur",
                      fg_color="#880000", hover_color="#AA0000",
                      font=("Arial", 13, "bold"), height=38,
                      command=self._delete_user).pack(fill=tk.X, padx=15, pady=(10, 15))

    def _labeled_entry(self, parent, label: str, show: str = "") -> ctk.CTkEntry:
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill=tk.X, padx=15, pady=4)
        ctk.CTkLabel(row, text=label, font=("Arial", 12),
                     text_color="#CCDDEE", width=140, anchor="w").pack(side=tk.LEFT)
        entry = ctk.CTkEntry(row, font=("Arial", 12), height=32, show=show)
        entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        return entry

    def _set_status(self, msg: str):
        self._status_var.set(msg)

    def _select_user(self, uid: str, row_widget: ctk.CTkFrame):
        if self._selected_row:
            try:
                self._selected_row.configure(fg_color="#2d4a5b")
            except Exception:
                pass
        self._selected_uid = uid
        self._selected_row = row_widget
        row_widget.configure(fg_color="#1f5a8c")
        user = next((u for u in self._users if u["uid"] == uid), None)
        if user:
            self._sel_label.configure(text=f"✉  {user['email']}\n🆔 {uid[:24]}…")
            self._edit_role.set(user.get("role", "viewer"))

    def _build_user_row(self, user: dict):
        row = ctk.CTkFrame(self._list_scroll, fg_color="#2d4a5b", corner_radius=6)
        row.pack(fill=tk.X, pady=3)
        uid      = user["uid"]
        disabled = user.get("disabled", False)
        ctk.CTkLabel(row, text=user["email"], width=260,
                     font=("Arial", 12), text_color="#FFFFFF", anchor="w").pack(
            side=tk.LEFT, padx=6)
        ctk.CTkLabel(row, text=user.get("role", "—"), width=80,
                     font=("Arial", 11), text_color="#AADDFF", anchor="w").pack(
            side=tk.LEFT, padx=6)
        ctk.CTkLabel(row, text="Désactivé" if disabled else "Actif",
                     width=75, font=("Arial", 11, "bold"),
                     text_color="#FF7777" if disabled else "#77FF99",
                     anchor="w").pack(side=tk.LEFT, padx=6)
        ctk.CTkLabel(row, text=user.get("created", "—"), width=110,
                     font=("Arial", 11), text_color="#AAAAAA", anchor="w").pack(
            side=tk.LEFT, padx=6)
        ctk.CTkButton(row, text="Sélectionner", width=100, height=28,
                      fg_color="#004466", hover_color="#006688",
                      font=("Arial", 11),
                      command=lambda r=row, u=uid: self._select_user(u, r)
                      ).pack(side=tk.RIGHT, padx=8)

    def _refresh_list(self):
        for w in self._list_scroll.winfo_children():
            w.destroy()
        self._selected_row = None
        if not self._users:
            ctk.CTkLabel(self._list_scroll, text="Aucun utilisateur trouvé.",
                         text_color="#AAAAAA", font=("Arial", 12)).pack(pady=20)
            return
        for user in self._users:
            self._build_user_row(user)
        self._set_status(f"{len(self._users)} utilisateur(s) chargé(s).")

    def _load_users(self):
        self._set_status("Chargement en cours…")
        threading.Thread(target=self._fetch_users, daemon=True).start()

    def _fetch_users(self):
        try:
            roles_snap = admin_db.reference("users").get() or {}
            users      = []
            page       = admin_auth.list_users()
            while page:
                for u in page.users:
                    created = "—"
                    if u.user_metadata and u.user_metadata.creation_timestamp:
                        ts      = u.user_metadata.creation_timestamp / 1000
                        created = datetime.fromtimestamp(ts).strftime("%d/%m/%Y")
                    role = "—"
                    snap = roles_snap.get(u.uid)
                    if isinstance(snap, dict):
                        role = snap.get("role", "—")
                    users.append({
                        "uid":      u.uid,
                        "email":    u.email or "(sans email)",
                        "name":     u.display_name or "",
                        "disabled": u.disabled,
                        "created":  created,
                        "role":     role,
                    })
                page = page.get_next_page()
            self._users = users
            self.after(0, self._refresh_list)
        except Exception as e:
            logger.error(f"Erreur chargement utilisateurs : {e}", exc_info=True)
            self.after(0, lambda: self._set_status(f"Erreur : {e}"))

    def _create_user(self):
        email  = self._new_email.get().strip()
        passwd = self._new_passwd.get().strip()
        name   = self._new_name.get().strip()
        role   = self._new_role.get()
        if not email or not passwd:
            messagebox.showwarning("Champs requis", "Email et mot de passe requis.")
            return
        if len(passwd) < 6:
            messagebox.showwarning("Mot de passe", "Minimum 6 caractères.")
            return
        self._set_status("Création en cours…")
        threading.Thread(target=self._do_create_user,
                         args=(email, passwd, name, role), daemon=True).start()

    def _do_create_user(self, email, passwd, name, role):
        try:
            kwargs: dict = {"email": email, "password": passwd}
            if name:
                kwargs["display_name"] = name
            user = admin_auth.create_user(**kwargs)
            admin_db.reference(f"users/{user.uid}").set(
                {"email": email, "role": role, "name": name})
            self.after(0, lambda: messagebox.showinfo(
                "Succès", f"Utilisateur '{email}' créé (rôle : {role})."))
            self.after(0, self._clear_new_user_fields)
            self.after(0, self._load_users)
        except Exception as e:
            logger.error(f"Erreur création : {e}", exc_info=True)
            self.after(0, lambda: messagebox.showerror("Erreur", str(e)))
            self.after(0, lambda: self._set_status("Erreur à la création."))

    def _clear_new_user_fields(self):
        self._new_email.delete(0, tk.END)
        self._new_passwd.delete(0, tk.END)
        self._new_name.delete(0, tk.END)
        self._new_role.set("viewer")

    def _save_role(self):
        if not self._selected_uid:
            messagebox.showwarning("Sélection", "Sélectionnez d'abord un utilisateur.")
            return
        uid      = self._selected_uid
        new_role = self._edit_role.get()
        self._set_status("Mise à jour du rôle…")
        threading.Thread(target=self._do_save_role,
                         args=(uid, new_role), daemon=True).start()

    def _do_save_role(self, uid, role):
        try:
            admin_db.reference(f"users/{uid}/role").set(role)
            self.after(0, lambda: messagebox.showinfo("Succès", f"Rôle → {role}"))
            self.after(0, self._load_users)
        except Exception as e:
            self.after(0, lambda: messagebox.showerror("Erreur", str(e)))

    def _toggle_user(self, disable: bool):
        if not self._selected_uid:
            messagebox.showwarning("Sélection", "Sélectionnez d'abord un utilisateur.")
            return
        threading.Thread(target=self._do_toggle_user,
                         args=(self._selected_uid, disable), daemon=True).start()

    def _do_toggle_user(self, uid, disable):
        try:
            admin_auth.update_user(uid, disabled=disable)
            state = "désactivé" if disable else "réactivé"
            self.after(0, lambda: messagebox.showinfo("Succès", f"Accès {state}."))
            self.after(0, self._load_users)
        except Exception as e:
            self.after(0, lambda: messagebox.showerror("Erreur", str(e)))

    def _delete_user(self):
        if not self._selected_uid:
            messagebox.showwarning("Sélection", "Sélectionnez d'abord un utilisateur.")
            return
        user  = next((u for u in self._users if u["uid"] == self._selected_uid), {})
        email = user.get("email", self._selected_uid)
        if not messagebox.askyesno("Confirmer",
                                    f"Supprimer définitivement :\n\n{email}",
                                    icon="warning"):
            return
        threading.Thread(target=self._do_delete_user,
                         args=(self._selected_uid,), daemon=True).start()

    def _do_delete_user(self, uid):
        try:
            admin_auth.delete_user(uid)
            admin_db.reference(f"users/{uid}").delete()
            def _after():
                self._selected_uid = None
                self._selected_row = None
                self._sel_label.configure(text="(aucune sélection)")
                messagebox.showinfo("Supprimé", "Utilisateur supprimé.")
                self._load_users()
            self.after(0, _after)
        except Exception as e:
            self.after(0, lambda: messagebox.showerror("Erreur", str(e)))


# ── MAIN APPLICATION ──────────────────────────────────────────────────
class ExportedApp(ctk.CTk):
    @handle_error
    def __init__(self):
        super().__init__()
        self.alert_manager = AlertManager()
        # Lecture Firebase initiale AVANT la première mise à jour UI, sinon l'app affiche 0 au démarrage.
        fetch_firebase_once()
        self.sensor        = SensorSimulator(self.alert_manager)
        self._initialize_widgets()
        self._create_widgets()
        self.start_updates()
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _initialize_widgets(self):
        self.title('Water Monitoring System')
        self.geometry('1100x720')
        self.resizable(True, True)
        ctk.set_appearance_mode('dark')
        ctk.set_widget_scaling(1.0)
        self.current_view = None

    def _create_widgets(self):
        self.main_container = ctk.CTkFrame(self, fg_color='#2b2b2b')
        self.main_container.pack(fill=tk.BOTH, expand=True)

        self.sidebar = ctk.CTkFrame(self.main_container, width=220, fg_color='#008080')
        self.sidebar.pack(side=tk.LEFT, fill=tk.Y)
        self.sidebar.pack_propagate(False)

        ctk.CTkLabel(self.sidebar, text="Water\nMonitoring",
                      font=("Arial", 20, "bold"), text_color='#FFFFFF').pack(pady=30)

        for text, cmd in [
            ("📊  Tableau de Bord",       self.show_dashboard),
            ("📡  État du Système",       self.show_status),
            ("💬  Assistant Chat",        self.show_chatbot),
            ("📱  GSM / SMS",              self.show_gsm_config),
            ("👥  Gestion Utilisateurs",  self.show_user_management),
        ]:
            ctk.CTkButton(self.sidebar, text=text, width=180, height=40,
                           fg_color='#006666', hover_color='#80ffff',
                           text_color='#FFFFFF', corner_radius=8,
                           font=('Arial', 13), anchor="w",
                           command=cmd).pack(pady=6, padx=20)
        logo_file = resource_path("logo.png")
        if logo_file.is_file():
            logo_img = Image.open(logo_file)
            self.logo_ctk = ctk.CTkImage(light_image=logo_img, size=(200, 100))
            logo_label = ctk.CTkLabel(
                self.sidebar,
                image=self.logo_ctk,
                text="",
            )
        else:
            logger.warning(f"Logo introuvable : {logo_file}")
            logo_label = ctk.CTkLabel(
                self.sidebar,
                text="Water Monitoring",
                font=("Arial", 14, "bold"),
                text_color="#FFFFFF",
            )
        logo_label.pack(side=tk.BOTTOM, pady=10)
        ctk.CTkLabel(self, text='© Reserved for Nour Limem',
                     font=('Arial', 10, 'bold'), text_color='#FFFFFF').place(x=10, rely=0.97, anchor='w')
        ctk.CTkFrame(self.sidebar, height=2, fg_color="#005555").pack(
            fill=tk.X, padx=20, pady=(20, 5))
        ctk.CTkLabel(self.sidebar, text="Notifications",
                      font=("Arial", 12, "bold"), text_color="#CCCCCC").pack(pady=(10, 5))
        self._add_toggle(self.sidebar, "🔔 Toast Windows",
                          lambda v: setattr(self.alert_manager, "enable_toast", bool(v)))
        self._add_toggle(self.sidebar, "📢 Bannière",
                          lambda v: setattr(self.alert_manager, "enable_popup", bool(v)))
        self._add_toggle(self.sidebar, "🔊 Son",
                          lambda v: setattr(self.alert_manager, "enable_sound", bool(v)))

        content_wrapper = ctk.CTkFrame(self.main_container, fg_color='#55829f')
        content_wrapper.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True)

        self.banner = AlertBanner(content_wrapper)
        self.alert_manager.banner_widget = self.banner

        self.content_area = ctk.CTkFrame(content_wrapper, fg_color='#55829f')
        self.content_area.pack(fill=tk.BOTH, expand=True)

        self.show_dashboard()

    def _add_toggle(self, parent, label: str, callback):
        var   = tk.IntVar(value=1)
        frame = ctk.CTkFrame(parent, fg_color='transparent')
        frame.pack(pady=3, padx=15, fill=tk.X)
        ctk.CTkLabel(frame, text=label, font=("Arial", 11),
                      text_color="#DDDDDD", anchor="w").pack(
            side=tk.LEFT, fill=tk.X, expand=True)
        ctk.CTkSwitch(frame, text="", variable=var, width=40,
                       command=lambda: callback(var.get())).pack(side=tk.RIGHT)
        return var

    def _switch_view(self, ViewClass, *args):
        if self.current_view:
            self.current_view.destroy()
        self.current_view = ViewClass(self.content_area, *args)
        self.current_view.pack(fill=tk.BOTH, expand=True)

    def show_dashboard(self):
        self._switch_view(DashboardView, self.sensor)

    def show_status(self):
        self._switch_view(SystemStatusView, self.sensor)

    def show_chatbot(self):
        self._switch_view(ChatBotView, self.sensor)

    def show_gsm_config(self):
        self._switch_view(GSMConfigurationView)

    def show_user_management(self):
        self._switch_view(UserManagementView)

    def start_updates(self):
        self.update_sensors()

    def update_sensors(self):
        self.sensor.update()
        if isinstance(self.current_view, DashboardView):
            self.current_view.update_graphs()
        elif isinstance(self.current_view, SystemStatusView):
            self.current_view.update_display()
        self.after(READ_INTERVAL_MS, self.update_sensors)

    def _on_close(self):
        self.sensor.storage.save()
        logger.info("Données sauvegardées à la fermeture.")
        self.destroy()


if __name__ == '__main__':
    app = ExportedApp()
    app.mainloop()
