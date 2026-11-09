import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/task_pool.dart';
import 'package:path/path.dart' as paths;
import 'package:win32_registry/win32_registry.dart';

const happMarker = 'flclash-happ';
const happDocumentKey = 'x-flclash-happ';
const happEngineName = 'FlClashXray.exe';
const happProcessRule = 'PROCESS-NAME,$happEngineName,DIRECT';
const defaultHappUserAgent = 'Happ/4.7.2';
final _validationPool = TaskPool(4);
final _hwidPattern = RegExp(r'^[A-Za-z0-9=-]{10,64}$');
final _userAgentPattern = RegExp(r'^[ -~]{1,256}$');

String get happEnginePath => paths.join(
  paths.dirname(Platform.resolvedExecutable),
  'xray',
  happEngineName,
);

bool isHappSubscription(String url) =>
    Uri.tryParse(url)?.fragment == happMarker;

String happSubscriptionUrl(String url) {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('Happ subscriptions require an HTTPS URL.');
  }
  return uri.replace(fragment: happMarker).toString();
}

bool validHappHwid(String value) =>
    value.isEmpty || _hwidPattern.hasMatch(value);

bool validHappUserAgent(String value) =>
    value.isEmpty || _userAgentPattern.hasMatch(value);

String? happHwidFromScript(String script, String url) {
  final source = RegExp(
    r'''^\s*const\s+SUB_URL\s*=\s*(['"])([^\r\n'"]+)\1\s*;''',
    multiLine: true,
  ).firstMatch(script)?.group(2);
  if (source == null ||
      Uri.tryParse(source)?.removeFragment() !=
          Uri.tryParse(url)?.removeFragment()) {
    return null;
  }
  final hwid = RegExp(
    r'''^\s*const\s+HWID\s*=\s*(['"])([A-Za-z0-9=-]{10,64})\1\s*;''',
    multiLine: true,
  ).firstMatch(script)?.group(2);
  return hwid;
}

Map<String, String> happRequestHeaders({
  required String hwid,
  required String userAgent,
  required String Function() fallbackHwid,
}) {
  if (!validHappHwid(hwid) || !validHappUserAgent(userAgent)) {
    throw const FormatException('Invalid HWID or User-Agent.');
  }
  return {
    HttpHeaders.userAgentHeader: userAgent.isEmpty
        ? defaultHappUserAgent
        : userAgent,
    'X-Hwid': hwid.isEmpty ? fallbackHwid() : hwid,
    'X-Device-Os': 'Windows',
    HttpHeaders.cacheControlHeader: 'no-cache',
  };
}

String _windowsHwid() {
  final key = LOCAL_MACHINE.open(r'SOFTWARE\Microsoft\Cryptography');
  try {
    final guid = key.getString('MachineGuid');
    if (guid == null || guid.isEmpty) {
      throw const FormatException('Windows device ID is unavailable.');
    }
    // Match the Windows HWID already used by FlClashX.
    return sha256
        .convert(utf8.encode('StringValue(MachineGuid, $guid)'))
        .toString()
        .substring(0, 16)
        .toUpperCase();
  } finally {
    key.close();
  }
}

Future<Uint8List> downloadHappSubscription(
  String url, {
  required String Function(Uri) findProxy,
  String hwid = '',
  String userAgent = '',
}) async {
  final uri = Uri.parse(happSubscriptionUrl(url)).removeFragment();
  final headers = happRequestHeaders(
    hwid: hwid,
    userAgent: userAgent,
    fallbackHwid: _windowsHwid,
  );
  final client = HttpClient()
    ..findProxy = findProxy
    ..connectionTimeout = const Duration(seconds: 12)
    ..badCertificateCallback = (_, _, _) => false;
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.headers.value('x-hwid-max-devices-reached') == 'true' ||
          response.headers.value('x-hwid-limit') == 'true' ||
          response.headers.value('x-hwid-not-supported') == 'true') {
        throw const FormatException(
          'Subscription rejected this device (HWID).',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw FormatException(
          'Subscription returned HTTP ${response.statusCode}.',
        );
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        body.add(chunk);
        if (body.length > 8 * 1024 * 1024) {
          throw const FormatException('Happ subscription exceeds 8 MiB.');
        }
      }
      final document = encodeHappDocument(body.takeBytes());
      await validateHappDocument(document);
      return Uint8List.fromList(utf8.encode(document));
    })().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}

String encodeHappDocument(List<int> body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const FormatException('Subscription is not valid Xray JSON.');
  }
  final entries = decoded is List ? decoded : [decoded];
  if (entries.isEmpty || entries.length > 100) {
    throw const FormatException(
      'Happ subscription must contain 1–100 profiles.',
    );
  }
  final names = <String>{};
  final configs = <String, Map<String, dynamic>>{};
  for (final entry in entries) {
    if (entry is! Map<String, dynamic> || entry['outbounds'] is! List) {
      throw const FormatException(
        'Expected an Xray configuration with outbounds.',
      );
    }
    final outbounds = (entry['outbounds'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    const protocols = {'vless', 'freedom', 'blackhole', 'loopback'};
    if (outbounds.length != (entry['outbounds'] as List).length ||
        outbounds.any((node) => !protocols.contains(node['protocol'])) ||
        !outbounds.any((node) => node['protocol'] == 'vless')) {
      throw const FormatException('Unsupported Happ outbound protocol.');
    }
    final label = entry['remarks'];
    final base = label is String && label.trim().isNotEmpty
        ? label.trim()
        : 'Xray ${configs.length + 1}';
    var name = base;
    var duplicate = 2;
    while (!names.add(name) ||
        {'DIRECT', 'REJECT', 'GLOBAL', 'Happ'}.contains(name)) {
      name = '$base (${duplicate++})';
    }
    configs[name] = {
      'outbounds': outbounds,
      for (final key in ['dns', 'routing', 'observatory', 'burstObservatory'])
        if (entry[key] is Map<String, dynamic>) key: entry[key],
    };
    _rejectLocalFiles(configs[name]);
  }
  return jsonEncode({happDocumentKey: configs});
}

void _rejectLocalFiles(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase();
      if (key.endsWith('file') || key == 'masterkeylog' || key == 'keylog') {
        throw const FormatException(
          'Local files are not allowed in Happ subscriptions.',
        );
      }
      _rejectLocalFiles(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _rejectLocalFiles(item);
    }
  } else if (value is String && value.startsWith('ext:')) {
    throw const FormatException(
      'External rule files are not allowed in Happ subscriptions.',
    );
  }
}

Future<void> validateHappDocument(String document) async {
  if (!await File(happEnginePath).exists()) {
    throw const FormatException('The bundled Windows Xray engine is missing.');
  }
  final configs =
      (jsonDecode(document) as Map<String, dynamic>)[happDocumentKey]
          as Map<String, dynamic>;
  await Future.wait(
    configs.values.map(
      (config) => _validationPool.run(() async {
        final process = await Process.start(happEnginePath, [
          'run',
          '-test',
          '-config',
          'stdin:',
        ], workingDirectory: paths.dirname(happEnginePath));
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        try {
          process.stdin.write(jsonEncode(config));
          await process.stdin.close();
          if (await process.exitCode.timeout(const Duration(seconds: 5)) != 0) {
            throw const FormatException(
              'Xray rejected a configuration in the subscription.',
            );
          }
        } finally {
          process.kill();
        }
      }),
    ),
  );
}
