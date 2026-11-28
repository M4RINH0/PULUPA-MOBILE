import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pulupa_controller/features/controls/controller_pad_page.dart';

void main() {
  testWidgets('a hold button follows the first finger only', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: HoldButton(
            label: 'A',
            caption: 'Segure',
            semanticsLabel: 'Botão A',
            color: Colors.blue,
            size: 200,
            held: false,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final centre = tester.getCenter(find.byType(HoldButton));

    final first = await tester.startGesture(centre);
    await tester.pump();
    expect(changes, [true]);

    // A second finger (a palm, a thumb slipping) neither presses again nor
    // releases when it lifts.
    final second = await tester.startGesture(centre + const Offset(20, 20));
    await second.up();
    await tester.pump();
    expect(changes, [true]);

    await first.up();
    await tester.pump();
    expect(changes, [true, false]);

    // A touch that the system takes over (an edge swipe) counts as a release.
    final cancelled = await tester.startGesture(centre);
    await cancelled.cancel();
    await tester.pump();
    expect(changes, [true, false, true, false]);
  });

  testWidgets('touches outside the button do nothing', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.center,
          child: HoldButton(
            label: 'B',
            caption: 'Centralizar',
            semanticsLabel: 'Botão B',
            color: Colors.white,
            size: 80,
            held: false,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    final edge = await tester.startGesture(const Offset(2, 2));
    await edge.up();
    await tester.pump();
    expect(changes, isEmpty);
  });
}
