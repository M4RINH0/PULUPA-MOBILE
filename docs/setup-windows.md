# Instalação no Windows

1. Instale [Flutter estável](https://docs.flutter.dev/install/manual) e adicione a pasta `bin` ao PATH. O projeto foi criado com Flutter 3.50.1 e Dart 3.14.0.
2. Configure o [Android SDK](https://docs.flutter.dev/platform-integration/android/setup) com Android Studio ou com as ferramentas de linha de comando. O projeto compila com a plataforma Android 36 e suporta Android 7.0 (API 24) em diante. Use o JDK do Android Studio ou um JDK compatível com o Gradle do projeto.
3. Execute `flutter doctor --android-licenses` e revise as licenças solicitadas. Confira o ambiente com `flutter doctor -v`.
4. Ative a depuração USB no celular, conecte-o ao PC e autorize a depuração. Confirme que o aparelho aparece em `flutter devices`.

Execute os comandos a partir da raiz do repositório.

```powershell
cd mobile-controller
flutter pub get
flutter run
```

Para executar em um emulador, inicie o dispositivo virtual no Android Studio e passe `--dart-define=PULUPA_SIMULATE=true` ao `flutter run`. Se houver mais de um dispositivo, use `flutter run -d <id>` com um dos IDs mostrados por `flutter devices`.

Use um caminho curto, sem `!`, para compilar o app, por exemplo `C:\src\pulupa`. No caminho deste projeto no OneDrive, o wrapper do Gradle pode falhar com `No build receipt resource found` antes de executar a compilação.

## Rede e permissões

O Android usa `ACCESS_NETWORK_STATE` para indicar Wi-Fi e `INTERNET` para conversar com o PC. A permissão de câmera é solicitada ao abrir **Ler QR Code**. A conexão manual aceita IP, porta e código temporário mesmo com a câmera indisponível. O app usa o modelo do dispositivo como rótulo no painel. IP, códigos, tokens, leituras e nomes de jogador não são persistidos pelo app.

O servidor usa TCP 8765 por padrão e mantém o painel em `127.0.0.1`. No Firewall do Windows, permita conexões de entrada nessa porta no perfil **Privado**, com origem na sub-rede local. Use o IPv4 que aparece em `ipconfig` para a interface usada pelos jogadores. VPNs e redes de convidados com isolamento entre clientes podem impedir a descoberta do PC. Evite redirecionamento de portas no roteador.

Em caso de dúvida, confirme pelo navegador do PC que `http://127.0.0.1:8765` abre localmente. No celular, confirme que o IP usado coincide com o do painel e que o sistema está na mesma rede. O Wi-Fi ativo é apenas um indicador de rede disponível.

## Servidor e simulador

```powershell
cd motion-server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m app --lan-ip 192.168.1.20
```

Use `--local-only` para testes restritos ao PC. Um emulador Android padrão pode usar `10.0.2.2` no campo de IP para acessar o loopback do host. Para testar no aparelho físico, informe o IPv4 local do PC, mantenha o servidor aberto e use o código atual do painel.
