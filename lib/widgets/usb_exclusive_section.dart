import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services/usb_audio_service.dart';
import '../core/utils/app_toast.dart';
import '../core/utils/audio_format_utils.dart';
import '../providers/player_provider.dart';

/// USB 独占输出设置板块（设置页 / 歌曲信息页共用，保证信息与开关一致）。
///
/// 实时状态来自 [UsbAudioService.statusStream]（服务层每秒轮询一次原生状态）。
/// 拔线检测：独占开启期间 deviceConnected 由 true→false 时提示并回调 [onAutoPause]。
class UsbExclusiveSection extends StatefulWidget {
  /// 拔线时自动暂停播放的回调（由宿主页面注入）。
  final VoidCallback? onAutoPause;

  const UsbExclusiveSection({super.key, this.onAutoPause});

  @override
  State<UsbExclusiveSection> createState() => _UsbExclusiveSectionState();
}

class _UsbExclusiveSectionState extends State<UsbExclusiveSection> {
  Map<String, dynamic> _status = const {};
  bool _loading = false;
  bool _wasDeviceConnected = false;

  /// USB 独占独立音量（0..1，独立记忆，仅独占生效）。本地副本用于 slider 拖动即时反馈。
  double _usbVolume = 1.0;

  /// 输出格式强制（0=自适应跟随源）。本地副本用于下拉框即时反馈，持久化在服务层。
  int _outputRate = 0;
  int _outputBits = 0;
  int _outputChannels = 0;

  // ── 源文件格式（ExoPlayer TrackGroup + 文件头位深），切歌时刷新 ──
  /// 当前曲目的源格式（含歌曲原始采样率/声道/codec），null=尚未获取。
  Map<String, dynamic>? _sourceFormat;

  /// 从音频文件头解析的原始位深（FLAC/WAV），null=未知（有损格式不显示位深）。
  int? _headerBitDepth;

  /// 已拉取源格式的歌曲 id（去重，切歌才重新请求）。
  String? _sourceSongId;

  /// 状态流订阅 + 每秒轮询定时器（页面可见期间保证三行格式链实时）。
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    _statusSub = UsbAudioService.instance.statusStream.listen(_onStatus);
    _wasDeviceConnected = _status['deviceConnected'] == true;
    // 从服务恢复已持久化的 USB 音量（服务启动时已从 SharedPreferences 读取）
    _usbVolume = (UsbAudioService.instance.usbVolumePercent / 100).clamp(0.0, 1.0);
    // 从服务恢复输出格式强制值
    _outputRate = UsbAudioService.instance.outputRate;
    _outputBits = UsbAudioService.instance.outputBits;
    _outputChannels = UsbAudioService.instance.outputChannels;
    // 兜底 c：页面可见时主动查一次（覆盖原生事件未推送的边界场景）
    UsbAudioService.instance.refresh();
    // 每秒轮询原生状态：切歌/钳制重建等场景的格式变化 1s 内刷新到格式链
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      UsbAudioService.instance.refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  /// 拉取当前曲目的源格式（TrackGroup）+ 文件头原始位深（FLAC/WAV）。
  Future<void> _refreshSourceFormat() async {
    try {
      final provider = context.read<PlayerProvider>();
      final player = provider.audioService?.player;
      final song = provider.currentSong;
      Map<String, dynamic>? fmt;
      if (player != null) {
        fmt = await player.getSourceFormat();
      }
      final headerBits =
          await AudioFormatUtils.parseAudioBitDepth(song?.url, song?.localPath);
      if (mounted) {
        setState(() {
          _sourceFormat = fmt;
          _headerBitDepth = headerBits;
        });
      }
    } catch (_) {
      // 源格式仅用于展示，失败静默
    }
  }

  void _onStatus(Map<String, dynamic> s) {
    if (!mounted) return;
    setState(() => _status = s);
    // 拔线检测：独占开启中设备断开 → 提示 + 自动暂停
    final nowConnected = s['deviceConnected'] == true;
    final enabled = s['enabled'] == true;
    if (enabled && _wasDeviceConnected && !nowConnected) {
      widget.onAutoPause?.call();
      if (mounted) {
        showToast('USB DAC 已断开，独占输出已自动关闭');
      }
    }
    _wasDeviceConnected = nowConnected;
  }

  Future<void> _toggle(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        await UsbAudioService.instance.enableExclusive();
      } else {
        await UsbAudioService.instance.disableExclusive();
      }
      // 立即拉一次最新状态刷新 UI
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } on UsbAudioException catch (e) {
      if (mounted) {
        showToast('USB 独占开启失败：${e.message}', long: true);
      }
    } catch (e) {
      if (mounted) {
        showToast('USB 独占操作失败：$e', long: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final enabled = _status['enabled'] == true;
    final connected = _status['deviceConnected'] == true;
    final alive = _status['streamAlive'] == true;
    final deviceName = _status['deviceName'] as String? ?? '未知设备';

    // 切歌后异步拉取源格式（以歌曲 id 去重，与歌曲信息页同一机制）
    final song = context.watch<PlayerProvider>().currentSong;
    if (song?.id != _sourceSongId) {
      _sourceSongId = song?.id;
      _refreshSourceFormat();
    }

    // ── 三行格式链数据：源文件 / 播放流 / DAC 端点 ──────────────
    // 源文件：歌曲原始格式（TrackGroup 采样率/声道 + 文件头位深 + codec 名）
    final src = _sourceFormat;
    final hasSrc = src != null && src['hasData'] == true;
    final srcRate = hasSrc ? ((src['sampleRate'] as num?)?.toInt() ?? 0) : 0;
    final srcCh = hasSrc ? ((src['channelCount'] as num?)?.toInt() ?? 0) : 0;
    final srcCodec = hasSrc ? src['codec'] as String? : null;
    final codecLabel = (srcCodec != null && srcCodec.isNotEmpty)
        ? srcCodec
        : AudioFormatUtils.codecLabelFromPath(song?.url, song?.localPath);
    // 有损格式（MP3/AAC/…）无位深概念；无损格式仅在文件头解析成功时展示
    final srcBits =
        (codecLabel != null && AudioFormatUtils.lossyCodecs.contains(codecLabel))
            ? 0
            : (_headerBitDepth ?? 0);

    // 播放流：独占开启=实际写入 USB 的流配置；未开启=ExoPlayer 解码输出格式
    final ready = _status['streamReady'] == true;
    final streamActive = enabled && ready;
    final usbRate = (_status['sampleRate'] as num?)?.toInt() ?? 0;
    final usbCh = (_status['channelCount'] as num?)?.toInt() ?? 0;
    final dacBits = (_status['dacBitDepth'] as num?)?.toInt() ?? 0;
    final decRate = (_status['lastSampleRate'] as num?)?.toInt() ?? 0;
    final decCh = (_status['lastChannelCount'] as num?)?.toInt() ?? 0;
    final decEnc = (_status['lastEncoding'] as num?)?.toInt() ?? 0;
    final playRate = streamActive ? usbRate : decRate;
    final playCh = streamActive ? usbCh : decCh;
    final playBits = streamActive
        ? dacBits
        : (decRate > 0 ? AudioFormatUtils.encodingBits(decEnc) : 0);
    // DIRECT：整数 PCM 直写（率/声道一致且非 float 输出），native 仅做位深对齐、无 DSP；
    // 经过 float 域（重采样/声道转换/32bit float 开关）为 PCM。
    final isDirect = streamActive &&
        decRate > 0 &&
        decRate == usbRate &&
        decCh == usbCh &&
        decEnc != 4; // C.ENCODING_PCM_FLOAT
    // 与源不一致的率/声道（钳制降级/重采样/上混）用橙色高亮
    final rateConverted = srcRate > 0 && playRate > 0 && srcRate != playRate;
    final chConverted = srcCh > 0 && playCh > 0 && srcCh != playCh;
    final convertColor = Colors.orange.shade800;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // search: usb dac 独占 音频
        SwitchListTile(
          secondary: Icon(Icons.usb, color: colorScheme.primary),
          title: const Text('USB 独占输出'),
          value: enabled,
          onChanged: _loading ? null : _toggle,
        ),
        // 播放 MV 时自动关闭独占（默认开启）：独占绕过 AudioFlinger，MV 无系统音频
        FutureBuilder<bool>(
          future: UsbAudioService.instance.getAutoDisableForMv(),
          builder: (context, snapshot) {
            final autoClose = snapshot.data ?? true;
            // search: usb 独占 mv
            return SwitchListTile(
              secondary: Icon(Icons.movie_outlined, color: colorScheme.primary),
              title: const Text('播放 MV 时自动关闭独占'),
              value: autoClose,
              onChanged: (v) async {
                HapticFeedback.lightImpact();
                await UsbAudioService.instance.setAutoDisableForMv(v);
                if (mounted) setState(() {});
              },
            );
          },
        ),
        // 状态卡
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        connected ? deviceName : '未连接 USB 音频设备',
                        style: textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _StatusChip(
                      connected
                          ? (alive ? '运行中' : '已连接')
                          : '未连接',
                      color: alive
                          ? Colors.green
                          : (connected ? Colors.orange : colorScheme.outline),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // 输出格式选择（采样率/位深/声道，默认自适应；独占开启时改选立即重建流生效）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _formatDropdown(
                  context,
                  icon: Icons.speed,
                  label: '输出采样率',
                  value: _outputRate,
                  items: {
                    0: '自适应',
                    for (final r in _supportedRates()) r: _rateLabel(r),
                  },
                  onChanged: (v) =>
                      _updateFormat(rate: v ?? 0),
                ),
                _formatDropdown(
                  context,
                  icon: Icons.high_quality,
                  label: '输出位深',
                  value: _outputBits,
                  items: {
                    0: '自适应',
                    for (final b in _supportedBits()) b: '$b-bit',
                  },
                  onChanged: (v) =>
                      _updateFormat(bits: v ?? 0),
                ),
                _formatDropdown(
                  context,
                  icon: Icons.surround_sound,
                  label: '输出声道',
                  value: _outputChannels,
                  items: const {
                    0: '自适应',
                    1: '单声道',
                    2: '立体声',
                  },
                  onChanged: (v) =>
                      _updateFormat(channels: v ?? 0),
                ),
                Text(
                  '自适应跟随歌曲格式。强制采样率与源不同时将自动重采样',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                // ── 实时格式链：源文件 → 播放流 → DAC 端点 ──────────────
                const Padding(
                  padding: EdgeInsets.only(top: 12, bottom: 10),
                  child: Divider(height: 1),
                ),
                _FormatChainRow(
                  label: '源文件',
                  segments: [
                    _ChainText(codecLabel ?? '—'),
                    _ChainText(AudioFormatUtils.formatRate(srcRate)),
                    _ChainText(AudioFormatUtils.formatCh(srcCh)),
                    if (srcBits > 0)
                      _ChainText(AudioFormatUtils.formatBits(srcBits)),
                  ],
                ),
                const SizedBox(height: 14),
                _FormatChainRow(
                  label: '播放流',
                  segments: [
                    // DIRECT=整数直写无损（绿）；PCM=经 float 域转换（蓝）；
                    // 未开独占走系统混音=灰色 PCM；无任何播放数据时显示 —
                    if (streamActive)
                      _StatusChip(
                        isDirect ? 'DIRECT' : 'PCM',
                        color:
                            isDirect ? Colors.green : colorScheme.primary,
                      )
                    else if (decRate > 0)
                      _StatusChip('PCM', color: colorScheme.outline)
                    else
                      const _ChainText('—'),
                    _ChainText(
                      AudioFormatUtils.formatRate(playRate),
                      color: rateConverted ? convertColor : null,
                    ),
                    _ChainText(
                      AudioFormatUtils.formatCh(playCh),
                      color: chConverted ? convertColor : null,
                    ),
                    _ChainText(AudioFormatUtils.formatBits(playBits)),
                  ],
                ),
                const SizedBox(height: 14),
                _FormatChainRow(
                  label: 'DAC 端点',
                  // 端点仅在独占流就绪时有实际硬件配置；未开启独占显示 —
                  segments: streamActive
                      ? [
                          const _ChainText('PCM'),
                          _ChainText(AudioFormatUtils.formatRate(usbRate)),
                          _ChainText(AudioFormatUtils.formatCh(usbCh)),
                          _ChainText(AudioFormatUtils.formatBits(dacBits)),
                        ]
                      : [const _ChainText('—')],
                ),
              ],
            ),
          ),
        ),
        // USB 独占独立音量（任何时候可调；独立记忆，仅对独占生效）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _usbVolume <= 0
                          ? Icons.volume_off
                          : _usbVolume < 0.5
                              ? Icons.volume_down
                              : Icons.volume_up,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'USB 音量',
                        style: textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${(_usbVolume * 100).round()}%',
                      style: textTheme.labelMedium
                          ?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ),
                Slider(
                  value: _usbVolume,
                  // 实时生效：拖动即下发原生，无需松手
                  onChanged: (v) {
                    setState(() => _usbVolume = v);
                    UsbAudioService.instance.setUsbVolume(v * 100);
                  },
                  onChangeStart: (_) => HapticFeedback.lightImpact(),
                  onChangeEnd: (_) => HapticFeedback.selectionClick(),
                ),
                Text(
                  enabled
                      ? '已生效：DAC 音量 = 系统音量 × USB 音量'
                      : '未开启独占时暂不生效，开启后即按此音量输出',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        // 调试信息（折叠）：便于真机排查问题，避免后续反复加日志
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.bug_report_outlined,
                size: 18, color: colorScheme.onSurfaceVariant),
            title: Text('调试信息',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            initiallyExpanded: false,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 一键复制 Salt Player 式诊断（设备拓扑/所选端点/有效格式/Rate Set）。
                    // 运行日志走设置页「导出诊断日志」（usb.log 随报告打包）。
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final text = _status['diagnostics']?.toString() ??
                              _status.entries
                                  .map((e) => '${e.key}: ${e.value}')
                                  .join('\n');
                          await Clipboard.setData(ClipboardData(text: text));
                          if (mounted) showToast('诊断信息已复制');
                        },
                        icon: Icon(Icons.copy,
                            size: 14, color: colorScheme.primary),
                        label: Text('复制诊断信息',
                            style: textTheme.labelSmall
                                ?.copyWith(color: colorScheme.primary)),
                      ),
                    ),
                    SelectableText(
                      _status.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join('\n'),
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── 输出格式选择辅助 ─────────────────────────────────────────

  /// 更新输出格式（持久化 + 下发原生；独占开启中原生会立即重建流）。
  void _updateFormat({int? rate, int? bits, int? channels}) {
    HapticFeedback.selectionClick();
    final r = rate ?? _outputRate;
    final b = bits ?? _outputBits;
    final c = channels ?? _outputChannels;
    if (r == _outputRate && b == _outputBits && c == _outputChannels) return;
    setState(() {
      _outputRate = r;
      _outputBits = b;
      _outputChannels = c;
    });
    UsbAudioService.instance.setOutputFormat(r, b, c);
  }

  /// DAC 支持的采样率（getStatus 能力并集；无设备连接时用通用兜底）。
  List<int> _supportedRates() {
    final list = _status['supportedRates'];
    if (list is List && list.isNotEmpty) {
      return list.map((e) => (e as num).toInt()).toList()..sort();
    }
    return const [44100, 48000, 96000];
  }

  /// DAC 支持的位深。
  List<int> _supportedBits() {
    final list = _status['supportedBits'];
    if (list is List && list.isNotEmpty) {
      return list.map((e) => (e as num).toInt()).toList()..sort();
    }
    return const [16, 24];
  }

  String _rateLabel(int rate) {
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  Widget _formatDropdown(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int value,
    required Map<int, String> items,
    required ValueChanged<int?> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: textTheme.bodyMedium),
        ),
        DropdownButton<int>(
          value: items.containsKey(value) ? value : 0,
          underline: const SizedBox.shrink(),
          items: items.entries
              .map((e) => DropdownMenuItem<int>(
                    value: e.key,
                    child: Text(e.value, style: textTheme.bodyMedium),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 格式链中的一行：小灰标签 + 一行粗体格式段（codec/率/声道/位深或徽标）。
class _FormatChainRow extends StatelessWidget {
  final String label;
  final List<Widget> segments;

  const _FormatChainRow({required this.label, required this.segments});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 20,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: segments,
        ),
      ],
    );
  }
}

/// 格式链中的一个文本段（大字号粗体 + 等宽数字）；[color] 非空时用于高亮转换项。
class _ChainText extends StatelessWidget {
  final String text;
  final Color? color;

  const _ChainText(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Text(
      text,
      style: (textTheme.titleSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color ?? Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}
