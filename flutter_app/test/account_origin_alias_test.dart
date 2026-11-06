import 'package:flutter_test/flutter_test.dart';
import 'package:dropo/main.dart';

void main() {
  test('only the compiled Dropo origins share account credentials', () {
    expect(accountCredentialOrigin('https://api.droponevedimka.ru'),
        'https://dropo.fun');
    expect(accountCredentialOrigin('https://dropo.fun'), 'https://dropo.fun');
    for (final origin in [
      'https://evil.invalid',
      'https://dropo.fun.evil.invalid',
      'https://api.droponevedimka.ru.evil.invalid',
      'http://api.droponevedimka.ru',
      'https://api.droponevedimka.ru:444',
    ]) {
      expect(accountCredentialOrigin(origin), isNot('https://dropo.fun'));
    }
  });
}
