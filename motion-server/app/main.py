import asyncio
import io
import ipaddress
from pathlib import Path

import qrcode
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response
from qrcode.image.svg import SvgPathImage

from .protocol import ProtocolError, decode, envelope, integer, is_lan
from .session import Session, TokenBucket

STATIC = Path(__file__).with_name("static")
LOCAL_HOSTS = {"127.0.0.1", "::1", "localhost"}
PING_INTERVAL = 2
PEER_TIMEOUT = 8
ASSETS = {"dashboard.js", "dashboard.css"}
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Content-Type-Options": "nosniff",
}


def is_loopback(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def is_local_admin(request: Request | WebSocket) -> bool:
    if not request.client or not is_loopback(request.client.host):
        return False
    if request.url.hostname not in LOCAL_HOSTS:
        return False
    origin = request.headers.get("origin")
    return origin is None or origin == f"http://{request.url.netloc}"


def check_admin(request: Request):
    if not is_local_admin(request):
        raise HTTPException(403, "Acesse o painel pelo navegador do PC anfitrião.")


async def receive(socket: WebSocket) -> dict:
    message = await socket.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(message["code"])
    return decode(message.get("text"))


async def close_socket(socket: WebSocket, code: int):
    try:
        await socket.close(code=code)
    except (RuntimeError, WebSocketDisconnect, OSError):
        pass


def create_app(lan_ip: str, port: int = 8765) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    session = Session(lan_ip, port)

    @app.get("/")
    async def dashboard(request: Request):
        check_admin(request)
        return FileResponse(STATIC / "index.html", headers=SECURITY_HEADERS)

    @app.get("/assets/{name}")
    async def asset(request: Request, name: str):
        check_admin(request)
        if name not in ASSETS:
            raise HTTPException(404)
        return FileResponse(STATIC / name, headers=SECURITY_HEADERS)

    @app.get("/api/state")
    async def state(request: Request):
        check_admin(request)
        invite = session.invite()
        invite.pop("qr", None)
        return JSONResponse({**invite, "players": session.snapshots(metrics=True)}, headers=SECURITY_HEADERS)

    @app.get("/api/qr")
    async def qr_code(request: Request):
        check_admin(request)
        invite = session.invite()
        if not invite["active"]:
            raise HTTPException(410)
        image = qrcode.make(invite["qr"], image_factory=SvgPathImage, border=4)
        svg = io.BytesIO()
        image.save(svg)
        return Response(svg.getvalue(), media_type="image/svg+xml", headers=SECURITY_HEADERS)

    @app.post("/api/session")
    async def new_session(request: Request):
        nonlocal session
        check_admin(request)
        old = session
        old.expires = old.clock()
        session = Session(lan_ip, port)
        await asyncio.gather(*(
            close_socket(player.socket, 4002) for player in old.players.values() if player.connected
        ))
        return Response(status_code=204)

    @app.post("/api/players/{player_id}/disconnect")
    async def disconnect_player(request: Request, player_id: int):
        check_admin(request)
        player = session.players.pop(player_id, None)
        if player is None:
            raise HTTPException(404)
        if player.connected:
            await close_socket(player.socket, 4003)
        return Response(status_code=204)

    @app.post("/api/players/{player_id}/haptic")
    async def confirm_player(request: Request, player_id: int):
        check_admin(request)
        player = session.players.get(player_id)
        if player is None or not player.connected:
            raise HTTPException(404)
        try:
            await player.socket.send_json(envelope("haptic", event="confirm"))
        except (RuntimeError, WebSocketDisconnect, OSError):
            raise HTTPException(409) from None
        return Response(status_code=204)

    @app.websocket("/ws/controller")
    async def controller(socket: WebSocket):
        host = socket.client.host if socket.client else ""
        if socket.headers.get("origin") is not None or not (is_lan(host) or is_loopback(host)):
            await socket.close(code=1008)
            return
        await socket.accept()
        active = session
        player = None
        explicit = False
        try:
            hello = await asyncio.wait_for(receive(socket), timeout=5)
            player = active.join(hello, host, socket)
            await socket.send_json(player.welcome(active.id))
            now = active.clock()
            every_message = TokenBucket(240, 48, now)
            motion_rate = TokenBucket(120, 16, now)
            next_ping = now
            last_pong = now
            pending_ping = None
            errors = 0
            while True:
                now = active.clock()
                if active.expired or active.players.get(player.id) is not player:
                    await close_socket(socket, 4002)
                    break
                if now - last_pong >= PEER_TIMEOUT:
                    await close_socket(socket, 4000)
                    break
                if now >= next_ping:
                    ping_id = int(now * 1000000)
                    pending_ping = (ping_id, now)
                    await socket.send_json(envelope("ping", id=ping_id))
                    next_ping = now + PING_INTERVAL
                try:
                    message = await asyncio.wait_for(receive(socket), timeout=max(0.001, next_ping - now))
                except TimeoutError:
                    continue
                except ProtocolError:
                    errors += 1
                    if errors >= 3:
                        raise
                    await socket.send_json(envelope("error", code="invalid_message"))
                    continue
                now = active.clock()
                if not every_message.consume(now):
                    raise ProtocolError("rate_limit")
                kind = message["type"]
                if kind == "motion":
                    if not motion_rate.consume(now):
                        raise ProtocolError("rate_limit")
                    try:
                        player.accept(message, active.id, now)
                    except ProtocolError as error:
                        errors += 1
                        if errors >= 3:
                            raise
                        await socket.send_json(envelope("error", code=str(error)))
                    else:
                        await socket.send_json(envelope(
                            "motion_ack", seq=message["seq"], packets=player.packets, missing=player.missing,
                        ))
                elif kind == "calibration" and type(message.get("calibrated")) is bool:
                    if player.calibrated != message["calibrated"]:
                        player.latest = None
                    player.calibrated = message["calibrated"]
                    await socket.send_json(envelope("calibration_ack", calibrated=player.calibrated))
                elif kind == "ping" and integer(message.get("id")):
                    await socket.send_json(envelope("pong", id=message["id"]))
                elif kind == "pong" and pending_ping and message.get("id") == pending_ping[0]:
                    player.rtts.append((now - pending_ping[1]) * 1000)
                    last_pong = now
                    pending_ping = None
                elif kind == "disconnect":
                    explicit = True
                    await close_socket(socket, 1000)
                    break
                elif kind in {"calibration", "ping", "pong"}:
                    continue
                else:
                    errors += 1
                    if errors >= 3:
                        raise ProtocolError("invalid_message")
        except ProtocolError as error:
            try:
                await socket.send_json(envelope("error", code=str(error)))
            except (RuntimeError, WebSocketDisconnect, OSError):
                pass
            await close_socket(socket, 1008)
        except TimeoutError:
            await close_socket(socket, 4000)
        except (RuntimeError, WebSocketDisconnect, OSError):
            pass
        finally:
            if player is not None:
                active.leave(player, socket, explicit=explicit)

    @app.websocket("/ws/game")
    async def game(socket: WebSocket):
        if not is_local_admin(socket):
            await socket.close(code=1008)
            return
        await socket.accept()
        rate = TokenBucket(120, 12, session.clock())
        try:
            while True:
                message = await asyncio.wait_for(receive(socket), timeout=10)
                if message["type"] != "snapshot" or not rate.consume(session.clock()):
                    raise ProtocolError("invalid_message")
                await socket.send_json(envelope(
                    "snapshot", session=session.id, players=[] if session.expired else session.snapshots(),
                ))
        except (ProtocolError, TimeoutError):
            await close_socket(socket, 1008)
        except (RuntimeError, WebSocketDisconnect, OSError):
            pass

    return app
