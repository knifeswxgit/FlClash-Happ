import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/features/happ/runtime.dart';
import 'package:fl_clash/features/happ/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final executable = File('windows/xray/$happEngineName').absolute;

  test('uses Xray for GET and authenticated SOCKS traffic', () async {
    final local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var gets = 0;
    var retries = 0;
    var stalled = 0;
    local.listen((request) async {
      if (request.method == 'GET') gets++;
      if (request.uri.path == '/retry' && ++retries == 1) return;
      if (request.uri.path == '/stall') {
        stalled++;
        return;
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    addTearDown(() => local.close(force: true));
    final runtime = HappRuntime(enginePath: executable.path);
    addTearDown(runtime.close);
    final config = await runtime.prepare(
      1,
      jsonEncode({
        happDocumentKey: {
          'Local': {
            'outbounds': [
              {'protocol': 'freedom', 'tag': 'direct'},
            ],
          },
        },
      }),
    );
    await runtime.activate(1);
    final url = 'http://127.0.0.1:${local.port}/';
    final delay = await runtime.testDelay(
      'Local',
      url,
      const Duration(seconds: 5),
    );
    expect(delay, greaterThan(0));
    expect(gets, 1);

    expect(
      await runtime.testDelay(
        'Local',
        '${url}retry',
        const Duration(seconds: 3),
      ),
      greaterThan(0),
    );
    expect(retries, 2);
    final stopwatch = Stopwatch()..start();
    expect(
      await runtime.testDelay(
        'Local',
        '${url}stall',
        const Duration(seconds: 3),
      ),
      -1,
    );
    expect(stalled, 2);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));

    final proxy = (config['proxies'] as List).single as Map;
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy['port'] as int,
    );
    addTearDown(client.destroy);
    final reader = _SocketReader(client);
    addTearDown(reader.stream.cancel);
    client.add([5, 1, 2]);
    expect(await reader.read(2), [5, 2]);
    final user = utf8.encode(proxy['username'] as String);
    final password = utf8.encode(proxy['password'] as String);
    client.add([1, user.length, ...user, password.length, ...password]);
    expect(await reader.read(2), [1, 0]);
    client.add([5, 1, 0, 1, 127, 0, 0, 1, local.port >> 8, local.port & 255]);
    final response = await reader.read(4);
    expect(response.take(2), [5, 0]);
    await reader.read(response[3] == 4 ? 18 : 6);
    client.write(
      'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
    );
    expect(ascii.decode(await reader.read(12)), 'HTTP/1.1 204');
  }, skip: !Platform.isWindows || !executable.existsSync());
}

class _SocketReader {
  _SocketReader(Socket socket) : stream = StreamIterator(socket);

  final StreamIterator<Uint8List> stream;
  List<int> _buffer = [];

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (!await stream.moveNext()) throw StateError('Socket closed');
      _buffer.addAll(stream.current);
    }
    final bytes = _buffer.sublist(0, count);
    _buffer = _buffer.sublist(count);
    return bytes;
  }
}
