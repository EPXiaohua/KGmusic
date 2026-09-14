import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 音频格式展示工具：源文件编码名、文件头位深解析、Media3 编码常量与格式化。
///
/// 供 USB 独占格式链（源文件/播放流/DAC 端点）与歌曲信息页共用，保证两处展示一致。
class AudioFormatUtils {
  AudioFormatUtils._();

  /// Media3 编码常量 → 位深（bit）。
  static int encodingBits(int encoding) {
    switch (encoding) {
      case 4: // C.ENCODING_PCM_FLOAT
        return 32;
      case 2: // C.ENCODING_PCM_16BIT
        return 16;
      case 0x15: // C.ENCODING_PCM_24BIT
        return 24;
      case 0x16: // C.ENCODING_PCM_32BIT
        return 32;
      default:
        return 16;
    }
  }

  /// 采样率格式化：48000 → "48 kHz"，44100 → "44.1 kHz"；<=0 返回 "—"。
  static String formatRate(int rate) {
    if (rate <= 0) return '—';
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  /// 声道数格式化：1 → "1 ch"，2 → "2 ch"，与参考图风格一致；<=0 返回 "—"。
  static String formatCh(int ch) {
    if (ch <= 0) return '—';
    return '$ch ch';
  }

  /// 位深格式化：24 → "24-bit"；<=0 返回 "—"。
  static String formatBits(int bits) {
    if (bits <= 0) return '—';
    return '$bits-bit';
  }

  /// 有损编码集合（此类格式源文件行不展示位深，位深概念仅存在于解码后 PCM）。
  static const Set<String> lossyCodecs = {'MP3', 'AAC', 'OPUS', 'OGG', 'AMR'};

  /// sampleMimeType（Media3）→ 编码短名（FLAC/MP3/AAC/…）。无法识别返回 null。
  /// [codecs] 为 Format.codecs 字符串，用于 OGG 容器内区分 Opus/Vorbis。
  static String? codecLabelFromMime(String? mime, {String? codecs}) {
    if (mime == null || mime.isEmpty) return null;
    final m = mime.toLowerCase();
    final cs = (codecs ?? '').toLowerCase();
    if (m.contains('flac')) return 'FLAC';
    if (m.contains('mpeg') || m.contains('mp3')) return 'MP3';
    if (m.contains('mp4a') || m.contains('aac')) return 'AAC';
    if (m.contains('opus')) return 'OPUS';
    if (m.contains('vorbis') || m == 'audio/ogg' || m.contains('application/ogg')) {
      return cs.contains('opus') ? 'OPUS' : 'OGG';
    }
    if (m.contains('alac')) return 'ALAC';
    if (m.contains('ape') || m.contains('monkey')) return 'APE';
    if (m.contains('wav') || m.contains('wave') || m.contains('pcm')) return 'WAV';
    if (m.contains('ac3') || m.contains('e-ac3') || m.contains('ec3')) return 'AC3';
    if (m.contains('amr')) return 'AMR';
    if (m.contains('dff') || m.contains('dsd') || m.contains('dsf')) return 'DSD';
    if (m.contains('mqa')) return 'MQA';
    return null;
  }

  /// 从文件路径/URL 扩展名推断编码短名（mime 缺失时兜底）。无法识别返回 null。
  static String? codecLabelFromPath(String? url, String? localPath) {
    String? ext;
    for (final p in [localPath, url]) {
      if (p == null || p.isEmpty) continue;
      final q = p.split('?').first;
      final idx = q.lastIndexOf('.');
      if (idx >= 0 && idx < q.length - 1) {
        ext = q.substring(idx + 1).toLowerCase();
        break;
      }
    }
    if (ext == null || ext.isEmpty) return null;
    const map = {
      'flac': 'FLAC',
      'mp3': 'MP3',
      'm4a': 'AAC',
      'aac': 'AAC',
      'opus': 'OPUS',
      'ogg': 'OGG',
      'oga': 'OGG',
      'wav': 'WAV',
      'ape': 'APE',
      'alac': 'ALAC',
      'ac3': 'AC3',
      'amr': 'AMR',
      'dff': 'DSD',
      'dsf': 'DSD',
      'dsd': 'DSD',
    };
    return map[ext] ?? ext.toUpperCase();
  }

  /// 解析音频文件头（FLAC STREAMINFO / WAV fmt chunk）获取原始位深。
  /// 本地文件直接读，网络 URL 用 Range 请求前 64 字节。解析失败返回 null。
  static Future<int?> parseAudioBitDepth(String? url, String? localPath) async {
    try {
      Uint8List head;
      if (localPath != null && localPath.isNotEmpty) {
        final f = File(localPath);
        if (!await f.exists()) {
          // localPath 可能是 file:// URI
          final uri = Uri.tryParse(localPath);
          if (uri == null || uri.scheme != 'file') return null;
          final f2 = File(uri.toFilePath());
          if (!await f2.exists()) return null;
          final raf = await f2.open();
          head = await raf.read(64);
          await raf.close();
        } else {
          final raf = await f.open();
          head = await raf.read(64);
          await raf.close();
        }
      } else if (url != null && url.isNotEmpty) {
        if (url.startsWith('file://')) {
          final f = File(Uri.parse(url).toFilePath());
          if (!await f.exists()) return null;
          final raf = await f.open();
          head = await raf.read(64);
          await raf.close();
        } else if (url.startsWith('http://') || url.startsWith('https://')) {
          final resp = await http
              .get(Uri.parse(url), headers: {'Range': 'bytes=0-63'})
              .timeout(const Duration(seconds: 5));
          if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
          head = resp.bodyBytes;
        } else {
          return null;
        }
      } else {
        return null;
      }

      if (head.length < 32) return null;

      // FLAC: "fLaC" + STREAMINFO 块，采样参数在 offset 8+10=18（8 字节）
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
        const off = 18;
        if (head.length < off + 4) return null;
        final bps = (((head[off + 2] & 0x01) << 4) | ((head[off + 3] >> 4) & 0x0F)) + 1;
        if (bps > 0 && bps <= 32) return bps;
      }

      // WAV: "RIFF" + fmt chunk 的 bitsPerSample（offset 34，2 字节 LE）
      if (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46) {
        if (head.length >= 36) {
          final bps = (head[34] & 0xFF) | ((head[35] & 0xFF) << 8);
          if (bps > 0 && bps <= 32) return bps;
        }
      }
    } catch (_) {
      // 网络/文件解析失败静默处理
    }
    return null;
  }
}
