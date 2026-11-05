import 'dart:io';
import 'dart:isolate';

import 'catalog_work.dart';

/// Owns the database on a background isolate so the interface stays responsive.
class CatalogWorkerClient {
  Isolate? _isolate;
  SendPort? _commands;
  final _events = ReceivePort();
  void Function(int done, int total, int rss)? onProgress;

  Future<void> start() async {
    if (_commands != null) return;
    final ready = ReceivePort();
    _isolate = await Isolate.spawn(catalogWorker, ready.sendPort);
    _commands = await ready.first as SendPort;
    ready.close();
    _events.listen((message) {
      final event = message as Map;
      if (event['progress'] == true) {
        onProgress?.call(
          event['done'] as int,
          event['total'] as int,
          event['rss'] as int,
        );
      }
    });
  }

  Future<Map<String, Object?>> call(Map<String, Object?> command) async {
    final commands = _commands;
    if (commands == null) {
      throw StateError('The catalog worker is not running');
    }
    final reply = ReceivePort();
    commands.send({
      ...command,
      'reply': reply.sendPort,
      'events': _events.sendPort,
    });
    final response = await reply.first as Map;
    reply.close();
    if (response['ok'] != true) {
      throw StateError('${response['error']}');
    }
    return response.cast<String, Object?>();
  }

  Future<void> close() async {
    if (_commands != null) {
      try {
        await call({'op': 'close'});
      } catch (_) {
        // The isolate is about to stop.
      }
    }
    _commands = null;
    _events.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

void catalogWorker(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  final holder = _SessionHolder();
  var chain = Future<void>.value();
  inbox.listen((message) {
    chain = chain.then((_) => _handle(holder, message));
  });
}

final class _SessionHolder {
  CatalogSession session = CatalogSession();
}

Future<void> _handle(_SessionHolder holder, Object? message) async {
  final request = message as Map;
  final reply = request['reply'] as SendPort;
  final events = request['events'] as SendPort;
  try {
    switch (request['op']) {
      case 'reset':
        await holder.session.close();
        holder.session = CatalogSession();
        reply.send({'ok': true});
      case 'insert':
        final rows = request['rows'] as List;
        final products = [
          for (final row in rows)
            ProductLine(
              language: (row as List)[0] as String,
              sourceLine: (row[1] as num).toInt(),
              name: row[2] as String,
            ),
        ];
        final count = await holder.session.insertChunk(products);
        reply.send({
          'ok': true,
          'count': count,
          'rss': ProcessInfo.currentRss,
          'peak': ProcessInfo.maxRss,
        });
      case 'open':
        final path = request['path'] as String;
        final file = File(path);
        if (!file.existsSync() || file.lengthSync() == 0) {
          reply.send({'ok': true, 'found': false});
          break;
        }
        try {
          final bytes = await file.readAsBytes();
          await holder.session.close();
          holder.session = CatalogSession();
          await holder.session.openImage(bytes);
          reply.send({
            'ok': true,
            'found': true,
            'indexed': holder.session.indexed,
            'count': holder.session.productCount,
            'sample': _sample(holder.session),
          });
        } catch (error) {
          await holder.session.close();
          holder.session = CatalogSession();
          reply.send({'ok': true, 'found': false, 'error': error.toString()});
        }
      case 'save':
        final path = request['path'] as String;
        final bytes = holder.session.exportImage();
        final file = File(path);
        await file.parent.create(recursive: true);
        final temporary = File('$path.saving');
        await temporary.writeAsBytes(bytes, flush: true);
        if (file.existsSync()) await file.delete();
        await temporary.rename(file.path);
        reply.send({'ok': true, 'image': bytes.length});
      case 'index':
        await holder.session.buildIndex(
          rebuild: request['rebuild'] == true,
          onProgress: (done, total) {
            events.send({
              'progress': true,
              'done': done,
              'total': total,
              'rss': ProcessInfo.currentRss,
            });
          },
        );
        reply.send({'ok': true, 'sample': _sample(holder.session)});
      case 'search':
        final run = await holder.session.searchProducts(
          request['query'] as String,
          scope: SearchScope.values.byName(request['scope'] as String),
          limit: request['limit'] as int? ?? catalogResultLimit,
          offset: request['offset'] as int? ?? 0,
        );
        reply.send({
          'ok': true,
          'total': run.total,
          'searchUs': run.searchElapsed.inMicroseconds,
          'lookupUs': run.lookupElapsed.inMicroseconds,
          'matches': [
            for (final match in run.matches)
              {
                'rank': match.rank,
                'language': match.language,
                'line': match.sourceLine,
                'name': match.name,
                'score': match.score,
              },
          ],
          'rss': ProcessInfo.currentRss,
          'peak': ProcessInfo.maxRss,
        });
      case 'sample':
        reply.send({'ok': true, 'sample': _sample(holder.session)});
      case 'close':
        await holder.session.close();
        reply.send({'ok': true});
      default:
        reply.send({'ok': false, 'error': 'Unknown catalog operation'});
    }
  } catch (error) {
    reply.send({'ok': false, 'error': error.toString()});
  }
}

Map<String, Object> _sample(CatalogSession session) {
  return {
    'rss': ProcessInfo.currentRss,
    'peak': ProcessInfo.maxRss,
    'image': session.database?.exportImage().length ?? 0,
  };
}
