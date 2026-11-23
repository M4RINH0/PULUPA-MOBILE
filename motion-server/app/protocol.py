import ipaddress
import json
import math
import re

VERSION = 1
MAX_BYTES = 1024
MAX_INTEGER = 2**53 - 1
SESSION_ID = re.compile(r"[A-Za-z0-9_-]{22,64}")
TOKEN = re.compile(r"[A-Za-z0-9_-]{32,128}")
LOCAL_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
))
MOTION_KEYS = {
    "v", "type", "session", "player", "seq", "t_us", "q", "accel", "gyro",
    "calibrated", "valid",
}


class ProtocolError(ValueError):
    pass


def is_lan(host: str) -> bool:
    try:
        address = ipaddress.IPv4Address(host)
    except ipaddress.AddressValueError:
        return False
    return any(address in network for network in LOCAL_NETWORKS)


def integer(value, minimum=0, maximum=MAX_INTEGER) -> bool:
    return type(value) is int and minimum <= value <= maximum


def decode(text: str | None) -> dict:
    if text is None or len(text.encode("utf-8")) > MAX_BYTES:
        raise ProtocolError("invalid_message")
    try:
        message = json.loads(text)
    except (ValueError, RecursionError) as exc:
        raise ProtocolError("invalid_message") from exc
    if (
        type(message) is not dict
        or type(message.get("v")) is not int
        or message["v"] != VERSION
        or type(message.get("type")) is not str
    ):
        raise ProtocolError("invalid_message")
    return message


def envelope(kind: str, **fields) -> dict:
    return {"v": VERSION, "type": kind, **fields}


def label(value, limit: int, fallback="") -> str:
    if type(value) is not str:
        return fallback
    trimmed = value.strip()
    return trimmed if 0 < len(trimmed) <= limit and trimmed.isprintable() else fallback


def _vector(value, size: int, limit: float) -> list[float]:
    if (
        type(value) is not list or len(value) != size
        or any(type(n) not in (int, float) or not -limit <= n <= limit for n in value)
        or math.hypot(*value) > limit
    ):
        raise ProtocolError("invalid_motion")
    return value


def validate_motion(message: dict, session_id: str, player_id: int) -> dict:
    if (
        message.keys() != MOTION_KEYS
        or message["session"] != session_id
        or not integer(message["player"], 1, 4) or message["player"] != player_id
        or not integer(message["seq"]) or not integer(message["t_us"])
        or type(message["calibrated"]) is not bool or type(message["valid"]) is not bool
    ):
        raise ProtocolError("invalid_motion")
    q = _vector(message["q"], 4, 1.02)
    norm = math.hypot(*q)
    if abs(norm * norm - 1) > 0.02:
        raise ProtocolError("invalid_motion")
    _vector(message["accel"], 3, 500)
    _vector(message["gyro"], 3, 100)
    return {**message, "q": [n / norm for n in q]}
