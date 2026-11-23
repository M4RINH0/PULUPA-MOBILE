import argparse
import asyncio
import json
import math
import socket
import statistics
from urllib.request import urlopen

import uvicorn
from websockets.asyncio.client import connect

from .main import create_app
from .protocol import envelope


def get_code(host: str, port: int) -> str:
    with urlopen(f"http://{host}:{port}/api/state", timeout=5) as response:
        state = json.load(response)
    if not state["active"]:
        raise RuntimeError("Inicie uma sessão no painel antes de simular.")
    return state["code"]


async def response(socket, kind: str) -> dict:
    while True:
        message = json.loads(await asyncio.wait_for(socket.recv(), timeout=5))
        if message["type"] == "ping":
            await socket.send(json.dumps(envelope("pong", id=message["id"])))
        elif message["type"] == "error":
            raise RuntimeError(f"Servidor recusou o simulador: {message['code']}")
        elif message["type"] == kind:
            return message


async def simulate(host: str, port: int, code: str, index: int, hz: int, seconds: float) -> dict:
    clock = asyncio.get_running_loop().time
    uri = f"ws://{host}:{port}/ws/controller"
    async with connect(uri, max_size=1024, proxy=None) as ws:
        await ws.send(json.dumps(envelope("hello", code=code, name=f"Simulador {index}", device="IMU simulada")))
        welcome = await response(ws, "welcome")
        player, session_id = welcome["player"], welcome["session"]
        await ws.send(json.dumps(envelope("calibration", calibrated=True)))
        await response(ws, "calibration_ack")

        rtts = []
        start = next_tick = clock()
        while (now := clock()) - start < seconds:
            angle = math.sin((now - start) * 2 + index) * 0.8
            motion = envelope(
                "motion", session=session_id, player=player, seq=len(rtts), t_us=int(now * 1e6),
                q=[math.sin(angle / 2), 0, 0, math.cos(angle / 2)],
                accel=[0, 9.80665 * math.cos(angle), -9.80665 * math.sin(angle)],
                gyro=[1.6 * math.cos((now - start) * 2 + index), 0, 0], calibrated=True, valid=True,
            )
            await ws.send(json.dumps(motion))
            ack = await response(ws, "motion_ack")
            if ack["seq"] != len(rtts):
                raise RuntimeError("Confirmação de sequência incompatível.")
            rtts.append((clock() - now) * 1000)
            next_tick += 1 / hz
            if next_tick < clock():
                next_tick = clock()
            await asyncio.sleep(max(0, next_tick - clock()))
        elapsed = clock() - start
        await ws.send(json.dumps(envelope("disconnect")))
        ordered = sorted(rtts)
        return {
            "player": player,
            "packets": len(rtts),
            "hz": round(len(rtts) / elapsed, 2),
            "ack_mean_ms": round(statistics.fmean(rtts), 3),
            "ack_p95_ms": round(ordered[math.ceil(0.95 * len(ordered)) - 1], 3),
        }


async def run(args):
    server_task = None
    server = None
    port = args.port
    try:
        if args.local_server:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
                server = uvicorn.Server(uvicorn.Config(
                    create_app("127.0.0.1", port), ws="websockets-sansio",
                    ws_max_size=1024, access_log=False, log_level="warning", proxy_headers=False,
                ))
                server_task = asyncio.create_task(server.serve(sockets=[listener]))
                while not server.started:
                    if server_task.done():
                        await server_task
                        raise RuntimeError("Servidor local indisponível.")
                    await asyncio.sleep(0.01)
                await run_clients(port, args)
                server.should_exit = True
                await server_task
        else:
            await run_clients(port, args)
    finally:
        if server_task is not None and not server_task.done():
            server.should_exit = True
            await server_task


async def run_clients(port, args):
    host = "127.0.0.1"
    code = await asyncio.to_thread(get_code, host, port)
    results = await asyncio.gather(*(
        simulate(host, port, code, index, args.hz, args.seconds)
        for index in range(1, args.players + 1)
    ))
    print(json.dumps(sorted(results, key=lambda result: result["player"]), ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Controles IMU simulados")
    parser.add_argument("--players", type=int, choices=range(1, 5), default=2)
    parser.add_argument("--hz", type=int, choices=(25, 30, 50, 60, 100), default=60)
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--local-server", action="store_true", help="Inicia um servidor isolado para medir")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds < 1 or not 1 <= args.port <= 65535:
        parser.error("use pelo menos um segundo e uma porta entre 1 e 65535")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
