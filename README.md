# PULUPA Controller

Aplicativo Android que transforma o celular em um controle de movimento para **PULUPA! — Motion Party Games**.

As fases 1 a 3 incluem captura nativa de acelerômetro e giroscópio, orientação por quaternion, calibração de posição neutra, visualização 3D e laboratório de sensores. A captura solicita 100 Hz por padrão e o laboratório mostra a frequência realmente medida. O pareamento, o envio ao PC e o servidor entram na fase 4.

## Executar no Android

Com Flutter estável e Android SDK configurados no Windows, conecte um Android com depuração USB.

```powershell
cd mobile-controller
flutter pub get
flutter devices
flutter run
```

Use **Calibrar** para definir a posição neutra. Em **Laboratório**, gire o aparelho e observe o modelo, o quaternion, os vetores e as frequências.

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

- [Configuração no Windows](docs/setup-windows.md)
- [Arquitetura e preparação para iOS](docs/architecture.md)
- [Calibração e convenções de eixos](docs/calibration.md)
- [Roteiro de testes](docs/testing.md)
- [Protocolo de movimento e pareamento](protocol/motion-protocol.md)
