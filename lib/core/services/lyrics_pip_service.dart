import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../widgets/apple_lyrics/models/lyric_line.dart';

/// iOS 歌词悬浮窗：系统 Picture-in-Picture（AVSampleBufferDisplayLayer）桥接。
///
/// 仅 iOS 激活；其它平台全部 no-op（Android 悬浮歌词走 FloatingLyricService，
/// 由 DesktopLyricService 原路径负责，互不影响）。
/// Swift 端实现见 ios/Runner/AppDelegate.swift 的 LyricsPipManager。
class LyricsPipService {
  LyricsPipService._();

  static final LyricsPipService instance = LyricsPipService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music/lyrics_pip',
  );

  bool _handlerRegistered = false;
  bool _active = false;

  /// PiP 窗口是否激活（start 成功置位；用户从 PiP 窗口关闭时由原生
  /// 'state' 回调复位）。按钮激活态以它为准。
  bool get active => _active;

  /// PiP 窗口内播放/暂停按钮回调（由 PlayerProvider 注入）。
  /// [playing]：用户在 PiP 窗口按下的目标状态（true=播放 / false=暂停）。
  void Function(bool playing)? onPipPlayPause;

  /// PiP 激活态变化回调（由 DesktopLyricService 注入，刷新按钮高亮）。
  void Function()? onActiveChanged;

  void _ensureHandler() {
    if (_handlerRegistered || !Platform.isIOS) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'command') {
      if (args is Map && args['action'] == 'pipPlayPause') {
        final playing = args['playing'];
        if (playing is bool) onPipPlayPause?.call(playing);
      }
    } else if (call.method == 'state') {
      final isActive = args is Map ? args['active'] == true : false;
      _setActive(isActive);
    }
    return null;
  }

  /// 开关 PiP 悬浮窗，返回切换后的激活态（设备/系统不支持时保持 false）。
  Future<bool> toggle() async {
    if (_active) {
      await stop();
      return _active;
    }
    return start();
  }

  /// 启动 PiP 悬浮窗。乐观置位：窗口真正出现/启动失败由原生 'state'
  /// 回调校正（PictureInPictureControllerDelegate didStart/didStop）。
  Future<bool> start() async {
    if (!Platform.isIOS) return false;
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      if (ok == true) _setActive(true);
      return _active;
    } catch (e) {
      debugPrint('[LyricsPip] start failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[LyricsPip] stop failed: $e');
    }
    _setActive(false);
  }

  /// 歌词整包下发（切歌/解析完成时调用）。[lines] 为解析后的统一歌词模型，
  /// 映射为原生期望的 {start: ms, duration: ms, text, translation} 行数组。
  Future<void> setLyrics(List<LyricLine> lines) async {
    if (!Platform.isIOS) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod('setLyrics', <String, dynamic>{
        'lines': lines
            .map(
              (l) => <String, dynamic>{
                'start': l.startTime,
                'duration': l.duration,
                'text': l.text,
                'translation': l.translation ?? '',
              },
            )
            .toList(),
      });
    } catch (e) {
      debugPrint('[LyricsPip] setLyrics failed: $e');
    }
  }

  /// 播放进度/状态推进。与 NowPlayingService 同源：~1s 节流 + 状态翻转/seek
  /// 立即推；原生端仅行变化（或状态翻转）时重绘，重复位置不重复渲染。
  Future<void> update({required int positionMs, required bool playing}) async {
    if (!Platform.isIOS || !_active) return;
    try {
      await _channel.invokeMethod('update', <String, dynamic>{
        'position': positionMs,
        'playing': playing,
      });
    } catch (e) {
      debugPrint('[LyricsPip] update failed: $e');
    }
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    onActiveChanged?.call();
  }
}
