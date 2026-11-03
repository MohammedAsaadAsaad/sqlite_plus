import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../btree/database_image_builder.dart';
import '../format/database_header.dart';
import '../sql/mutable_database.dart';

/// SQLCipher 4 defaults: AES-256-CBC, HMAC-SHA512, and PBKDF2-HMAC-SHA512.
///
/// A 4096-byte page keeps 80 bytes at the end (16-byte IV, then 64-byte HMAC).
/// Page 1 stores a 16-byte salt where the SQLite magic would be. The salt is
/// not encrypted. AES covers the bytes before the reserve, with no padding.
/// HMAC-SHA512 covers that ciphertext, the IV, and the 1-based page number in
/// little-endian. The HMAC key is PBKDF2 of the encryption key over the salt
/// with each byte XOR 0x3a, for 2 iterations.
///
/// [iterations] is not stored in the file. A file opens only when both sides
/// use the same count. The default, 256000, matches SQLCipher 4. Derivation
/// runs when a database is created or opened. Later encrypted exports reuse
/// the derived keys.
///
/// WAL, SQLCipher 1–3, plaintext headers, rekey, and auto-vacuum combined with
/// the reserve are outside this codec. An unencrypted database never calls it.
abstract final class SqlCipher {
  static const iterations = 256000;
  static const fastIterations = 2;
  static const reservedBytes = 80;
  static const saltBytes = 16;
  static const keyBytes = 32;
  static const ivBytes = 16;
  static const hmacBytes = 64;
  static const _hmacSaltMask = 0x3a;

  static const _magic = <int>[
    83,
    81,
    76,
    105,
    116,
    101,
    32,
    102,
    111,
    114,
    109,
    97,
    116,
    32,
    51,
    0
  ];

  /// Derives the SQLCipher 4 keys for [passphrase] and [salt].
  ///
  /// A passphrase shaped as `x'hex'` uses the raw key, raw key plus salt, or
  /// raw key plus HMAC key plus salt when the hex length is 64, 96, or 160.
  /// Any other string is UTF-8 input to PBKDF2. An embedded salt replaces
  /// [salt].
  static SqlCipherKeys derive(String passphrase, Uint8List salt,
      {int iterations = iterations}) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations');
    }
    if (salt.length != saltBytes) {
      throw ArgumentError.value(salt.length, 'salt');
    }
    final raw = _rawMaterial(passphrase);
    if (raw == null && passphrase.isEmpty) {
      throw ArgumentError('SQLCipher key is empty');
    }
    final fileSalt = Uint8List.fromList(raw?.salt ?? salt);
    final encryption = Uint8List(keyBytes);
    final hmacKey = Uint8List(keyBytes);
    if (raw == null) {
      encryption.setRange(
          0,
          keyBytes,
          _pbkdf2(Uint8List.fromList(utf8.encode(passphrase)), fileSalt,
              iterations, keyBytes));
    } else {
      encryption.setRange(0, keyBytes, raw.key);
      if (raw.hmacKey != null) hmacKey.setRange(0, keyBytes, raw.hmacKey!);
    }
    if (raw?.hmacKey == null) {
      final masked = Uint8List(saltBytes);
      for (var i = 0; i < saltBytes; i++) {
        masked[i] = fileSalt[i] ^ _hmacSaltMask;
      }
      hmacKey.setRange(
          0, keyBytes, _pbkdf2(encryption, masked, fastIterations, keyBytes));
    }
    return SqlCipherKeys._(fileSalt, encryption, hmacKey);
  }

  /// Encrypts a plaintext SQLite image whose reserve byte is 80.
  ///
  /// [salt] is stored in the first 16 bytes. Omit it to draw a new salt. A
  /// raw passphrase that already carries a salt uses that salt.
  static Uint8List encrypt(Uint8List image, String passphrase,
      {Uint8List? salt, int iterations = iterations, Random? random}) {
    final chosen = salt ?? _randomBytes(saltBytes, random ?? Random.secure());
    final keys = derive(passphrase, chosen, iterations: iterations);
    return encryptKeys(image, keys, random: random);
  }

  /// Encrypts [image] with keys already derived for its salt.
  static Uint8List encryptKeys(Uint8List image, SqlCipherKeys keys,
      {Random? random}) {
    final header = _plaintextHeader(image);
    final pageSize = header.pageSize;
    final output = Uint8List.fromList(image);
    output.setRange(0, saltBytes, keys.salt);
    final source = random ?? Random.secure();
    final pages = output.length ~/ pageSize;
    for (var page = 1; page <= pages; page++) {
      _cryptPage(output, page, pageSize, keys, encrypt: true, random: source);
    }
    return output;
  }

  /// Decrypts a SQLCipher 4 file. The first 16 bytes are the salt.
  ///
  /// [pageSize] cannot be read before decryption. SQLCipher 4's default is
  /// 4096. A wrong passphrase, a changed byte, or a page moved to another
  /// number fails authentication and does not return a database image.
  static Uint8List decrypt(Uint8List file, String passphrase,
      {int iterations = iterations, int pageSize = 4096}) {
    _requireFile(file, pageSize);
    final keys = derive(passphrase, Uint8List.sublistView(file, 0, saltBytes),
        iterations: iterations);
    return decryptKeys(file, keys, pageSize: pageSize);
  }

  /// Decrypts [file] with keys derived from its salt.
  static Uint8List decryptKeys(Uint8List file, SqlCipherKeys keys,
      {int pageSize = 4096}) {
    _requireFile(file, pageSize);
    final output = Uint8List.fromList(file);
    final pages = output.length ~/ pageSize;
    for (var page = 1; page <= pages; page++) {
      _cryptPage(output, page, pageSize, keys, encrypt: false);
    }
    return output;
  }

  static DatabaseHeader _plaintextHeader(Uint8List image) {
    final header = DatabaseHeader.decode(image);
    if (header.reservedBytes != reservedBytes) {
      throw ArgumentError('SQLCipher reserve is 80 bytes');
    }
    if (header.writeVersion != 1 || header.readVersion != 1) {
      throw UnsupportedError('SQLCipher WAL images are unsupported');
    }
    header.validateFileLength(image.length);
    return header;
  }

  static void _requireFile(Uint8List file, int pageSize) {
    if (pageSize < 1024 ||
        pageSize > 65536 ||
        pageSize & (pageSize - 1) != 0 ||
        pageSize - reservedBytes < 480) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    if (file.length < pageSize || file.length % pageSize != 0) {
      throw const FormatException(
          'SQLCipher file length is not a multiple of the page size');
    }
  }

  static void _cryptPage(
      Uint8List file, int pageNumber, int pageSize, SqlCipherKeys keys,
      {required bool encrypt, Random? random}) {
    final start = (pageNumber - 1) * pageSize;
    final usable = pageSize - reservedBytes;
    final offset = pageNumber == 1 ? saltBytes : 0;
    final size = usable - offset;
    final ivAt = start + usable;
    if (encrypt) {
      for (var i = 0; i < reservedBytes; i++) {
        file[ivAt + i] = random!.nextInt(256);
      }
    }
    final iv = Uint8List.sublistView(file, ivAt, ivAt + ivBytes);
    if (!encrypt) {
      final expected = _pageHmac(
          keys.hmacKey, file, start + offset, size + ivBytes, pageNumber);
      final stored =
          Uint8List.sublistView(file, ivAt + ivBytes, ivAt + reservedBytes);
      if (!_equal(expected, stored)) {
        throw FormatException(
            'SQLCipher page authentication failed: $pageNumber');
      }
    }
    _aes(encrypt, keys.encryptionKey, iv, file, start + offset, size);
    if (encrypt) {
      final mac = _pageHmac(
          keys.hmacKey, file, start + offset, size + ivBytes, pageNumber);
      file.setRange(ivAt + ivBytes, ivAt + reservedBytes, mac);
    } else if (pageNumber == 1) {
      file.setRange(0, saltBytes, _magic);
    }
  }

  static void _aes(bool encrypt, Uint8List key, Uint8List iv, Uint8List data,
      int offset, int length) {
    final cipher = CBCBlockCipher(AESEngine());
    cipher.init(encrypt, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(length);
    var index = 0;
    while (index < length) {
      index += cipher.processBlock(data, offset + index, output, index);
    }
    data.setRange(offset, offset + length, output);
  }

  static Uint8List _pageHmac(
      Uint8List key, Uint8List data, int offset, int length, int pageNumber) {
    final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(key));
    hmac.update(data, offset, length);
    final page = Uint8List(4);
    ByteData.sublistView(page).setUint32(0, pageNumber, Endian.little);
    hmac.update(page, 0, 4);
    final mac = Uint8List(hmacBytes);
    hmac.doFinal(mac, 0);
    return mac;
  }

  static Uint8List _pbkdf2(
      Uint8List password, Uint8List salt, int iterations, int length) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))
      ..init(Pbkdf2Parameters(salt, iterations, length));
    return derivator.process(password);
  }

  static _RawKey? _rawMaterial(String passphrase) {
    final match = RegExp(r"^[xX]'([0-9a-fA-F]+)'$").firstMatch(passphrase);
    if (match == null) return null;
    final hex = match.group(1)!;
    if (hex.length != 64 && hex.length != 96 && hex.length != 160) return null;
    final bytes = _hex(hex);
    if (hex.length == 64) {
      return _RawKey(Uint8List.sublistView(bytes, 0, keyBytes), null, null);
    }
    if (hex.length == 96) {
      return _RawKey(Uint8List.sublistView(bytes, 0, keyBytes), null,
          Uint8List.sublistView(bytes, keyBytes, keyBytes + saltBytes));
    }
    return _RawKey(
        Uint8List.sublistView(bytes, 0, keyBytes),
        Uint8List.sublistView(bytes, keyBytes, keyBytes * 2),
        Uint8List.sublistView(bytes, keyBytes * 2));
  }

  static Uint8List _hex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static Uint8List _randomBytes(int length, Random random) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

final class _RawKey {
  _RawKey(this.key, this.hmacKey, this.salt);
  final Uint8List key;
  final Uint8List? hmacKey;
  final Uint8List? salt;
}

/// Encryption key, HMAC key, and the 16-byte salt stored in the file.
final class SqlCipherKeys {
  SqlCipherKeys._(this.salt, this.encryptionKey, this.hmacKey);
  final Uint8List salt;
  final Uint8List encryptionKey;
  final Uint8List hmacKey;
}

/// A plaintext [MutableSqliteDatabase] whose file image is SQLCipher 4.
///
/// [database.exportImage] is the decrypted SQLite image, including the 80-byte
/// reserve. [encryptedImage] is the file a SQLCipher 4 library opens with the
/// same passphrase and KDF count. Writes stay in the plaintext image until the
/// next [encryptedImage] call. That call does not run PBKDF2 again.
final class SqlCipherDatabase {
  SqlCipherDatabase._(this.database, this._keys, this.iterations);
  final MutableSqliteDatabase database;
  final SqlCipherKeys _keys;
  final int iterations;

  /// Salt stored in the first 16 bytes of [encryptedImage].
  Uint8List get salt => Uint8List.fromList(_keys.salt);

  /// Creates an empty SQLCipher database.
  ///
  /// The plaintext header reserve is 80. Auto-vacuum stays off because the
  /// page image already exists. [pageSize] is a power of two from 1024 to
  /// 65536.
  static Future<SqlCipherDatabase> create(String passphrase,
      {int iterations = SqlCipher.iterations,
      int pageSize = 4096,
      int encoding = 1,
      Uint8List? salt,
      Random? random}) async {
    final source = random ?? Random.secure();
    final chosen = salt ?? SqlCipher._randomBytes(SqlCipher.saltBytes, source);
    final keys = SqlCipher.derive(passphrase, chosen, iterations: iterations);
    final image = DatabaseImageBuilder.empty(
        pageSize: pageSize,
        encoding: encoding,
        reservedBytes: SqlCipher.reservedBytes);
    return SqlCipherDatabase._(
        await MutableSqliteDatabase.fromImage(image), keys, iterations);
  }

  /// Opens a SQLCipher 4 file image.
  static Future<SqlCipherDatabase> open(Uint8List file, String passphrase,
      {int iterations = SqlCipher.iterations, int pageSize = 4096}) async {
    SqlCipher._requireFile(file, pageSize);
    final salt =
        Uint8List.fromList(Uint8List.sublistView(file, 0, SqlCipher.saltBytes));
    final keys = SqlCipher.derive(passphrase, salt, iterations: iterations);
    final plain = SqlCipher.decryptKeys(file, keys, pageSize: pageSize);
    final header = DatabaseHeader.decode(plain);
    if (header.writeVersion != 1 || header.readVersion != 1) {
      throw UnsupportedError('SQLCipher WAL images are unsupported');
    }
    if (header.reservedBytes != SqlCipher.reservedBytes) {
      throw const FormatException('SQLCipher reserve is 80 bytes');
    }
    if (header.largestRootPage != 0) {
      throw UnsupportedError(
          'Reserved-byte auto-vacuum image rebuild is unsupported');
    }
    return SqlCipherDatabase._(
        await MutableSqliteDatabase.fromImage(plain), keys, iterations);
  }

  /// Encrypts the current plaintext image with the salt from [open] or [create].
  Uint8List encryptedImage({Random? random}) =>
      SqlCipher.encryptKeys(database.exportImage(), _keys, random: random);
}
