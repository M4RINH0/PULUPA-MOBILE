import argparse
import socket

import uvicorn

from .main import create_app
from .protocol import is_lan


def default_route_ip() -> str | None:
    # connect() em UDP só escolhe a rota padrão; nenhum pacote é enviado.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
    except OSError:
        return None


def lan_candidates() -> list[str]:
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except socket.gaierror:
        return []
    return list(dict.fromkeys(address[0] for *_, address in infos if is_lan(address[0])))


def choose_lan_ip() -> tuple[str | None, list[str]]:
    """Prefere o IPv4 da rota padrão; adaptadores virtuais costumam aparecer antes no Windows."""
    preferred = default_route_ip()
    candidates = lan_candidates()
    if preferred and is_lan(preferred):
        candidates = [preferred, *(ip for ip in candidates if ip != preferred)]
    return (candidates[0] if candidates else None), candidates


def main():
    parser = argparse.ArgumentParser(description="Servidor local do PULUPA Controller")
    parser.add_argument("--lan-ip", help="IPv4 da interface usada pelos jogadores")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--local-only", action="store_true", help="Aceita apenas conexões no PC")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("a porta deve estar entre 1 e 65535")
    lan_ip = args.lan_ip
    if not lan_ip and args.local_only:
        lan_ip = "127.0.0.1"
    elif not lan_ip:
        lan_ip, candidates = choose_lan_ip()
        if len(candidates) > 1:
            print("Vários IPv4 locais encontrados: " + ", ".join(candidates), flush=True)
            print(f"Usando {lan_ip}. Para escolher outro, execute com --lan-ip <IPv4>.", flush=True)
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
