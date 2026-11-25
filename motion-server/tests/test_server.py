import asyncio
import json
import re
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import PENDING_PER_HOST, create_app
from app.protocol import ProtocolError, decode, device_label, envelope, player_name, validate_motion
from app.session import (
    HOST_FAILURES, INVITE_FAILURES, INVITE_SECONDS, RESUME_SECONDS, SESSION_SECONDS, Session, TokenBucket,
)

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "fixtures"
URL = "ws://127.0.0.1/ws/controller"
ATTEMPT = "tentativa_de_pareamento_01"


def packet(session, player, sequence=0, **fields):
    return envelope(
        "motion", **{
            "session": session, "player": player, "seq": sequence, "t_us": 100 + sequence,
            "q": [0, 0, 0, 1], "accel": [0, 9.8, 0], "gyro": [0, 0, 0],
            "calibrated": True, "valid": True, **fields,
        },
    )


def wait_for(client, message_type, limit=50, seconds=10):
    # O servidor envia ping a cada 2 s, então cada receive retorna em tempo limitado.
    deadline = time.monotonic() + seconds
    for _ in range(limit):
        message = client.receive_json()
        if message["type"] == "ping":
            client.send_json(envelope("pong", id=message["id"]))
        if message["type"] == message_type:
            return message
        if time.monotonic() > deadline:
            break
    raise AssertionError(f"mensagem {message_type!r} não recebida")


def wait_close(client, limit=50):
    for _ in range(limit):
        message = client.receive()
        if message["type"] == "websocket.close":
            return message["code"]
        data = json.loads(message["text"])
        if data["type"] == "ping":
            client.send_json(envelope("pong", id=data["id"]))
    raise AssertionError("socket não foi encerrado")


def load_fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class ValidationTests(unittest.TestCase):
    def test_rejects_bad_message_shapes(self):
        for value in (None, " " * 1025, "[]", "broken", '{"v":1.0,"type":"ping"}'):
            with self.subTest(value=value), self.assertRaises(ProtocolError):
                decode(value)

    def test_rejects_wrong_player_and_bad_imu(self):
        valid = packet("session", 1)
        for changes in (
            {"player": 2}, {"player": True}, {"valid": 1}, {"seq": -1},
            {"q": [0, 0, 0, 0]}, {"accel": [500, 500, 0]},
            {"gyro": [0, 0, float("nan")]}, {"extra": 1},
        ):
            with self.subTest(changes=changes), self.assertRaises(ProtocolError):
                validate_motion({**valid, **changes}, "session", 1)

    def test_accepts_invalid_sample_marker(self):
        marker = packet("session_id_1234567890ab", 1, valid=False, calibrated=False, accel=[0, 0, 0])
        self.assertFalse(validate_motion(marker, "session_id_1234567890ab", 1)["valid"])

    def test_motion_fixtures(self):
        fixture = load_fixture("motion.json")
        self.assertRegex(fixture["session"], r"^[A-Za-z0-9_-]{22,64}$")
        for item in fixture["valid"]:
            with self.subTest(packet=item):
                text = json.dumps(item, ensure_ascii=False)
                self.assertLessEqual(len(text.encode("utf-8")), 1024)
                validate_motion(decode(text), fixture["session"], fixture["player"])
        for item in fixture["invalid"]:
            with self.subTest(reason=item["reason"]), self.assertRaises(ProtocolError):
                validate_motion(decode(json.dumps(item["packet"])), fixture["session"], fixture["player"])

    def test_name_fixtures(self):
        fixture = load_fixture("names.json")
        for name in fixture["valid"]:
            with self.subTest(name=name):
                self.assertEqual(player_name(name), name)
        for name, expected in fixture["normalized"]:
            with self.subTest(name=name):
                self.assertEqual(player_name(name), expected)
        for name in fixture["invalid"]:
            with self.subTest(name=name):
                self.assertIsNone(player_name(name))
        for value in (None, 1, ["Ana"]):
            self.assertIsNone(player_name(value))

    def test_device_label_falls_back(self):
        self.assertEqual(device_label("Pixel\u00a07"), "Pixel 7")
        self.assertEqual(device_label("Pixel\u202e"), "Dispositivo móvel")
        self.assertEqual(device_label(None), "Dispositivo móvel")

    def test_bucket_limits_traffic_and_refills(self):
        bucket = TokenBucket(120, 2, 0)
        self.assertTrue(bucket.consume(0))
        self.assertTrue(bucket.consume(0))
        self.assertFalse(bucket.consume(0))
        self.assertTrue(bucket.consume(0.01))


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.time = 0
        self.session = Session("192.168.1.10", 8765, clock=lambda: self.time)

    def test_rotates_invite_and_expires_session(self):
        self.assertRegex(self.session.code, r"^\d{6}$")
        old_ticket = self.session.ticket
        self.time = INVITE_SECONDS
        new = self.session.invite()
        query = parse_qs(urlparse(new["qr"]).query)
        self.assertNotEqual(query["ticket"][0], old_ticket)
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(envelope("hello", name="A", session=self.session.id, ticket=old_ticket), "192.168.1.2", object())
        self.time = SESSION_SECONDS
        self.assertFalse(self.session.invite()["active"])
        with self.assertRaisesRegex(ProtocolError, "session_expired"):
            self.session.join(envelope("hello", name="A", code=new["code"]), "192.168.1.2", object())

    def test_resume_rotates_token_and_expires_reserved_slot(self):
        first_socket = object()
        player = self.session.join(envelope("hello", name="A", code=self.session.code), "127.0.0.1", first_socket)
        self.session.leave(player, first_socket)
        secret = player.resume
        resume = envelope("hello", name="A", session=self.session.id, resume=secret)
        next_socket = object()
        same = self.session.join(resume, "127.0.0.1", next_socket)
        self.assertIs(same, player)
        self.assertNotEqual(secret, same.resume)
        self.session.leave(same, next_socket)
        self.time = RESUME_SECONDS
        self.assertEqual(self.session.snapshots(), [])
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(resume, "127.0.0.1", object())

    def test_rate_limits_unsuccessful_codes_by_peer(self):
        bad = envelope("hello", name="A", code="xxxxxx")
        for _ in range(HOST_FAILURES):
            with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
                self.session.join(bad, "192.168.1.2", object())
        with self.assertRaisesRegex(ProtocolError, "retry_later"):
            self.session.join(bad, "192.168.1.2", object())
        self.time = 61
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(bad, "192.168.1.2", object())


    def test_previous_resume_token_is_accepted_until_confirmed(self):
        first = object()
        player = self.session.join(envelope("hello", name="A", code=self.session.code), "127.0.0.1", first)
        original = player.resume
        hello = envelope("hello", name="A", session=self.session.id, resume=original)
        second = object()
        self.assertIs(self.session.join(hello, "127.0.0.1", second), player)
        self.assertIs(player.socket, second)
        self.assertIs(player.replaced, first)
        rotated = player.resume
        third = object()
        self.assertIs(self.session.join(hello, "127.0.0.1", third), player)
        self.assertNotIn(player.resume, (original, rotated))
        player.confirm()
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(hello, "127.0.0.1", object())
        self.session.leave(player, first)
        self.assertTrue(player.connected)

    def test_attempt_makes_first_pairing_idempotent(self):
        hello = envelope("hello", name="A", code=self.session.code, attempt=ATTEMPT)
        first = self.session.join(hello, "127.0.0.1", object())
        resume = first.resume
        again = self.session.join(hello, "127.0.0.1", object())
        self.assertIs(again, first)
        self.assertNotEqual(again.resume, resume)
        other = self.session.join(envelope("hello", name="B", code=self.session.code), "127.0.0.1", object())
        self.assertEqual(other.id, 2)
        for attempt in ("curto", "x" * 65, "com espaço__________", 123):
            with self.subTest(attempt=attempt), self.assertRaisesRegex(ProtocolError, "invalid_message"):
                self.session.join(envelope("hello", name="C", code=self.session.code, attempt=attempt),
                                  "127.0.0.1", object())

    def test_rejects_invalid_names(self):
        for name in (None, "", "   ", "Ana\u202e", "A" * 33):
            hello = envelope("hello", name=name, code=self.session.code)
            with self.subTest(name=name), self.assertRaisesRegex(ProtocolError, "invalid_name"):
                self.session.join(hello, "127.0.0.1", object())
        player = self.session.join(envelope("hello", name="Ana\u00a0Bia", code=self.session.code),
                                   "127.0.0.1", object())
        self.assertEqual(player.name, "Ana Bia")

    def test_global_failures_rotate_invite(self):
        ticket = self.session.ticket
        bad = envelope("hello", name="A", code="xxxxxx")
        for index in range(INVITE_FAILURES):
            with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
                self.session.join(bad, f"192.168.1.{index % 4 + 2}", object())
        self.assertNotEqual(self.session.ticket, ticket)
        self.assertEqual(self.session.invite_failures, 0)
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(envelope("hello", name="A", session=self.session.id, ticket=ticket),
                              "192.168.1.9", object())


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.http = TestClient(create_app("192.168.1.10"), base_url="http://127.0.0.1", client=("127.0.0.1", 50001))
        self.addCleanup(self.http.close)

    def test_dashboard_routes_and_local_administration(self):
        self.assertEqual(self.http.get("/").status_code, 200)
        self.assertEqual(self.http.get("/assets/dashboard.js").status_code, 200)
        self.assertIn("image/svg+xml", self.http.get("/api/qr").headers["content-type"])
        self.assertEqual(self.http.post("/api/session", headers={"Origin": "http://other.test"}).status_code, 403)
        self.assertEqual(self.http.get("/api/state", headers={"Host": "other.test"}).status_code, 403)
        self.assertEqual(self.http.post("/api/session").status_code, 204)

    def test_four_sockets_motion_game_haptic_kick_and_slot_reuse(self):
        state = self.http.get("/api/state").json()
        url = "ws://127.0.0.1/ws/controller"
        with ExitStack() as stack:
            players = []
            for index in range(1, 5):
                ws = stack.enter_context(self.http.websocket_connect(url))
                ws.send_json(envelope("hello", name=f"Jogador {index}", device="Teste", code=state["code"]))
                player = wait_for(ws, "welcome")
                self.assertEqual(player["player"], index)
                self.assertEqual(len(player["player_key"]), 16)
                self.assertRegex(player["color"], re.compile(r"#[0-9A-F]{6}"))
                players.append(ws)
                ws.send_json(packet(player["session"], index, accel=[index, 9.8, 0]))
                self.assertEqual(wait_for(ws, "motion_ack")["seq"], 0)

            extra = stack.enter_context(self.http.websocket_connect(url))
            extra.send_json(envelope("hello", name="Extra", code=state["code"]))
            self.assertEqual(wait_for(extra, "error")["code"], "session_full")
            game = stack.enter_context(self.http.websocket_connect("ws://127.0.0.1/ws/game"))
            game.send_json(envelope("snapshot"))
            frames = game.receive_json()["players"]
            self.assertEqual([frame["motion"]["accel"][0] for frame in frames], [1, 2, 3, 4])

            first = players[0]
            first.send_json(packet(state["session"], 2, 1))
            rejected = wait_for(first, "motion_ack")
            self.assertEqual((rejected["seq"], rejected["accepted"], rejected["code"]), (1, False, "invalid_motion"))
            first.send_json(packet(state["session"], 1, 2))
            self.assertTrue(wait_for(first, "motion_ack")["accepted"])
            first.send_json(packet(state["session"], 1, 1))
            late = wait_for(first, "motion_ack")
            self.assertEqual((late["seq"], late["accepted"]), (1, True))
            snapshot = self.http.get("/api/state").json()["players"]
            self.assertEqual(snapshot[0]["packets"], 2)
            self.assertAlmostEqual(snapshot[0]["loss"], 1 / 3)

            self.assertEqual(self.http.post("/api/players/2/haptic").status_code, 204)
            self.assertEqual(wait_for(players[1], "haptic")["event"], "confirm")
            self.assertEqual(self.http.post("/api/players/2/disconnect").status_code, 204)
            with self.assertRaises(WebSocketDisconnect) as close:
                players[1].receive_json()
            self.assertEqual(close.exception.code, 4003)
            self.assertEqual([p["player"] for p in self.http.get("/api/state").json()["players"]], [1, 3, 4])

            replacement = stack.enter_context(self.http.websocket_connect(url))
            replacement.send_json(envelope("hello", name="Novo", code=state["code"]))
            new_player = wait_for(replacement, "welcome")
            self.assertEqual(new_player["player"], 2)
            self.assertNotEqual(new_player["player_key"], frames[1]["player_key"])

    def test_websocket_resumes_and_explicit_disconnect_releases_player(self):
        state = self.http.get("/api/state").json()
        url = "ws://127.0.0.1/ws/controller"
        with self.http.websocket_connect(url) as ws:
            ws.send_json(envelope("hello", name="Teste", code=state["code"]))
            welcome = wait_for(ws, "welcome")
            ws.send_json(packet(state["session"], welcome["player"], 10))
            wait_for(ws, "motion_ack")

        with self.http.websocket_connect(url) as ws:
            ws.send_json(envelope("hello", name="Teste", session=state["session"], resume=welcome["resume"]))
            resumed = wait_for(ws, "welcome")
            self.assertEqual(resumed["player"], welcome["player"])
            self.assertEqual(resumed["player_key"], welcome["player_key"])
            self.assertNotEqual(resumed["resume"], welcome["resume"])
            ws.send_json(packet(state["session"], resumed["player"], 11))
            wait_for(ws, "motion_ack")
            self.assertEqual(self.http.get("/api/state").json()["players"][0]["packets"], 2)
            ws.send_json(envelope("disconnect"))
            while True:
                msg = ws.receive()
                if msg["type"] == "websocket.close":
                    self.assertEqual(msg["code"], 1000)
                    break
        self.assertEqual(self.http.get("/api/state").json()["players"], [])

    def hello(self, ws, **fields):
        state = self.http.get("/api/state").json()
        credentials = fields or {"code": state["code"]}
        ws.send_json(envelope("hello", name="Teste", **credentials))
        return wait_for(ws, "welcome")

    def test_resume_takeover_closes_old_socket_and_grants_grace(self):
        with ExitStack() as stack:
            old = stack.enter_context(self.http.websocket_connect(URL))
            welcome = self.hello(old)
            session_id = welcome["session"]
            middle = stack.enter_context(self.http.websocket_connect(URL))
            taken = self.hello(middle, session=session_id, resume=welcome["resume"])
            self.assertEqual((taken["player"], taken["player_key"]), (welcome["player"], welcome["player_key"]))
            self.assertNotEqual(taken["resume"], welcome["resume"])
            self.assertEqual(wait_close(old), 4001)

            # O welcome anterior pode ter se perdido: o token antigo ainda vale.
            newest = stack.enter_context(self.http.websocket_connect(URL))
            again = self.hello(newest, session=session_id, resume=welcome["resume"])
            self.assertEqual(again["player"], welcome["player"])
            self.assertEqual(wait_close(middle), 4001)
            players = self.http.get("/api/state").json()["players"]
            self.assertEqual([(p["player"], p["connected"]) for p in players], [(1, True)])

            newest.send_json(packet(session_id, again["player"], 0))
            self.assertTrue(wait_for(newest, "motion_ack")["accepted"])
            stale = stack.enter_context(self.http.websocket_connect(URL))
            stale.send_json(envelope("hello", name="Teste", session=session_id, resume=welcome["resume"]))
            self.assertEqual(wait_for(stale, "error")["code"], "invalid_invite")
            self.assertEqual(wait_close(stale), 1008)

    def test_invalid_sample_keeps_snapshot_motion_empty(self):
        with self.http.websocket_connect(URL) as ws:
            welcome = self.hello(ws)
            ws.send_json(packet(welcome["session"], welcome["player"], 0))
            self.assertTrue(wait_for(ws, "motion_ack")["accepted"])
            self.assertIsNotNone(self.http.get("/api/state").json()["players"][0]["motion"])
            ws.send_json(packet(welcome["session"], welcome["player"], 1, valid=False, accel=[0, 0, 0]))
            self.assertTrue(wait_for(ws, "motion_ack")["accepted"])
            player = self.http.get("/api/state").json()["players"][0]
            self.assertEqual((player["motion"], player["packets"], player["connected"]), (None, 2, True))

    def test_attempt_reuses_player_over_websocket(self):
        with ExitStack() as stack:
            code = self.http.get("/api/state").json()["code"]
            first = stack.enter_context(self.http.websocket_connect(URL))
            welcome = self.hello(first, code=code, attempt=ATTEMPT)
            second = stack.enter_context(self.http.websocket_connect(URL))
            repeated = self.hello(second, code=code, attempt=ATTEMPT)
            self.assertEqual((repeated["player"], repeated["player_key"]), (welcome["player"], welcome["player_key"]))
            self.assertEqual(wait_close(first), 4001)
            self.assertEqual(len(self.http.get("/api/state").json()["players"]), 1)

    def test_consecutive_error_budget_resets_after_valid_message(self):
        with self.http.websocket_connect(URL) as ws:
            welcome = self.hello(ws)
            for round_id in range(1, 4):
                for _ in range(2):
                    ws.send_text("quebrado")
                    self.assertEqual(wait_for(ws, "error")["code"], "invalid_message")
                ws.send_json(envelope("ping", id=round_id))
                self.assertEqual(wait_for(ws, "pong")["id"], round_id)
            ws.send_json(packet(welcome["session"], welcome["player"], 0, seq="x"))
            self.assertEqual(wait_for(ws, "error")["code"], "invalid_motion")
            ws.send_json(envelope("desconhecido"))
            self.assertEqual(wait_for(ws, "error")["code"], "invalid_message")
            ws.send_text("quebrado")
            self.assertEqual(wait_for(ws, "error")["code"], "invalid_message")
            self.assertEqual(wait_close(ws), 1008)

    def test_names_are_validated_on_hello(self):
        code = self.http.get("/api/state").json()["code"]
        with self.http.websocket_connect(URL) as ws:
            ws.send_json(envelope("hello", name="Ana\u202e", code=code))
            self.assertEqual(wait_for(ws, "error")["code"], "invalid_name")
            self.assertEqual(wait_close(ws), 1008)
        for name, expected in (("Ana \U0001F469\u200d\U0001F4BB", "Ana \U0001F469\u200d\U0001F4BB"),
                               ("\u00a0Ana\u00a0Bia ", "Ana Bia")):
            with self.subTest(name=name), self.http.websocket_connect(URL) as ws:
                ws.send_json(envelope("hello", name=name, code=code))
                self.assertEqual(wait_for(ws, "welcome")["name"], expected)

    def test_limits_pending_handshakes_per_host(self):
        with ExitStack() as stack:
            for _ in range(PENDING_PER_HOST):
                stack.enter_context(self.http.websocket_connect(URL))
            with self.http.websocket_connect(URL) as extra:
                self.assertEqual(extra.receive_json()["code"], "retry_later")
                self.assertEqual(wait_close(extra), 1008)
        with self.http.websocket_connect(URL) as ws:
            self.assertEqual(self.hello(ws)["player"], 1)

    def test_failed_welcome_releases_new_player(self):
        app = create_app("192.168.1.10")
        http = TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 50001))
        self.addCleanup(http.close)
        code = http.get("/api/state").json()["code"]
        incoming = [
            {"type": "websocket.connect"},
            {"type": "websocket.receive", "text": json.dumps(envelope("hello", name="A", code=code))},
        ]
        sent = []

        async def receive():
            if incoming:
                return incoming.pop(0)
            await asyncio.sleep(5)
            return {"type": "websocket.disconnect", "code": 1006}

        async def send(message):
            sent.append(message["type"])
            if message["type"] == "websocket.send":
                raise OSError("falha de envio")

        scope = {
            "type": "websocket", "asgi": {"version": "3.0"}, "scheme": "ws", "path": "/ws/controller",
            "raw_path": b"/ws/controller", "query_string": b"", "root_path": "", "headers": [],
            "client": ("127.0.0.1", 50002), "server": ("127.0.0.1", 8765), "subprotocols": [],
        }
        asyncio.run(asyncio.wait_for(app(scope, receive, send), timeout=5))
        self.assertIn("websocket.send", sent)
        self.assertEqual(http.get("/api/state").json()["players"], [])


class PeerTimeoutTests(unittest.TestCase):
    def test_closes_silent_peer_with_4000(self):
        self.time = 0.0
        app = create_app("192.168.1.10", clock=lambda: self.time)
        http = TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 50001))
        self.addCleanup(http.close)
        code = http.get("/api/state").json()["code"]
        with http.websocket_connect(URL) as ws:
            ws.send_json(envelope("hello", name="A", code=code))
            self.assertEqual(ws.receive_json()["type"], "welcome")
            self.assertEqual(ws.receive_json()["type"], "ping")
            self.time = 9.0
            ws.send_json(envelope("ping", id=7))
            self.assertEqual(ws.receive_json(), envelope("pong", id=7))
            self.assertEqual(ws.receive()["code"], 4000)


class LanAddressTests(unittest.TestCase):
    def test_prefers_default_route_and_lists_candidates(self):
        from unittest import mock

        from app import __main__ as cli

        infos = [(None, None, None, None, (ip, 0)) for ip in ("172.20.0.1", "192.168.0.5", "172.20.0.1")]
        with mock.patch.object(cli, "default_route_ip", return_value="192.168.0.5"), \
                mock.patch.object(cli.socket, "getaddrinfo", return_value=infos):
            self.assertEqual(cli.choose_lan_ip(), ("192.168.0.5", ["192.168.0.5", "172.20.0.1"]))
        with mock.patch.object(cli, "default_route_ip", return_value="8.8.4.4"), \
                mock.patch.object(cli.socket, "getaddrinfo", return_value=infos):
            self.assertEqual(cli.choose_lan_ip()[0], "172.20.0.1")
        with mock.patch.object(cli, "default_route_ip", return_value=None), \
                mock.patch.object(cli.socket, "getaddrinfo", side_effect=cli.socket.gaierror):
            self.assertEqual(cli.choose_lan_ip(), (None, []))
