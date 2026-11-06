import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dropo/main.dart';

void main() {
  test('eligibility, foreground and durable claim are all required', () async {
    var eligible = false;
    var visible = true;
    var shown = false;
    var presentations = 0;
    AndroidReviewPromptCoordinator create() => AndroidReviewPromptCoordinator(
      readStatus: () async => {'eligible': eligible, 'shown': shown},
      claim: () async {
        shown = true;
        return {'claimed': true};
      },
      canPresent: () => visible,
      present: () async {
        expect(shown, isTrue);
        presentations++;
      },
    );
    final coordinator = create();
    await coordinator.check();
    expect(presentations, 0);
    eligible = true;
    visible = false;
    await coordinator.check();
    expect(shown, isFalse);
    visible = true;
    await coordinator.check();
    await coordinator.check();
    await create().check();
    expect(presentations, 1);
  });

  test(
    'concurrent refreshes and lifecycle changes cannot duplicate a prompt',
    () async {
      final ready = Completer<Map<String, dynamic>>();
      var visible = true;
      var claims = 0;
      var presentations = 0;
      final coordinator = AndroidReviewPromptCoordinator(
        readStatus: () => ready.future,
        claim: () async {
          claims++;
          return {'claimed': true};
        },
        canPresent: () => visible,
        present: () async {
          presentations++;
        },
      );
      final first = coordinator.check();
      await coordinator.check();
      visible = false;
      ready.complete({'eligible': true});
      await first;
      expect(claims, 0);
      visible = true;
      await Future.wait([coordinator.check(), coordinator.check()]);
      expect(claims, 1);
      expect(presentations, 1);
    },
  );

  test('unavailable native storage and failed claims do not present', () async {
    var failRead = true;
    var presentations = 0;
    final coordinator = AndroidReviewPromptCoordinator(
      readStatus: () async {
        if (failRead) throw StateError('unavailable');
        return {'eligible': true};
      },
      claim: () async => {'claimed': false},
      canPresent: () => true,
      present: () async {
        presentations++;
      },
    );
    await coordinator.check();
    failRead = false;
    await coordinator.check();
    expect(presentations, 0);
  });

  for (final accept in [false, true]) {
    testWidgets(
      'dialog ${accept ? 'opens exact Play page' : 'dismisses without opening'}',
      (tester) async {
        String? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAndroidReviewPrompt(
                    context,
                    openExternal: (url) async {
                      opened = url;
                    },
                  ),
                  child: const Text('show'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('show'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(accept ? 'Оставить отзыв' : 'Не сейчас'));
        await tester.pumpAndSettle();
        expect(
          opened,
          accept
              ? 'https://play.google.com/store/apps/details?id=com.dropo.myapp'
              : null,
        );
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'dialog fits a small Android screen with large text and Back dismisses',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAndroidReviewPrompt(
                  context,
                  openExternal: (_) async {},
                ),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
