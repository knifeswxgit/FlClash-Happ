import 'dart:convert';

import 'package:fl_clash/features/happ/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> example() => {
    'remarks': 'Example',
    'inbounds': [
      {'listen': '0.0.0.0'},
    ],
    'api': {'tag': 'api'},
    'outbounds': [
      {
        'protocol': 'vless',
        'tag': 'relay',
        'streamSettings': {
          'finalmask': {
            'tcp': [
              {'type': 'fragment'},
            ],
          },
        },
      },
    ],
    'routing': {
      'balancers': [
        {
          'tag': 'AUTO',
          'selector': ['relay'],
        },
      ],
    },
  };

  test(
    'marks an HTTPS subscription without exposing the marker to its server',
    () {
      const url = 'https://example.test/sub?id=1';
      final marked = happSubscriptionUrl(url);
      expect(isHappSubscription(marked), isTrue);
      expect(Uri.parse(marked).removeFragment().toString(), url);
      expect(
        () => happSubscriptionUrl('http://example.test'),
        throwsFormatException,
      );
    },
  );

  test(
    'keeps Xray transports and routing and replaces downloaded listeners',
    () {
      final entry = example();
      final data =
          jsonDecode(
                encodeHappDocument(utf8.encode(jsonEncode([entry, entry]))),
              )
              as Map<String, dynamic>;
      final cards = data[happDocumentKey] as Map<String, dynamic>;
      expect(cards.keys, ['Example', 'Example (2)']);
      expect(cards['Example'], {
        'outbounds': entry['outbounds'],
        'routing': entry['routing'],
      });
    },
  );

  test('rejects empty responses and external file references', () {
    expect(() => encodeHappDocument(utf8.encode('[]')), throwsFormatException);
    final entry = example()
      ..['routing'] = {
        'rules': [
          {
            'domain': ['ext:private.dat:private'],
          },
        ],
      };
    expect(
      () => encodeHappDocument(utf8.encode(jsonEncode(entry))),
      throwsFormatException,
    );
  });

  test('reuses the scripted HWID only for the same subscription', () {
    const script = '''
const SUB_URL = "https://example.test/sub";
const HWID = 'test-device-123';
''';
    expect(
      happHwidFromScript(
        script,
        happSubscriptionUrl('https://example.test/sub'),
      ),
      'test-device-123',
    );
    expect(happHwidFromScript(script, 'https://example.test/other'), isNull);
    expect(happHwidFromScript(script, 'https://other.test/sub'), isNull);
  });

  test('uses manual request headers and rejects injected line breaks', () {
    final manual = happRequestHeaders(
      hwid: 'test-device-123',
      userAgent: 'Custom Xray/1',
      fallbackHwid: () => throw StateError('manual HWID was ignored'),
    );
    expect(manual['X-Hwid'], 'test-device-123');
    expect(manual['user-agent'], 'Custom Xray/1');
    final defaults = happRequestHeaders(
      hwid: '',
      userAgent: '',
      fallbackHwid: () => 'automatic-123',
    );
    expect(defaults['X-Hwid'], 'automatic-123');
    expect(defaults['user-agent'], defaultHappUserAgent);
    expect(validHappUserAgent('Agent\r\nX-Hwid: other'), isFalse);
    expect(validHappHwid('too-short'), isFalse);
  });
}
