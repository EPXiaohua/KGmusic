import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS 锁屏/控制中心 Now Playing 信息与远程命令桥接。
///
/// 仅 iOS 激活；其它平台全部 no-op（Android 锁屏/通知由 Media3 的
/// MediaNotificationService 路径负责，不得走此通道）。
/// Swift 端实现见 ios/Runner/AppDelegate.swift 的 NowPlayingManager。
class NowPlayingService {
  NowPlayingService._();

  static final NowPlayingService instance = NowPlayingService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music/now_playing',
  );

  bool _initialized = false;

  /// 远程命令回调（由 PlayerProvider 注入）。
  ///
  /// [action]：play / pause / toggle / next / previous / seek；
  /// [positionMs]：仅 seek 有值，为目标位置（毫秒）。
  void Function(String action, int? positionMs)? onCommand;

  /// 仅 iOS 激活：注册 MethodChannel 处理器，并确保音频会话为
  /// playback 类别且处于激活态（锁屏信息 + 后台播放的前提）。
  ///
  /// 必须在 AudioService.init() 之后调用：audio_service_io 的
  /// _configureAudioSession 因 Android 音频焦点统一交给 Media3 而执行了
  /// setActive(false)，iOS 需在其后重新激活，否则锁屏显示后进后台播放
  /// 仍会被系统打断。
  Future<void> init() async {
    if (_initialized || !Platform.isIOS) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('[NowPlaying] configure audio session failed: $e');
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'command') {
      final args = call.arguments;
      if (args is Map) {
        final action = args['action'] as String?;
        final position = args['position'];
        final positionMs = position is int ? position : null;
        if (action != null) onCommand?.call(action, positionMs);
      }
    }
    return null;
  }

  /// 切歌/元数据变化：下发标题/歌手/专辑/封面 URI/时长（毫秒）。
  Future<void> updateMetadata({
    String? title,
    String? artist,
    String? album,
    String? artUri,
    int? durationMs,
  }) async {
    if (!_initialized || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setMetadata', <String, dynamic>{
        'title': title,
        'artist': artist,
        'album': album,
        'artUri': artUri,
        'duration': durationMs,
      });
    } catch (e) {
      debugPrint('[NowPlaying] setMetadata failed: $e');
    }
  }

  /// 播放进度/状态：[positionMs] 毫秒；playing=false 时 Swift 端把 rate
  /// 置 0，否则锁屏进度条会按墙钟自己走。
  Future<void> updatePlayback({
    required int positionMs,
    required bool playing,
    double speed = 1.0,
  }) async {
    if (!_initialized || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('updatePlayback', <String, dynamic>{
        'position': positionMs,
        'playing': playing,
        'speed': speed,
      });
    } catch (e) {
      debugPrint('[NowPlaying] updatePlayback failed: $e');
    }
  }

  /// 播放停止/清空队列时清空锁屏信息。
  Future<void> clear() async {
    if (!_initialized || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('clear');
    } catch (e) {
      debugPrint('[NowPlaying] clear failed: $e');
    }
  }
}
