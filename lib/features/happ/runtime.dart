import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/task_pool.dart';
import 'package:fl_clash/features/happ/subscription.dart';
import 'package:path/path.dart' as paths;

final happRuntime = HappRuntime();

const happGroupName = 'Happ';
const _loopback = '127.0.0.1';

class HappRuntime {
  HappRuntime({String? enginePath})
    : _enginePath = enginePath ?? happEnginePath;

  final String _enginePath;
  final _profiles = <int, _HappProfile>{};
  final _delayPool = TaskPool(10);
  _HappProfile? _active;

  Future<Map<String, dynamic>> prepare(int id, String document) async {
    final previous = _profiles[id];
    if (previous != null && previous.document == document) {
      return previous.configuration();
    }
    if (!await File(_enginePath).exists()) {
      throw const FormatException(
        'The bundled Windows Xray engine is missing.',
      );
    }
    final json = jsonDecode(document) as Map<String, dynamic>;
    final entries = json[happDocumentKey] as Map<String, dynamic>;
    final profile = _HappProfile(document);
    try {
      for (final entry in entries.entries) {
        profile.nodes[entry.key] = await _HappNode.bind(
          entry.value as Map<String, dynamic>,
          _enginePath,
        );
      }
    } catch (_) {
      await profile.close();
      rethrow;
    }
    _profiles[id] = profile;
    if (previous != null) _retired.add(previous);
    return profile.configuration();
  }

  final _retired = <_HappProfile>[];

  Future<void> activate(int? id) async {
    _active = _profiles[id];
    final retired = [
      ..._retired,
      for (final entry in _profiles.entries)
        if (entry.key != id) entry.value,
    ];
    _retired.clear();
    _profiles.removeWhere((key, _) => key != id);
    await Future.wait(retired.map((profile) => profile.close()));
  }

  Future<void> close() => activate(null);

  Future<int>? testDelay(String name, String url, Duration timeout) {
    final node = _active?.nodes[name];
    return node == null
        ? null
        : _delayPool.run(() => node.testDelay(url, timeout));
  }
}

class _HappProfile {
  final String document;
  final nodes = <String, _HappNode>{};

  _HappProfile(this.document);

  Map<String, dynamic> configuration() => {
    'proxies': [
      for (final entry in nodes.entries)
        {
          'name': entry.key,
          'type': 'socks5',
          'server': _loopback,
          'port': entry.value.listener.port,
          'username': entry.value.user,
          'password': entry.value.password,
          'udp': true,
        },
    ],
    'proxy-groups': [
      {'name': happGroupName, 'type': 'select', 'proxies': nodes.keys.toList()},
    ],
    'rules': [happProcessRule, 'MATCH,$happGroupName'],
  };

  Future<void> close() async {
    await Future.wait(nodes.values.map((node) => node.close()));
  }
}

class _HappNode {
  final Map<String, dynamic> config;
  final String enginePath;
  final ServerSocket listener;
  final String user = 'flclash';
  final String password = base64Url.encode(
    List.generate(24, (_) => _random.nextInt(256)),
  );
  final _clients = <Socket>{};
  static final _random = Random.secure();
  Future<_Engine>? _pending;
  _Engine? _running;
  Timer? _idle;
  var _users = 0;
  var _closed = false;
  var _usedForTraffic = false;

  _HappNode(this.config, this.listener, this.enginePath);

  static Future<_HappNode> bind(
    Map<String, dynamic> config,
    String enginePath,
  ) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final node = _HappNode(config, listener, enginePath);
    listener.listen((socket) => unawaited(node._relay(socket)));
    return node;
  }

  Future<_Engine> _engineForConnection() async {
    if (_closed) throw const SocketException('Happ profile closed');
    _idle?.cancel();
    if (_running case final engine?) return engine;
    final pending = _pending ??= _start();
    try {
      return await pending;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<_Engine> _start() async {
    final socks = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final http = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final socksPort = socks.port;
    final httpPort = http.port;
    await socks.close();
    await http.close();
    final child = await Process.start(enginePath, [
      'run',
      '-config',
      'stdin:',
    ], workingDirectory: paths.dirname(enginePath));
    final engine = _Engine(child, socksPort, httpPort);
    unawaited(child.stdout.drain<void>());
    unawaited(child.stderr.drain<void>());
    var exited = false;
    unawaited(
      child.exitCode.then((_) {
        exited = true;
        if (identical(_running, engine)) _running = null;
      }),
    );
    try {
      child.stdin.write(
        jsonEncode({
          ...config,
          'log': {'loglevel': 'none'},
          'inbounds': [
            {
              'tag': 'socks',
              'listen': _loopback,
              'port': socksPort,
              'protocol': 'socks',
              'settings': {
                'auth': 'password',
                'accounts': [
                  {'user': user, 'pass': password},
                ],
                'udp': true,
                'ip': _loopback,
              },
            },
            {
              'tag': 'http',
              'listen': _loopback,
              'port': httpPort,
              'protocol': 'http',
              'settings': {
                'accounts': [
                  {'user': user, 'pass': password},
                ],
              },
            },
          ],
        }),
      );
      await child.stdin.close();
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (!_closed && !exited && DateTime.now().isBefore(deadline)) {
        try {
          final socket = await Socket.connect(
            _loopback,
            socksPort,
            timeout: const Duration(milliseconds: 250),
          );
          socket.destroy();
          if (exited || _closed) break;
          return _running = engine;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      throw const SocketException('Xray could not start');
    } catch (_) {
      child.kill();
      rethrow;
    }
  }

  void _release() {
    _users--;
    if (_closed || _users != 0) return;
    if (_usedForTraffic) {
      _idle = Timer(const Duration(seconds: 20), _stopEngine);
    } else {
      _stopEngine();
    }
  }

  void _stopEngine() {
    _running?.process.kill();
    _running = null;
    _usedForTraffic = false;
  }

  Future<void> _relay(Socket client) async {
    _users++;
    _clients.add(client);
    Socket? server;
    try {
      final engine = await _engineForConnection();
      _usedForTraffic = true;
      final upstream = await Socket.connect(
        _loopback,
        engine.socksPort,
        timeout: const Duration(seconds: 2),
      );
      server = upstream;
      await Future.any([
        client.addStream(upstream),
        upstream.addStream(client),
      ]);
    } catch (_) {
      // Closing the socket lets Mihomo report the failure to its caller.
    } finally {
      server?.destroy();
      client.destroy();
      _clients.remove(client);
      _release();
    }
  }

  Future<int> testDelay(String url, Duration timeout) async {
    _users++;
    final stopwatch = Stopwatch()..start();
    try {
      final engine = await _engineForConnection();
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) return -1;
      return await _probe(engine, Uri.parse(url), remaining);
    } on Exception {
      return -2;
    } finally {
      _release();
    }
  }

  Future<int> _probe(_Engine engine, Uri url, Duration budget) async {
    final result = Completer<int>();
    final clients = <HttpClient>{};
    var started = 0;
    var finished = 0;

    void attempt() {
      if (result.isCompleted || started == 2) return;
      started++;
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY $_loopback:${engine.httpPort}';
      client.authenticateProxy = (host, port, scheme, realm) async {
        client.addProxyCredentials(
          host,
          port,
          realm ?? 'proxy',
          HttpClientBasicCredentials(user, password),
        );
        return true;
      };
      clients.add(client);
      unawaited(() async {
        final stopwatch = Stopwatch()..start();
        try {
          final request = await client.getUrl(url);
          request.followRedirects = false;
          final response = await request.close();
          if (!result.isCompleted &&
              response.statusCode >= 200 &&
              response.statusCode < 400) {
            result.complete(max(1, stopwatch.elapsedMilliseconds));
          }
        } on Exception {
          // A failed connection can retry within the same deadline.
        } finally {
          clients.remove(client);
          client.close(force: true);
          finished++;
          if (!result.isCompleted) {
            if (finished == 2) {
              result.complete(-2);
            } else {
              attempt();
            }
          }
        }
      }());
    }

    final deadline = Timer(budget, () {
      if (!result.isCompleted) result.complete(-1);
    });
    final retry = Timer(
      Duration(microseconds: min(budget.inMicroseconds ~/ 2, 3000000)),
      attempt,
    );
    attempt();
    try {
      return await result.future;
    } finally {
      deadline.cancel();
      retry.cancel();
      for (final client in clients) {
        client.close(force: true);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _idle?.cancel();
    for (final socket in _clients) {
      socket.destroy();
    }
    _running?.process.kill();
    await listener.close();
  }
}

class _Engine {
  final Process process;
  final int socksPort;
  final int httpPort;

  const _Engine(this.process, this.socksPort, this.httpPort);
}
