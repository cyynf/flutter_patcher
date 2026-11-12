import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../core.dart';

void assetKey(String key) {
  require(
    key.isNotEmpty &&
        !key.contains('\\') &&
        !key.contains(':') &&
        !key.contains('\u0000') &&
        !key.startsWith('/') &&
        key.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..'),
    'PATCH_ASSET_INVALID',
    'Unsafe asset key: $key',
  );
}

/// Flutter AssetManifest.bin uses StandardMessageCodec. Only its data types
/// are accepted, with bounded lengths, nesting, exact EOF and duplicate checks.
class AssetCodec {
  AssetCodec(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  late final ByteData data = ByteData.sublistView(bytes);
  void need(int count) {
    require(
      count >= 0 && offset + count <= bytes.length,
      'PATCH_ASSET_INVALID',
      'Truncated asset manifest',
    );
  }

  int byte() {
    need(1);
    return bytes[offset++];
  }

  int size() {
    final n = byte();
    if (n < 254) return n;
    need(n == 254 ? 2 : 4);
    final value = n == 254
        ? data.getUint16(offset, Endian.host)
        : data.getUint32(offset, Endian.host);
    offset += n == 254 ? 2 : 4;
    require(
      value <= 65536,
      'PATCH_ASSET_INVALID',
      'Asset manifest collection too large',
    );
    return value;
  }

  Object? read([int depth = 0]) {
    require(
      depth < 16,
      'PATCH_ASSET_INVALID',
      'Asset manifest nesting too deep',
    );
    switch (byte()) {
      case 0:
        return null;
      case 3:
        need(4);
        final n = data.getInt32(offset, Endian.host);
        offset += 4;
        return n;
      case 6:
        offset = (offset + 7) & ~7;
        need(8);
        final n = data.getFloat64(offset, Endian.host);
        offset += 8;
        return n;
      case 7:
        final n = size();
        need(n);
        final s = utf8.decode(bytes.sublist(offset, offset + n));
        offset += n;
        return s;
      case 12:
        return List.generate(size(), (_) => read(depth + 1));
      case 13:
        final result = <String, Object?>{}, n = size();
        for (var i = 0; i < n; i++) {
          final key = read(depth + 1);
          require(
            key is String && !result.containsKey(key),
            'PATCH_ASSET_INVALID',
            'Duplicate/invalid manifest key',
          );
          result[key as String] = read(depth + 1);
        }
        return result;
      default:
        throw Failure(
          'PATCH_ASSET_INVALID',
          'Unsupported asset manifest value',
        );
    }
  }

  static Map<String, dynamic> decode(List<int> bytes) {
    final reader = AssetCodec(Uint8List.fromList(bytes)),
        result = reader.read();
    require(
      result is Map && reader.offset == bytes.length,
      'PATCH_ASSET_INVALID',
      'Invalid asset manifest',
    );
    return Map<String, dynamic>.from(result as Map);
  }

  static List<int> encode(Object? value) {
    final out = <int>[];
    void size(int n) {
      require(
        n <= 65536,
        'PATCH_ASSET_INVALID',
        'Asset manifest collection too large',
      );
      if (n < 254) {
        out.add(n);
      } else {
        final b = ByteData(n <= 65535 ? 2 : 4);
        if (n <= 65535) {
          b.setUint16(0, n, Endian.host);
          out.add(254);
        } else {
          b.setUint32(0, n, Endian.host);
          out.add(255);
        }
        out.addAll(b.buffer.asUint8List());
      }
    }

    void write(Object? v) {
      if (v == null) {
        out.add(0);
      } else if (v is String) {
        final s = utf8.encode(v);
        out.add(7);
        size(s.length);
        out.addAll(s);
      } else if (v is int) {
        out.add(3);
        final b = ByteData(4)..setInt32(0, v, Endian.host);
        out.addAll(b.buffer.asUint8List());
      } else if (v is double) {
        out.add(6);
        while (out.length % 8 != 0) {
          out.add(0);
        }
        final b = ByteData(8)..setFloat64(0, v, Endian.host);
        out.addAll(b.buffer.asUint8List());
      } else if (v is List) {
        out.add(12);
        size(v.length);
        for (final x in v) {
          write(x);
        }
      } else if (v is Map) {
        out.add(13);
        size(v.length);
        for (final k in v.keys.toList()..sort()) {
          write(k);
          write(v[k]);
        }
      } else {
        throw Failure('PATCH_ASSET_INVALID', 'Unsupported manifest value');
      }
    }

    write(value);
    return out;
  }
}

Map<String, dynamic> resourceReceipt(Archive archive) {
  final files = <String, dynamic>{};
  Map<String, dynamic> manifest = {};
  List? fonts;
  for (final f in archive) {
    if (!f.isFile || !f.name.startsWith('assets/flutter_assets/')) continue;
    final key = f.name.substring('assets/flutter_assets/'.length);
    assetKey(key);
    final raw = f.content as List<int>;
    require(
      !files.containsKey(key),
      'PATCH_ASSET_INVALID',
      'Duplicate APK asset',
    );
    // NOTICES.Z is gzip, whose header records the building OS (zlib OS_CODE):
    // identify it by the license text, so hosts agree.
    final bytes = key == 'NOTICES.Z' ? gzip.decode(raw) : raw;
    files[key] = {
      'sha256': sha256.convert(bytes).toString(),
      'length': bytes.length,
    };
    if (key == 'AssetManifest.bin') manifest = AssetCodec.decode(bytes);
    if (key == 'FontManifest.json') {
      fonts = jsonDecode(utf8.decode(bytes)) as List;
    }
  }
  return {'schema': 1, 'files': files, 'manifest': manifest, 'fonts': ?fonts};
}
