import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final signedIn in [false, true]) {
    testWidgets(
      'Free banner routes ${signedIn ? 'signed-in' : 'anonymous'} user and fits accessible mobile size',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var opened = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SingleChildScrollView(
                  child: FreePlanBanner(
                    signedIn: signedIn,
                    onTurbo: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Бесплатный тариф'), findsOneWidget);
        expect(find.text(signedIn ? 'Турбо' : 'Войти'), findsOneWidget);
        expect(
          find.bySemanticsLabel(signedIn ? 'Купить Турбо' : 'Войти для Турбо'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('free-plan-turbo')),
        );
        await tester.tap(find.byKey(const ValueKey('free-plan-turbo')));
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('existing Turbo is never offered as another purchase', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FreePlanBanner(
            signedIn: true,
            turboEntitled: true,
            onTurbo: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('free-plan-banner')), findsNothing);
    expect(find.text('Подключить Турбо'), findsNothing);
    expect(find.text('Купить Турбо'), findsNothing);
  });
}
