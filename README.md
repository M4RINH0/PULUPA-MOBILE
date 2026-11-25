# PULUPA Controller

Aplicativo Android que transforma o celular em um controle de movimento para **PULUPA! — Motion Party Games**.

O app combina captura IMU nativa, calibração de posição neutra, gestos experimentais e um laboratório de sensores. O servidor Windows recebe por WebSocket até quatro controles na rede local, mostra a orientação e as métricas de cada jogador e fornece uma interface local para jogos em Unity 6.

## Iniciar o servidor no Windows

Na raiz do repositório, com Python 3.11 ou superior no PATH.

```powershell
cd motion-server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m app
```

Abra [o painel no computador](http://127.0.0.1:8765). Se o PC tiver múltiplas interfaces, passe `--lan-ip <IPv4-do-PC>` ao servidor. O painel informa o endereço e o código para conexão manual e exibe o QR.

## Executar no Android

Com Flutter estável e Android SDK configurados no Windows, conecte um Android com depuração USB.

> Clone o repositório numa pasta sem `!` no caminho (por exemplo `git clone <url> C:\src\pulupa`); com `!`, o Gradle falha ao compilar. Veja a [configuração no Windows](docs/setup-windows.md).

```powershell
cd mobile-controller
flutter pub get
flutter devices
flutter run
```

Toque em **Conectar ao jogo** e leia o QR, ou informe IP, porta e código do painel. Em **Calibrar**, defina a posição neutra mantendo o celular imóvel durante dois segundos. Em **Laboratório**, observe orientação, sensores, gestos e métricas do envio.

No emulador Android, use o simulador de IMU do app. Em **Laboratório**, ative **Simular movimento** para gerar uma rotação e desative para testar a calibração.

```powershell
flutter run --dart-define=PULUPA_SIMULATE=true
```

## Verificar e compilar

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

O APK de depuração é gravado em `mobile-controller/build/app/outputs/flutter-apk/app-debug.apk`.

Para ver dados de quatro controles sem celulares, deixe o servidor aberto e rode o simulador em outro terminal na pasta `motion-server`.

```powershell
.\.venv\Scripts\python.exe -m app.simulator --players 4 --seconds 30
```

- [Configuração no Windows](docs/setup-windows.md)
- [Arquitetura e preparação para iOS](docs/architecture.md)
- [Calibração e convenções de eixos](docs/calibration.md)
- [Roteiro de testes](docs/testing.md)
- [Protocolo de movimento e pareamento](protocol/motion-protocol.md)
- [Integração com Unity 6](docs/unity.md)
