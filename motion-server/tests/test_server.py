import re
import unittest
from contextlib import ExitStack
from urllib.parse import parse_qs, urlparse

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import create_app
from app.protocol import ProtocolError, decode, envelope, validate_motion
from app.session import INVITE_SECONDS, RESUME_SECONDS, SESSION_SECONDS, Session, TokenBucket


def packet(session, player, sequence=0, **fields):
    return envelope(
        "motion", **{
            "session": session, "player": player, "seq": sequence, "t_us": 100 + sequence,
            "q": [0, 0, 0, 1], "accel": [0, 9.8, 0], "gyro": [0, 0, 0],
            "calibrated": True, "valid": True, **fields,
        },
    )


def wait_for(client, message_type):
    while True:
        message = client.receive_json()
        if message["type"] == "ping":
            client.send_json(envelope("pong", id=message["id"]))
        if message["type"] == message_type:
            return message


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
        for _ in range(8):
            with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
                self.session.join(bad, "192.168.1.2", object())
        with self.assertRaisesRegex(ProtocolError, "retry_later"):
            self.session.join(bad, "192.168.1.2", object())
        self.time = 61
        with self.assertRaisesRegex(ProtocolError, "invalid_invite"):
            self.session.join(bad, "192.168.1.2", object())


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
            self.assertEqual(wait_for(first, "error")["code"], "invalid_motion")
            first.send_json(packet(state["session"], 1, 2))
            wait_for(first, "motion_ack")
            first.send_json(packet(state["session"], 1, 1))
            wait_for(first, "motion_ack")
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
