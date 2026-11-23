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

Nas fases 1 a 3 o app usa `ACCESS_NETWORK_STATE` para indicar Wi-Fi. A captura IMU usa sensores nativos e dispensa permissão de câmera e localização. O diagnóstico de rede informa a presença de Wi-Fi, sem certificar que um PC está acessível.

A partir da fase 4, a câmera será solicitada ao escolher a leitura de QR. O contrato prevê WebSocket em TCP 8765. Quando o servidor existir, permita conexões de entrada nessa porta no perfil **Privado** do Firewall do Windows e limite a origem à sub-rede local. Evite redirecionamento de portas no roteador.
