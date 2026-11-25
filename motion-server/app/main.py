import asyncio
import io
import ipaddress
import time
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
HELLO_TIMEOUT = 3
MAX_ERRORS = 3
PENDING_TOTAL = 16
PENDING_PER_HOST = 4
SEND_ERRORS = (RuntimeError, WebSocketDisconnect, OSError)
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


def create_app(lan_ip: str, port: int = 8765, clock=time.monotonic) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    session = Session(lan_ip, port, clock)
    pending: dict[str, int] = {}

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
        session = Session(lan_ip, port, clock)
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
        if sum(pending.values()) >= PENDING_TOTAL or pending.get(host, 0) >= PENDING_PER_HOST:
            # Limita handshakes ainda não autenticados (global e por origem).
            try:
                await socket.send_json(envelope("error", code="retry_later"))
            except SEND_ERRORS:
                pass
            await close_socket(socket, 1008)
            return
        active = session
        player = None
        explicit = False
        pending[host] = pending.get(host, 0) + 1
        try:
            try:
                hello = await asyncio.wait_for(receive(socket), timeout=HELLO_TIMEOUT)
            finally:
                pending[host] -= 1
                if not pending[host]:
                    del pending[host]
            player = active.join(hello, host, socket)
            try:
                await socket.send_json(player.welcome(active.id))
            except SEND_ERRORS:
                # Jogador recém-criado que nunca recebeu welcome não reserva o slot.
                explicit = not player.welcomed
                raise
            player.welcomed = True
            replaced, player.replaced = player.replaced, None
            if replaced is not None:
                await close_socket(replaced, 4001)
            now = active.clock()
            every_message = TokenBucket(240, 48, now)
            motion_rate = TokenBucket(120, 16, now)
            next_ping = now
            last_pong = now
            pending_ping = None
            errors = 0

            async def reject(code: str, seq=None):
                nonlocal errors
                errors += 1
                if errors >= MAX_ERRORS:
                    raise ProtocolError(code)
                if seq is None:
                    await socket.send_json(envelope("error", code=code))
                else:
                    await socket.send_json(envelope(
                        "motion_ack", seq=seq, accepted=False, code=code,
                        packets=player.packets, missing=player.missing,
                    ))

            def valid():
                # Mensagem válida: zera o orçamento de erros consecutivos e
                # confirma a entrega do welcome (descarta o token anterior).
                nonlocal errors
                errors = 0
                player.confirm()

            while True:
                now = active.clock()
                if active.expired or active.players.get(player.id) is not player:
                    await close_socket(socket, 4002)
                    break
                if player.socket is not socket:
                    await close_socket(socket, 4001)
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
                except ProtocolError as error:
                    await reject(str(error))
                    continue
                if player.socket is not socket:
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
                        seq = message.get("seq")
                        await reject(str(error), seq if integer(seq) else None)
                    else:
                        valid()
                        # Repetidos ou fora de ordem também são confirmados, sem aplicar.
                        await socket.send_json(envelope(
                            "motion_ack", seq=message["seq"], accepted=True,
                            packets=player.packets, missing=player.missing,
                        ))
                elif kind == "calibration" and type(message.get("calibrated")) is bool:
                    valid()
                    if player.calibrated != message["calibrated"]:
                        player.latest = None
                    player.calibrated = message["calibrated"]
                    await socket.send_json(envelope("calibration_ack", calibrated=player.calibrated))
                elif kind == "ping" and integer(message.get("id")):
                    valid()
                    await socket.send_json(envelope("pong", id=message["id"]))
                elif kind == "pong" and pending_ping and message.get("id") == pending_ping[0]:
                    valid()
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
                    await reject("invalid_message")
        except ProtocolError as error:
            try:
                await socket.send_json(envelope("error", code=str(error)))
            except SEND_ERRORS:
                pass
            await close_socket(socket, 1008)
        except TimeoutError:
            await close_socket(socket, 4000)
        except SEND_ERRORS:
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
