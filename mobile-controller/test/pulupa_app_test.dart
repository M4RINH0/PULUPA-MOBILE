import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pulupa_controller/app/pulupa_app.dart';
import 'package:pulupa_controller/features/sensors/simulated_sensors.dart';

Future<void> advance(WidgetTester tester, int ticks) async {
  for (var tick = 0; tick < ticks; tick++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pulupa/device'),
          (call) async => switch (call.method) {
            'loadSettings' => {'haptics': false},
            'wifi' => true,
            _ => throw MissingPluginException(),
          },
        );
  });

  testWidgets(
    'navigates, calibrates simulated sensors and rejects recalibration during motion',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final source = SimulatedSensors();
      await tester.pumpWidget(PulupaApp(source: source));
      await advance(tester, 4);
      expect(find.text('Motion Controller'), findsOneWidget);
      expect(find.text('Conectar ao jogo'), findsOneWidget);
      expect(find.text('Modo de simulação'), findsOneWidget);

      await tester.tap(find.text('Calibrar'));
      await advance(tester, 4);
      final calibrate = find.widgetWithText(
        FilledButton,
        'Calibrar e centralizar',
      );
      expect(tester.widget<FilledButton>(calibrate).onPressed, isNotNull);
      await tester.ensureVisible(calibrate);
      await tester.tap(calibrate);
      await tester.pump();
      expect(find.text('Medindo…'), findsOneWidget);

      await advance(tester, 55);
      expect(find.text('Posição neutra definida'), findsOneWidget);
      expect(find.text('Leituras estáveis'), findsOneWidget);

      final recalibrate = find.widgetWithText(FilledButton, 'Recalibrar');
      await tester.ensureVisible(recalibrate);
      await tester.tap(recalibrate);
      await tester.pump();
      source.moving = true;
      await advance(tester, 10);
      expect(find.text('Medição interrompida'), findsOneWidget);
      expect(find.text('Recalibrar'), findsOneWidget);

      await tester.tap(find.text('Laboratório'));
      await tester.pump();
      expect(find.text('Acelerômetro · m/s²'), findsOneWidget);
      expect(find.text('Giroscópio · rad/s'), findsOneWidget);
      expect(find.text('Quaternion'), findsOneWidget);
      expect(find.text('Simular movimento'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'home and pairing remain usable on a narrow display at larger text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 650);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(PulupaApp(source: SimulatedSensors()));
      await tester.pump();
      await tester.tap(find.text('Conectar ao jogo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Pareamento com o PC'), findsOneWidget);
      expect(find.text('Ler QR Code'), findsOneWidget);
      expect(find.text('Conectar por IP'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
