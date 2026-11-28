import math
import re
import secrets
import statistics
import time
from collections import deque
from dataclasses import dataclass, field
from urllib.parse import urlencode

from .protocol import (
    ATTEMPT, BUTTONS, ProtocolError, TOKEN, device_label, envelope, player_name, validate_button, validate_motion,
)

COLORS = ("#345CFF", "#FF55A5", "#FFD928", "#8B5CF6")
SESSION_SECONDS = 7200
INVITE_SECONDS = 120
# Cobre reabrir o app depois de fechá-lo sem querer.
RESUME_SECONDS = 180
FRAME_SECONDS = 0.35
MANUAL_CODE = re.compile(r"[0-9]{6}")
HOST_FAILURES = 8
INVITE_FAILURES = 20


def token_matches(value, expected: str, pattern) -> bool:
    return type(value) is str and pattern.fullmatch(value) is not None and secrets.compare_digest(value, expected)


class TokenBucket:
    def __init__(self, rate: float, burst: float, now: float):
        self.rate = rate
        self.burst = burst
        self.tokens = burst
        self.last = now

    def consume(self, now: float) -> bool:
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


@dataclass
class Player:
    id: int
    name: str
    device: str
    socket: object
    key: str = field(default_factory=lambda: secrets.token_urlsafe(12))
    resume: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    previous_resume: str | None = None
    attempt: str | None = None
    welcomed: bool = False
    replaced: object | None = None
    connected: bool = True
    disconnected_at: float = 0
    calibrated: bool = False
    latest: dict | None = None
    last_motion_at: float = 0
    last_seq: int = -1
    last_timestamp: int = -1
    packets: int = 0
    missing: int = 0
    buttons: dict = field(default_factory=lambda: dict.fromkeys(BUTTONS, False))
    arrivals: deque = field(default_factory=lambda: deque(maxlen=160))
    rtts: deque = field(default_factory=lambda: deque(maxlen=40))

    @property
    def color(self) -> str:
        return COLORS[self.id - 1]

    def welcome(self, session_id: str) -> dict:
        return envelope("welcome", session=session_id, player=self.id, name=self.name,
                        color=self.color, player_key=self.key, resume=self.resume)

    def resume_matches(self, value) -> bool:
        current = token_matches(value, self.resume, TOKEN)
        previous = self.previous_resume is not None and token_matches(value, self.previous_resume, TOKEN)
        return current or previous

    def take_over(self, socket: object, presented: str | None = None):
        """Associa o jogador a um novo socket e renova o token de reconexão.

        O token apresentado (ou o atual) continua aceito até o servidor receber
        uma mensagem válida no novo socket, o que prova a entrega do welcome.
        """
        if self.connected and self.socket is not socket:
            self.replaced = self.socket
        self.connected = True
        self.socket = socket
        self.previous_resume = presented if presented is not None else self.resume
        self.resume = secrets.token_urlsafe(32)
        # Um app reaberto recomeça seq e pode reiniciar a origem de t_us; a
        # ordem só importa dentro de um mesmo socket, e o antigo é descartado.
        self.last_seq = -1
        self.last_timestamp = -1
        # O app reenvia o que estiver segurando assim que o welcome chega.
        self.release_buttons()
        self.arrivals.clear()
        self.rtts.clear()

    def confirm(self):
        self.previous_resume = None

    def accept(self, packet: dict, session_id: str, now: float) -> bool:
        motion = validate_motion(packet, session_id, self.id)
        sequence = motion["seq"]
        if sequence <= self.last_seq or motion["t_us"] <= self.last_timestamp:
            return False
        if self.last_seq >= 0:
            self.missing += sequence - self.last_seq - 1
        self.last_seq = sequence
        self.last_timestamp = motion["t_us"]
        self.calibrated = motion["calibrated"]
        self.latest = motion
        self.last_motion_at = now
        self.packets += 1
        self.arrivals.append(now)
        return True

    def press(self, message: dict, session_id: str) -> bool:
        """Aplica um `button`. Devolve True quando o estado do botão mudou."""
        button = validate_button(message, session_id, self.id)
        changed = self.buttons[button["button"]] != button["pressed"]
        self.buttons[button["button"]] = button["pressed"]
        return changed

    def release_buttons(self):
        """Sem conexão ninguém segura botão: solta todos."""
        self.buttons = dict.fromkeys(BUTTONS, False)

    def snapshot(self, now: float, metrics=False) -> dict:
        live = self.connected and now - self.last_motion_at <= FRAME_SECONDS
        result = {
            "player": self.id, "name": self.name, "color": self.color, "player_key": self.key,
            "connected": self.connected, "calibrated": self.calibrated,
            "motion": self.latest if live and self.latest and self.latest["valid"] else None,
            "buttons": dict(self.buttons) if self.connected else dict.fromkeys(BUTTONS, False),
        }
        if metrics:
            while self.arrivals and now - self.arrivals[0] > 2:
                self.arrivals.popleft()
            span = self.arrivals[-1] - self.arrivals[0] if len(self.arrivals) >= 2 else 0
            ordered = sorted(self.rtts)
            p95 = ordered[math.ceil(len(ordered) * 0.95) - 1] if ordered else None
            result.update(
                device=self.device,
                hz=(len(self.arrivals) - 1) / span if live and span else 0,
                packets=self.packets,
                loss=self.missing / (self.packets + self.missing) if self.packets >= 2 else None,
                rtt_mean_ms=statistics.fmean(self.rtts) if self.rtts else None,
                rtt_p95_ms=p95,
                jitter_ms=statistics.fmean(abs(b - a) for a, b in zip(self.rtts, list(self.rtts)[1:]))
                if len(self.rtts) > 1 else None,
            )
        return result


class Session:
    def __init__(self, lan_ip: str, port: int, clock=time.monotonic):
        self.lan_ip = lan_ip
        self.port = port
        self.clock = clock
        self.id = secrets.token_urlsafe(18)
        self.expires = clock() + SESSION_SECONDS
        self.players: dict[int, Player] = {}
        self._failures: dict[str, deque] = {}
        self.invite_failures = 0
        self._rotate_invite(clock())

    @property
    def expired(self) -> bool:
        return self.clock() >= self.expires

    def _rotate_invite(self, now: float):
        self.ticket = secrets.token_urlsafe(32)
        self.code = f"{secrets.randbelow(1_000_000):06d}"
        self.invite_expires = now + INVITE_SECONDS
        self.invite_failures = 0

    def invite(self) -> dict:
        now = self.clock()
        if self.expired:
            return {"active": False, "host": self.lan_ip, "port": self.port}
        if now >= self.invite_expires:
            self._rotate_invite(now)
        qr = "pulupa://pair?" + urlencode({
            "v": 1, "host": self.lan_ip, "port": self.port,
            "session": self.id, "ticket": self.ticket,
        })
        return {
            "active": True, "host": self.lan_ip, "port": self.port, "session": self.id,
            "code": self.code, "qr": qr, "invite_seconds": math.ceil(self.invite_expires - now),
        }

    def prune(self, now: float):
        self.players = {
            slot: player for slot, player in self.players.items()
            if player.connected or now - player.disconnected_at < RESUME_SECONDS
        }
        for host, failures in list(self._failures.items()):
            while failures and now - failures[0] >= 60:
                failures.popleft()
            if not failures:
                del self._failures[host]

    def _fail(self, host: str, now: float):
        self._failures.setdefault(host, deque()).append(now)
        self.invite_failures += 1
        if self.invite_failures >= INVITE_FAILURES:
            self._rotate_invite(now)

    def join(self, hello: dict, host: str, socket: object) -> Player:
        now = self.clock()
        if self.expired:
            raise ProtocolError("session_expired")
        if now >= self.invite_expires:
            self._rotate_invite(now)
        self.prune(now)
        if len(self._failures.get(host, ())) >= HOST_FAILURES:
            raise ProtocolError("retry_later")
        if hello.get("type") != "hello":
            raise ProtocolError("invalid_message")
        name = player_name(hello.get("name"))
        if name is None:
            raise ProtocolError("invalid_name")
        attempt = hello.get("attempt")
        if "attempt" in hello and (type(attempt) is not str or ATTEMPT.fullmatch(attempt) is None):
            raise ProtocolError("invalid_message")

        expected_session = hello.get("session") == self.id
        fields = hello.keys() - {"v", "type", "name", "device", "attempt"}
        if fields == {"session", "resume"} and expected_session:
            for player in self.players.values():
                if player.resume_matches(hello["resume"]):
                    player.take_over(socket, hello["resume"])
                    return player
        valid_invite = (
            fields == {"session", "ticket"} and expected_session
            and token_matches(hello["ticket"], self.ticket, TOKEN)
        )
        valid_code = fields == {"code"} and token_matches(hello["code"], self.code, MANUAL_CODE)
        if not (valid_invite or valid_code):
            self._fail(host, now)
            raise ProtocolError("invalid_invite")
        if attempt is not None:
            for player in self.players.values():
                if player.attempt is not None and secrets.compare_digest(player.attempt, attempt):
                    player.take_over(socket)
                    return player
        player_id = next((slot for slot in range(1, 5) if slot not in self.players), None)
        if player_id is None:
            raise ProtocolError("session_full")
        player = Player(player_id, name, device_label(hello.get("device")), socket, attempt=attempt)
        self.players[player_id] = player
        return player

    def leave(self, player: Player, socket: object, explicit=False):
        if self.players.get(player.id) is not player or player.socket is not socket:
            return
        if explicit:
            self.players.pop(player.id)
        else:
            player.connected = False
            player.disconnected_at = self.clock()
            player.latest = None
            player.release_buttons()

    def snapshots(self, metrics=False) -> list[dict]:
        now = self.clock()
        self.prune(now)
        return [self.players[slot].snapshot(now, metrics) for slot in sorted(self.players)]
