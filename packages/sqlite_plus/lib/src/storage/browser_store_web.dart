import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'browser_byte_store.dart';

/// OPFS when `navigator.storage.getDirectory` works, otherwise IndexedDB.
/// Returns null when neither interface exists. A stored blob is not a
/// power-loss guarantee.
Future<BrowserByteStore?> openPlatformBrowserStore() async {
  final opfs = await _opfs();
  if (opfs != null) return opfs;
  return _indexedDb();
}

Future<BrowserByteStore?> _opfs() async {
  try {
    final navigator = _navigator;
    if (navigator == null) return null;
    final storage = _Navigator(navigator).storage;
    if (storage == null) return null;
    final root = await _StorageManager(storage).getDirectory().toDart;
    return _OpfsStore(_DirectoryHandle(root));
  } catch (_) {
    return null;
  }
}

Future<BrowserByteStore?> _indexedDb() async {
  try {
    final factory = _indexedDB;
    if (factory == null) return null;
    final database = await _openIndexedDatabase(_IDBFactory(factory));
    return _IndexedDbStore(database);
  } catch (_) {
    return null;
  }
}

@JS('globalThis.navigator')
external JSObject? get _navigator;

@JS('globalThis.indexedDB')
external JSObject? get _indexedDB;

extension type _Navigator(JSObject _) implements JSObject {
  external JSObject? get storage;
}

extension type _StorageManager(JSObject _) implements JSObject {
  external JSPromise<JSObject> getDirectory();
}

extension type _FileOptions._(JSObject _) implements JSObject {
  external factory _FileOptions({bool create});
}

extension type _DirectoryHandle(JSObject _) implements JSObject {
  external JSPromise<JSObject> getFileHandle(String name, _FileOptions options);
}

extension type _FileHandle(JSObject _) implements JSObject {
  external JSPromise<JSObject> getFile();
  external JSPromise<JSObject> createWritable();
}

extension type _Blob(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _Writer(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array data);
  external JSPromise<JSAny?> close();
}

final class _OpfsStore implements BrowserByteStore {
  _OpfsStore(this._root);
  final _DirectoryHandle _root;

  Future<_FileHandle> _handle(String name) async => _FileHandle(
      await _root.getFileHandle(name, _FileOptions(create: true)).toDart);

  @override
  Future<Uint8List?> read(String name) async {
    final handle = await _handle(name);
    final file = _Blob(await handle.getFile().toDart);
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final handle = await _handle(name);
    final writer = _Writer(await handle.createWritable().toDart);
    await writer.write(bytes.toJS).toDart;
    await writer.close().toDart;
  }
}

extension type _IDBFactory(JSObject _) implements JSObject {
  external JSObject open(String name, int version);
}

extension type _IDBRequest(JSObject _) implements JSObject {
  external set onsuccess(JSFunction value);
  external set onerror(JSFunction value);
  external set onupgradeneeded(JSFunction value);
  external JSAny? get result;
}

extension type _DOMStringList(JSObject _) implements JSObject {
  external bool contains(String name);
}

extension type _IDBDatabase(JSObject _) implements JSObject {
  external _DOMStringList get objectStoreNames;
  external JSObject createObjectStore(String name);
  external JSObject transaction(String store, String mode);
}

extension type _IDBTransaction(JSObject _) implements JSObject {
  external JSObject objectStore(String name);
}

extension type _IDBObjectStore(JSObject _) implements JSObject {
  external JSObject put(JSAny value, String key);
  external JSObject get(String key);
}

Future<JSAny?> _awaitRequest(JSObject request) {
  final completer = Completer<JSAny?>();
  final viewed = _IDBRequest(request);
  viewed.onsuccess = ((JSAny? _) {
    if (!completer.isCompleted) completer.complete(viewed.result);
  }).toJS;
  viewed.onerror = ((JSAny? _) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB request failed'));
    }
  }).toJS;
  return completer.future;
}

Future<_IDBDatabase> _openIndexedDatabase(_IDBFactory factory) async {
  final request = _IDBRequest(factory.open('sqlite_plus', 1));
  request.onupgradeneeded = ((JSAny? _) {
    final database = _IDBDatabase(request.result as JSObject);
    if (!database.objectStoreNames.contains('files')) {
      database.createObjectStore('files');
    }
  }).toJS;
  final opened = await _awaitRequest(request as JSObject);
  return _IDBDatabase(opened! as JSObject);
}

final class _IndexedDbStore implements BrowserByteStore {
  _IndexedDbStore(this._database);
  final _IDBDatabase _database;

  _IDBObjectStore _store(String mode) =>
      _IDBObjectStore(_IDBTransaction(_database.transaction('files', mode))
          .objectStore('files'));

  @override
  Future<Uint8List?> read(String name) async {
    final result = await _awaitRequest(_store('readonly').get(name));
    if (result == null) return null;
    if (result.isA<JSUint8Array>()) return (result as JSUint8Array).toDart;
    if (result.isA<JSArrayBuffer>()) {
      return (result as JSArrayBuffer).toDart.asUint8List();
    }
    throw StateError('IndexedDB value is not bytes');
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    await _awaitRequest(_store('readwrite').put(bytes.toJS, name));
  }
}
