import argparse
import socket

import uvicorn

from .main import create_app
from .protocol import is_lan


def choose_lan_ip() -> str | None:
    try:
        candidates = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except socket.gaierror:
        return None
    return next((address[0] for *_, address in candidates if is_lan(address[0])), None)


def main():
    parser = argparse.ArgumentParser(description="Servidor local do PULUPA Controller")
    parser.add_argument("--lan-ip", help="IPv4 da interface usada pelos jogadores")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--local-only", action="store_true", help="Aceita apenas conexões no PC")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("a porta deve estar entre 1 e 65535")
    lan_ip = args.lan_ip or ("127.0.0.1" if args.local_only else choose_lan_ip())
    if not args.local_only and (not lan_ip or not is_lan(lan_ip)):
        parser.error("informe o IPv4 local com --lan-ip ou execute com --local-only")
    lan_ip = lan_ip or "127.0.0.1"
    print(f"Painel no PC: http://127.0.0.1:{args.port}", flush=True)
    print(f"Pareamento: {lan_ip}:{args.port}", flush=True)
    uvicorn.run(
        create_app(lan_ip, args.port),
        host="127.0.0.1" if args.local_only else "0.0.0.0",
        port=args.port,
        ws="websockets-sansio",
        ws_max_size=1024,
        access_log=False,
        proxy_headers=False,
    )


if __name__ == "__main__":
    main()
