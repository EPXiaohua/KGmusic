package com.ryanheise.just_audio;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.os.Build;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * USB 独占输出控制器（MD3Music fork）。
 *
 * 设计（对齐 decent-player 的 UsbAudioSink.kt，裁剪掉 NativeAudioEngine 部分）：
 * - [wrap] 始终包装 AudioSink：未开启独占时完全透传，开启后拦截 handleBuffer 的
 *   PCM → UsbStreamingThread → 应用侧 UsbAudioSink（JNI usbdevfs 直写 DAC）。
 * - 包装器在 ExoPlayer 构建时注入，运行时开关（enable/disable）无需重建播放器。
 * - 委托 AudioTrack 保持存活但被静音并强制路由内置扬声器，仅用于 ExoPlayer 时钟/状态机。
 * - 采样率/声道变化（configure 回调）时经 [UsbAudioReconfigListener] 交给应用侧重建流。
 *
 * 线程模型：configure/handleBuffer 在 ExoPlayer 渲染线程执行；USB 写入在
 * UsbStreamingThread（MAX_PRIORITY）执行；enable/disable 由应用侧 MethodChannel 线程触发。
 */
public final class UsbAudioSinkController {

    private static final String TAG = "UsbAudioSinkCtrl";

    /** 队列接近满时返回 false，让 ExoPlayer 稍后重试（背压，匹配 DAC 时钟）。 */
    private static final int QUEUE_BACKPRESSURE_THRESHOLD = 16;

    // ── 日志桥接：链路日志进入应用侧环形缓冲（诊断导出），logcat 行为不变 ──

  /** 应用侧日志桥接（USB 链路环形日志，见 app 模块 UsbLog）。 */
  public interface UsbLogForwarder {
    void forward(char level, String tag, String msg);
  }

  private static volatile UsbLogForwarder logForwarder = null;

  public static void setLogForwarder(UsbLogForwarder forwarder) {
    logForwarder = forwarder;
  }

  static void logI(String tag, String msg) {
    Log.i(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('I', tag, msg);
  }

  static void logW(String tag, String msg) {
    Log.w(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('W', tag, msg);
  }

  static void logE(String tag, String msg) {
    Log.e(tag, msg);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('E', tag, msg);
  }

  static void logE(String tag, String msg, Throwable tr) {
    Log.e(tag, msg, tr);
    UsbLogForwarder f = logForwarder;
    if (f != null) f.forward('E', tag, tr != null ? msg + ": " + tr.getMessage() : msg);
  }

  // ── 全局开关与活动流（由应用侧 UsbAudioPlugin 管理） ──
    private static volatile boolean exclusiveEnabled = false;
    private static volatile UsbAudioSink activeStream = null;
    private static volatile int activeDacBitDepth = 0;
    private static volatile UsbAudioReconfigListener reconfigListener = null;

    // ── 32bit 播放支持开关（默认关闭） ─────────────────────────
    // 开启后让 ExoPlayer 恢复 float 输出（24/32bit 高规格走 float32 直通 AudioTrack）。
    // 注意：部分设备 stereo float 播放异常（速度加快/音高变高），故默认关闭，需用户主动开启。
    // DefaultAudioSink 每个 configure 都会读取该实时标志，因此切歌即生效，无需重建播放器。
    private static volatile boolean floatOutputEnabled = false;

    public static void setFloatOutputEnabled(boolean enabled) {
        floatOutputEnabled = enabled;
    }

    public static boolean isFloatOutputEnabled() {
        return floatOutputEnabled;
    }

    // ── 输出格式强制（0=自适应跟随源；由应用侧经 setOutputFormatOverride 下发） ──
    // 位深强制只影响流配置（插件侧），率/声道在 handleBuffer 拦截路径做转换。
    private static volatile int outputOverrideRate = 0;
    private static volatile int outputOverrideChannels = 0;

    public static void setOutputOverride(int sampleRate, int channelCount) {
        outputOverrideRate = sampleRate > 0 ? sampleRate : 0;
        outputOverrideChannels = channelCount > 0 ? channelCount : 0;
        logI(TAG, "setOutputOverride: rate=" + outputOverrideRate + " ch=" + outputOverrideChannels);
    }

    /** 有效输出采样率（override 优先，否则 0 由调用方兜底）；最后按 DAC 能力钳制。 */
    private static int effectiveRate(int sourceRate) {
        int rate = outputOverrideRate > 0 ? outputOverrideRate : sourceRate;
        return clampToDacRate(rate);
    }

    // ── DAC 能力（应用侧 rebuildStream 成功后同步；null/空=未知不限制） ──
    private static volatile int[] dacSupportedRates = null;
    /** 上次钳制日志记录的目标率（去重，避免 handleBuffer 每块刷屏）。 */
    private static int lastClampedRate = 0;

    public static void setDacSupportedRates(int[] rates) {
        dacSupportedRates = rates;
    }

    /**
     * 采样率钳制：超出 DAC 能力时自动降级 —— 选 ≤目标 的最大支持率；
     * 支持率全部高于目标时取最小。192kHz 等超出 full-speed 端点装包能力的
     * 采样率若不降级，native 装包会超过 maxPacket 导致 SUBMITURB 失败/堆溢出。
     */
    private static int clampToDacRate(int rate) {
        int[] rates = dacSupportedRates;
        if (rates == null || rates.length == 0 || rate <= 0) return rate;
        for (int r : rates) {
            if (r == rate) return rate;
        }
        int best = rates[0];
        for (int r : rates) {
            if (r <= rate && r > best) best = r;
        }
        if (best > rate) {
            best = rates[0];
            for (int r : rates) {
                if (r < best) best = r;
            }
        }
        if (best != lastClampedRate) {
            logI(TAG, "rate clamped to DAC capability: " + rate + " → " + best);
            lastClampedRate = best;
        }
        return best;
    }

    /** 有效输出声道数（override 优先，否则 0 由调用方兜底）；最后按 DAC 端点能力钳制。 */
    private static int effectiveChannels(int sourceChannels) {
        int ch = outputOverrideChannels > 0 ? outputOverrideChannels : sourceChannels;
        return clampToDacChannels(ch);
    }

    // ── DAC 端点声道数（应用侧建流成功后同步；0=未知不限制） ──
    private static volatile int dacChannels = 0;
    /** 上次钳制日志记录的目标声道（去重）。 */
    private static int lastClampedChannels = 0;
    /** 不支持编码的一次性警告标志。 */
    private static boolean convertUnsupportedWarned = false;
    /** handleBuffer 计数镜像（写线程快照用，区分 renderer 未喂 vs 喂了未转换）。 */
    private static volatile int lastHandleBufferCount = 0;

    public static void setDacChannels(int ch) {
        dacChannels = ch;
    }

    /** 设备关闭/更换时重置能力缓存与钳制日志去重（防旧设备能力残留）。 */
    public static void resetDacCapabilities() {
        dacSupportedRates = null;
        dacChannels = 0;
        lastClampedRate = 0;
        lastClampedChannels = 0;
    }

    /** 插件建流用：override 优先 + DAC 端点声道钳制后的最终声道数。 */
    public static int getTargetOutputChannels() {
        return clampToDacChannels(effectiveChannels(lastChannelCount));
    }

    /**
     * 声道钳制：流声道必须等于端点 bNrChannels，否则 DAC 按端点声道解释数据导致变调
     * （如 1ch 数据写 2ch 端点 → 速度 2 倍）。源声道不符由 handleBuffer 上/下混处理。
     */
    private static int clampToDacChannels(int ch) {
        int dac = dacChannels;
        if (dac <= 0 || ch <= 0 || ch == dac) return ch;
        if (dac != lastClampedChannels) {
            logI(TAG, "channels clamped to DAC endpoint: " + ch + " → " + dac);
            lastClampedChannels = dac;
        }
        return dac;
    }

    /** 供写线程在 Queue EMPTY 首次触发时输出状态快照（定位 renderer 停喂）。 */
    static void logStreamingState(String reason, boolean threadAlive, int queueSize) {
        logW(TAG, reason + " | usbRate=" + usbSampleRate + "Hz/" + usbChannelCount + "ch"
                + " enc=" + encName(lastEncoding) + " srcRate=" + lastSampleRate
                + " srcCh=" + lastChannelCount + " overrideRate=" + outputOverrideRate
                + " overrideCh=" + outputOverrideChannels
                + " hbCount=" + lastHandleBufferCount
                + " queue=" + queueSize + " threadAlive=" + threadAlive);
    }

    /** 插件建流用：override 优先 + DAC 能力钳制后的最终输出率（自适应场景自动降级 192k→96k）。 */
    public static int getTargetOutputRate() {
        return clampToDacRate(effectiveRate(lastSampleRate));
    }

    // ── 最近一次 ExoPlayer 解码输出格式（无论是否开启独占都会捕获，供歌曲信息页/初始化使用） ──
    private static volatile int lastSampleRate = 0;
    private static volatile int lastChannelCount = 0;
    private static volatile int lastEncoding = C.ENCODING_PCM_16BIT;

    // ── 当前 USB 流实际使用的采样率/声道（格式变更检测用） ──
    private static volatile int usbSampleRate = 0;
    private static volatile int usbChannelCount = 0;

    /** 最近一次播放器音量（0..1）。DAC 音量 = 系统媒体音量 × 该值。 */
    private static volatile float lastPlayerVolume = 1f;

    /**
     * 应用侧指定的 delegate 偏好输出设备（如 USB DAC）。
     * 关闭独占后显式路由到 USB，实现"非独占仍走 DAC"；开启独占时置 null 回到系统默认。
     * 保存在静态字段：关闭独占时若没有活跃 sink，后续新建的 sink 也会在 configure 时应用。
     */
    private static volatile AudioDeviceInfo preferredDevice = null;

    /**
     * 设置 delegate AudioTrack 的偏好输出设备（ForwardingAudioSink 已转发给 DefaultAudioSink）。
     * 设备已存在时 DefaultAudioSink 即时调用 AudioTrack.setPreferredDevice 切换；不存在时
     * 缓存在 DefaultAudioSink.preferredDevice，下次 configure 创建 AudioTrack 时应用。
     */
    public static void setDelegatePreferredDevice(@Nullable AudioDeviceInfo device) {
        preferredDevice = device;
        if (Build.VERSION.SDK_INT < 23) return;
        for (UsbInterceptAudioSink s : liveSinks) s.setPreferredDevice(device);
    }

    /** 新 sink 在 configure 时应用静态偏好路由（关闭独占后创建的 sink 也要走 USB）。 */
    private static void applyPreferredDeviceIfNeeded(UsbInterceptAudioSink sink) {
        AudioDeviceInfo device = preferredDevice;
        if (device != null && Build.VERSION.SDK_INT >= 23) {
            sink.setPreferredDevice(device);
        }
    }

    /**
     * 延迟重试用：强制所有 delegate AudioTrack 重新 start（等效用户暂停→重播）。
     * AudioTrack 迁移到未就绪的 USB 设备会静默失败（无声但数据照走），
     * pause+play 让 AudioFlinger 基于当前已就绪的设备重新路由。
     */
    public static void restartDelegateRouting() {
        for (UsbInterceptAudioSink s : liveSinks) s.restartRouting();
    }

    /** 播放器音量变化回调（应用侧用它更新 DAC 硬件音量）。 */
    public interface UsbVolumeListener {
        void onPlayerVolumeChanged(float volume);
    }

    private static volatile UsbVolumeListener volumeListener = null;

    public static void setVolumeListener(UsbVolumeListener listener) {
        volumeListener = listener;
    }

    public static float getLastPlayerVolume() {
        return lastPlayerVolume;
    }

    // ── 渲染器停喂自愈（Queue EMPTY 兜底） ─────────────────────────
    // ExoPlayer 渲染循环一旦停喂（configure 竞态/渲染器内因），USB 队列持续空转
    // 且无错误抛出（实测 hbCount 冻结 2.5s+）。从 sink 侧唯一能唤醒渲染器的
    // 手段是 seek：触发 onPositionReset → flushOrReinitializeCodec → 重新预滚。
    // 由应用侧 AudioPlayer 注册 listener，经主线程执行 seekTo(当前进度)。

    /** 渲染器停喂回调（应用侧实现：主线程 seek 当前位置）。 */
    public interface StallRecoveryListener {
        void onRendererStalled();
    }

    private static volatile StallRecoveryListener stallRecoveryListener = null;

    public static void setStallRecoveryListener(@Nullable StallRecoveryListener l) {
        stallRecoveryListener = l;
    }

    /** 停喂判定阈值（ms）：最后一次入队后静默超过该值视为停喂。 */
    private static final long STALL_THRESHOLD_MS = 2500L;
    /** 自愈冷却（ms），防止 seek 风暴。 */
    private static final long STALL_COOLDOWN_MS = 8000L;
    /** 单轮停喂自愈次数上限，超过则放弃等待用户操作。 */
    private static final int STALL_MAX_ATTEMPTS = 3;

    private static volatile long lastDataEnqueueMs = 0L;
    private static volatile long lastRecoveryMs = 0L;
    private static volatile int recoveryAttempts = 0;

    static long nowMs() {
        return android.os.SystemClock.elapsedRealtime();
    }

    /** handleBuffer 成功入队时调用：刷新最后数据时间并重置自愈计数。 */
    static void onDataEnqueued() {
        lastDataEnqueueMs = nowMs();
        recoveryAttempts = 0;
    }

    /** 写线程空转探测回调（每 100ms 一次）。仅播放中才判定停喂。 */
    static void onStallProbe(boolean sinkPlaying) {
        if (!sinkPlaying) return;
        StallRecoveryListener l = stallRecoveryListener;
        if (l == null) return;
        long now = nowMs();
        if (lastDataEnqueueMs <= 0 || now - lastDataEnqueueMs < STALL_THRESHOLD_MS) return;
        if (now - lastRecoveryMs < STALL_COOLDOWN_MS) return;
        if (recoveryAttempts >= STALL_MAX_ATTEMPTS) return;
        lastRecoveryMs = now;
        recoveryAttempts++;
        logE(TAG, "renderer stalled — auto-seek recovery fired (attempt "
                + recoveryAttempts + "/" + STALL_MAX_ATTEMPTS + ")");
        try {
            l.onRendererStalled();
        } catch (Exception e) {
            logE(TAG, "stall recovery listener threw: " + e.getMessage());
        }
    }

    // ── PCM 频谱捕获（MD3Music 频谱功能用） ────────────────────────
    // 无论是否 USB 独占，都在 handleBuffer 截取解码后的原始 PCM 快照。
    // 该数据在 AudioFlinger 混音之前，不受系统媒体音量影响 —— 静音播放时
    // 频谱依然有真实数据（Visualizer 做不到这点）。
    public interface PcmCaptureListener {
        /**
         * @param buffer      当前块 PCM（position 指向读取起点，调用方勿改动原始 buffer）
         * @param encoding    C.ENCODING_PCM_16BIT / PCM_24BIT / PCM_32BIT / PCM_FLOAT
         * @param sampleRate  解码采样率（Hz）
         * @param channelCount 声道数
         */
        void onPcm(java.nio.ByteBuffer buffer, int encoding, int sampleRate, int channelCount);
    }

    private static volatile PcmCaptureListener pcmCaptureListener = null;

    public static void setPcmCaptureListener(PcmCaptureListener listener) {
        pcmCaptureListener = listener;
    }

    /** 所有存活包装器（应用可能创建多个播放器实例）。 */
    private static final List<UsbInterceptAudioSink> liveSinks = new CopyOnWriteArrayList<>();

    /** 采样率/声道变化时由控制器回调应用侧重建 USB 流。 */
    public interface UsbAudioReconfigListener {
        /**
         * @return 已按新格式创建并 start 的流；失败返回 null（控制器将回退普通输出）。
         */
        UsbAudioSink onFormatChanged(int sampleRate, int channelCount, int pcmEncoding);
    }

    private UsbAudioSinkController() {}

    // ── 静态 API（供应用侧插件调用） ──────────────────────────────

    /** 包装 AudioSink。未开启独占时行为与不包装完全一致。 */
    public static AudioSink wrap(AudioSink delegate, Context context) {
        UsbInterceptAudioSink sink = new UsbInterceptAudioSink(delegate, context);
        liveSinks.add(sink);
        android.util.Log.i("NormGainTest", "WrapUsbMarker"); // 唯一标记，验证构建是否保留
        // MD3Music fork: 音量均衡——增益装饰器包在 USB 拦截层之外，先缩放再交给下层。
        return NormalizationGainAudioSink.wrap(sink);
    }

    /** 开启独占。应用侧须先完成：打开设备 → 创建流 → 按 xHCI 时序 setAlt/SET_CUR/start。 */
    public static synchronized boolean enable(UsbAudioSink stream, int dacBitDepth,
                                              int sampleRate, int channelCount) {
        if (stream == null || !stream.isReady()) {
            logE(TAG, "enable: stream not ready");
            return false;
        }
        if (sampleRate <= 0) sampleRate = lastSampleRate;
        if (channelCount <= 0) channelCount = lastChannelCount;
        // 双保险：enable 记录必须与实际建流的率/声道（override+钳制出口）一致
        sampleRate = clampToDacRate(sampleRate);
        channelCount = clampToDacChannels(channelCount);
        activeStream = stream;
        activeDacBitDepth = dacBitDepth;
        usbSampleRate = sampleRate;
        usbChannelCount = channelCount;
        exclusiveEnabled = true;
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(true);
        logI(TAG, "exclusive ENABLED: " + usbSampleRate + "Hz/" + usbChannelCount
                + "ch dac=" + dacBitDepth + "bit");
        return true;
    }

    /**
     * 关闭独占（阶段一）：停写线程、清活动流。
     * 注意：不在此处恢复 delegate 音量/路由 —— 必须先由调用方释放 USB 设备
     * （stop→drain→release→closeDevice，否则 DAC 仍被占用，delegate 路由回去会无声），
     * 再调用 [onUsbReleased] 恢复。顺序见 UsbAudioPlugin.disableExclusive。
     */
    public static synchronized UsbAudioSink disable() {
        UsbAudioSink old = activeStream;
        exclusiveEnabled = false;
        for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
        activeStream = null;
        activeDacBitDepth = 0;
        logI(TAG, "exclusive DISABLED (delegate restore deferred to onUsbReleased)");
        return old;
    }

    /** 关闭独占（阶段二）：USB 设备完全释放后调用，恢复 delegate 音量/路由。 */
    public static synchronized void onUsbReleased() {
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(false);
    }

    public static boolean isEnabled() { return exclusiveEnabled; }

    public static void setReconfigListener(UsbAudioReconfigListener listener) {
        reconfigListener = listener;
    }

    /**
     * 按当前有效格式（override 优先）立即重建活动流。供应用侧在"输出格式选择"
     * 变更后调用（须在后台线程；内部与 reconfigStream 相同的互斥与释放顺序）。
     */
    public static void reconfigureActiveStream() {
        UsbAudioReconfigListener listener = reconfigListener;
        if (!exclusiveEnabled || listener == null) return;
        synchronized (UsbAudioSinkController.class) {
            for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
            UsbAudioSink old = activeStream;
            activeStream = null;
            if (old != null) {
                try { old.stop(); old.drainUrbs(); old.release(); } catch (Exception e) {
                    logE(TAG, "reconfigureActiveStream: old release failed: " + e.getMessage());
                }
            }
            int rate = effectiveRate(lastSampleRate);
            int ch = effectiveChannels(lastChannelCount);
            UsbAudioSink fresh = null;
            try {
                fresh = listener.onFormatChanged(rate, ch, lastEncoding);
            } catch (Exception e) {
                logE(TAG, "reconfigureActiveStream: listener threw: " + e.getMessage(), e);
            }
            if (fresh != null && fresh.isReady()) {
                activeStream = fresh;
                usbSampleRate = rate;
                usbChannelCount = ch;
                logI(TAG, "reconfigureActiveStream OK → " + rate + "Hz/" + ch + "ch");
            } else {
                logE(TAG, "reconfigureActiveStream FAILED — falling back to normal output");
                if (fresh != null) { try { fresh.release(); } catch (Exception ignored) {} }
                disable();
                onUsbReleased();
            }
        }
    }

    public static int getLastSampleRate() { return lastSampleRate; }
    public static int getLastChannelCount() { return lastChannelCount; }
    public static int getLastEncoding() { return lastEncoding; }

    /** 歌曲信息页用：当前解码输出格式。 */
    public static Map<String, Object> getFormatInfo() {
        Map<String, Object> m = new HashMap<>();
        m.put("sampleRate", lastSampleRate);
        m.put("channelCount", lastChannelCount);
        m.put("encoding", lastEncoding);
        m.put("hasData", lastSampleRate > 0);
        return m;
    }

    /** 实时状态（设置页/歌曲信息页轮询）。 */
    public static Map<String, Object> getStatus() {
        Map<String, Object> m = new HashMap<>();
        m.put("enabled", exclusiveEnabled);
        m.put("streamReady", activeStream != null && activeStream.isReady());
        m.put("streamAlive", activeStream != null && activeStream.isAlive());
        m.put("framesWritten", activeStream != null ? activeStream.getFramesWritten() : 0L);
        m.put("sampleRate", usbSampleRate);
        m.put("channelCount", usbChannelCount);
        m.put("dacBitDepth", activeDacBitDepth);
        // 最近一次解码输出格式（未开启独占时也能展示歌曲信息）
        m.put("lastSampleRate", lastSampleRate);
        m.put("lastChannelCount", lastChannelCount);
        m.put("lastEncoding", lastEncoding);
        return m;
    }

    public static String encName(int encoding) {
        if (encoding == C.ENCODING_PCM_FLOAT) return "FLOAT";
        if (encoding == C.ENCODING_PCM_16BIT) return "16BIT";
        if (encoding == C.ENCODING_PCM_24BIT) return "24BIT";
        if (encoding == C.ENCODING_PCM_32BIT) return "32BIT";
        return "UNKNOWN(" + encoding + ")";
    }

    // ── 拦截型 AudioSink ─────────────────────────────────────────

    static final class UsbInterceptAudioSink extends ForwardingAudioSink {

        private final Context context;
        private UsbStreamingThread streamingThread = null;
        private final UsbPcmResampler usbResampler = new UsbPcmResampler();
        private boolean delegateMuted = false;
        private float pendingVolume = 1f;
        private int currentEncoding = C.ENCODING_PCM_16BIT;
        private int currentSampleRate = 0;
        private int currentChannelCount = 0;
        private boolean isPlaying = false;
        private long handleBufferCallCount = 0;
        private long posLogCount = 0;
        private long lastPosLogMs = 0L;
        private long lastBackpressureLogMs = 0L;
        /** 本 sink 是否已实际写入过数据（同率切歌时 ring 可能残留上一首 URB，用于判定是否 drain）。 */
        private boolean hasPlayedData = false;
        private long usbStartMediaTimeUs = 0L;
        private boolean usbStartMediaTimeNeedsInit = true;
        private boolean handledEndOfStream = false;

        UsbInterceptAudioSink(AudioSink delegate, Context ctx) {
            super(delegate);
            this.context = ctx.getApplicationContext();
        }

        @Override
        public void configure(Format inputFormat, int specifiedBufferSize, int[] outputChannels)
                throws ConfigurationException {
            // 应用静态偏好路由（关闭独占后新建/重配的 sink 也要显式走 USB DAC）
            applyPreferredDeviceIfNeeded(this);
            int enc = inputFormat.pcmEncoding;
            if (enc != Format.NO_VALUE) currentEncoding = enc;
            int sr = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 0;
            int ch = inputFormat.channelCount > 0 ? inputFormat.channelCount : 0;
            if (sr > 0 && ch > 0) {
                lastSampleRate = sr;
                lastChannelCount = ch;
            }
            lastEncoding = currentEncoding;
            currentSampleRate = sr;
            currentChannelCount = ch;
            logI(TAG, "configure: enc=" + encName(currentEncoding) + " rate=" + sr + " ch=" + ch);

            if (exclusiveEnabled && activeStream != null) {
                // 格式纪元边界复位：每次 configure 都从干净状态开始。
                // 1) super.flush() 清掉 delegate 的粘滞 pendingConfiguration —— 独占期间
                //    super.handleBuffer 永不执行，DefaultAudioSink.configure 的延迟配置
                //    只有 handleBuffer/flush 才会解析；"播放中 configure"会让 delegate
                //    长期处于 pending 状态（"暂停中 configure"因先有 pause/flush 幸免）。
                // 2) 清空旧格式队列 + 复位重采样器与 usbStartMediaTimeUs 基线，
                //    消除 FLOAT→16BIT 等格式切换后位置/数据错位。
                // 这统一了"播放中 configure"与"暂停中 configure"的行为（停喂根因）。
                flush();
                // 切歌/采样率切换/死流自愈：重建 USB 流（先停旧流，再让应用侧按新格式重建）。
                // 不要求 isAlive()：流死亡（如 SUBMITURB 失败）后若跳过重建，
                // 写线程会静默丢弃数据导致持续无声。
                // 采样率先按 DAC 能力钳制（如 192k → 96k），声道同样钳制到端点声道数
                // （如 1ch → 2ch），避免重建出与端点不符的流或 Controller 记录错位。
                sr = clampToDacRate(sr);
                ch = clampToDacChannels(ch);
                boolean needReconfig = sr > 0 && ch > 0
                        && (sr != usbSampleRate || ch != usbChannelCount || !activeStream.isAlive());
                if (needReconfig) {
                    reconfigStream(sr, ch, currentEncoding);
                    // 重建后的新流 ring 为空，重新起算
                    hasPlayedData = false;
                } else if (hasPlayedData) {
                    // 同率/同声道切歌不重建流，native ring 里可能还压着上一首的在途 URB
                    // （flush 只清 Java 队列与帧计数，不 drain ring）→ 新歌 framesWritten
                    // 从 0 计但 DAC 实际还播旧数据，位置语义失真、开头串音。
                    // stop/drain/start 清 ring（不重新 setAlt/SET_CUR，毫秒级）。
                    UsbAudioSink s = activeStream;
                    if (s != null && s.isAlive()) {
                        try {
                            s.stop();
                            s.drainUrbs();
                            s.start();
                            logI(TAG, "ring drained on same-rate reconfigure");
                        } catch (Exception e) {
                            logE(TAG, "ring drain failed: " + e.getMessage());
                        }
                    }
                    hasPlayedData = false;
                }
                // delegate 静音轨也必须用钳制后的格式：原始 192k 会让系统 AudioTrack
                // 初始化失败（多数输出设备不支持 192k）→ ExoPlayer error → renderer 停喂。
                Format delegateFormat =
                        (sr != inputFormat.sampleRate || ch != inputFormat.channelCount)
                                ? inputFormat.buildUpon().setSampleRate(sr).setChannelCount(ch).build()
                                : inputFormat;
                super.configure(delegateFormat, specifiedBufferSize, outputChannels);
                muteDelegateIfNeeded();
                return;
            }

            super.configure(inputFormat, specifiedBufferSize, outputChannels);
        }

        private void reconfigStream(int sampleRate, int channelCount, int encoding) {
            logI(TAG, "reconfigStream: " + sampleRate + "Hz/" + channelCount + "ch (was "
                    + usbSampleRate + "/" + usbChannelCount + ")");
            UsbAudioReconfigListener listener = reconfigListener;
            if (listener == null) {
                logW(TAG, "reconfigStream: no listener — keeping old stream");
                return;
            }
            // 与 enable/disable 互斥，避免并发切换时 double-release
            synchronized (UsbAudioSinkController.class) {
            // 1) 停掉所有写线程（线程持有旧流引用）
            for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
            // 2) 停旧流并释放原生上下文（drain 必须在 setAlt(0) 前完成）。
            //    先置空 activeStream，防止重建窗口内 handleBuffer 触碰已释放的上下文
            UsbAudioSink old = activeStream;
            activeStream = null;
            if (old != null) {
                try { old.stop(); old.drainUrbs(); old.release(); } catch (Exception e) {
                    logE(TAG, "old stream release failed: " + e.getMessage());
                }
            }
            // 3) 应用侧重建（打开设备→创建流→setAlt(0)→SET_CUR→setAlt(N)→start）
            UsbAudioSink fresh = null;
            try {
                fresh = listener.onFormatChanged(sampleRate, channelCount, encoding);
            } catch (Exception e) {
                logE(TAG, "reconfig listener threw: " + e.getMessage(), e);
            }
            if (fresh != null && fresh.isReady()) {
                activeStream = fresh;
                usbSampleRate = sampleRate;
                usbChannelCount = channelCount;
                logI(TAG, "reconfigStream OK → " + sampleRate + "Hz/" + channelCount + "ch");
            } else {
                // 重建失败：回退普通输出。disable() 已停线程/清流；恢复 delegate 音量。
                // 设备连接保留（插件侧 currentAdapter 已清空，下次 enable 复用）。
                logE(TAG, "reconfigStream FAILED — falling back to normal output");
                if (fresh != null) { try { fresh.release(); } catch (Exception ignored) {} }
                disable();
                onUsbReleased();
            }
            }
        }

        @Override
        public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
                throws InitializationException, WriteException {
            // ── 频谱 PCM 捕获：无论是否 USB 独占都截取（解码后、混音前，静音也有数据） ──
            PcmCaptureListener pcmListener = pcmCaptureListener;
            if (pcmListener != null && currentSampleRate > 0 && buffer != null && buffer.remaining() > 0) {
                try {
                    pcmListener.onPcm(
                            buffer.duplicate().order(buffer.order()),
                            currentEncoding, currentSampleRate, currentChannelCount);
                } catch (Exception e) {
                    logW(TAG, "pcm capture listener threw: " + e.getMessage());
                }
            }
            UsbAudioSink stream = activeStream;
            if (exclusiveEnabled) {
                if (stream == null || !stream.isAlive()) {
                    // 独占开启但流不可用（重建窗口/死流）：吞掉数据保持静音。
                    // 不能送 delegate —— 会从手机扬声器漏音，且 delegate 可能按源
                    // 格式（如 192k）初始化失败抛 InitializationException 导致停播。
                    // reconfigStream 失败路径已自行 disable() 回普通输出，不受影响。
                    buffer.position(buffer.limit());
                    return true;
                }
                muteDelegateIfNeeded();
                if (streamingThread == null) {
                    streamingThread = new UsbStreamingThread(stream);
                    // 暂停状态接管 → 线程创建即暂停（不消费队列 → 不写 DAC）
                    if (!isPlaying) streamingThread.pauseStreaming();
                    streamingThread.start();
                    logI(TAG, "USB streaming thread created (isPlaying=" + isPlaying + ")");
                }
                // 捕获媒体时间线偏移，用于 framesWritten → 播放进度换算
                if (usbStartMediaTimeNeedsInit) {
                    usbStartMediaTimeUs = Math.max(0L, presentationTimeUs);
                    usbStartMediaTimeNeedsInit = false;
                    logI(TAG, "usbStartMediaTimeUs=" + usbStartMediaTimeUs);
                }
                handleBufferCallCount++;
                lastHandleBufferCount = (int) handleBufferCallCount;
                // 诊断：前 5 次 + 每 500 次打印，观察暂停后是否仍有数据喂入
                if (handleBufferCallCount <= 5 || handleBufferCallCount % 500 == 0) {
                    logI(TAG, "handleBuffer #" + handleBufferCallCount + " pts=" + presentationTimeUs
                            + " isPlaying=" + isPlaying + " queue=" + streamingThread.queueSize()
                            + " enc=" + encName(currentEncoding));
                }
                // 阻塞式背压（对齐系统 AudioTrack.write 语义）：队列达水线时在渲染线程
                // 有界阻塞等空位，而不是返回 false 让 ExoPlayer 按「(pts−clock位置)/2」
                // 调度睡眠。我们的 clock 位置依赖持续喂入（framesWritten），睡眠会与
                // 位置冻结形成死锁（实测 192k 首曲 hbCount 永久冻结、无声）。
                // awaitSpace 内部带 1s 超时 + pause/stop/flush 退出，边界不会挂死。
                if (streamingThread.queueSize() >= QUEUE_BACKPRESSURE_THRESHOLD) {
                    if (!streamingThread.awaitSpace(1000L)) {
                        // 被打断/超时：回退旧契约（同一 buffer 稍后重试），行为不劣化
                        if (nowMs() - lastBackpressureLogMs >= 2000L) {
                            lastBackpressureLogMs = nowMs();
                            logI(TAG, "backpressure: return false pts=" + presentationTimeUs
                                    + " queue=" + streamingThread.queueSize()
                                    + " hbCount=" + handleBufferCallCount);
                        }
                        return false;
                    }
                }
                ByteBuffer snapshot = buffer.slice().order(buffer.order());
                // 统一转换出口：源格式 ≠ 流配置(usbSampleRate/usbChannelCount) 时触发转换
                // （float → 声道 → 重采样），一致时走 RAW 直写保持 bit-perfect。
                // 目标就是流配置本身（流由 createStartedStream 按 override+钳制统一出口建立）。
                boolean needCh = usbChannelCount > 0 && currentChannelCount > 0
                        && currentChannelCount != usbChannelCount;
                boolean needResample = usbSampleRate > 0 && currentSampleRate > 0
                        && currentSampleRate != usbSampleRate;
                if (needCh || needResample) {
                    // 输出格式转换路径：统一转 float → 声道转换 → 线性插值重采样。
                    float[] f = toFloatInterleaved(snapshot, currentEncoding);
                    if (f == null && !convertUnsupportedWarned) {
                        // 罕见编码（8BIT/INVALID）无法转 float：数据将被丢弃，至少可见
                        convertUnsupportedWarned = true;
                        logW(TAG, "CONVERT skipped: unsupported encoding "
                                + encName(currentEncoding));
                    }
                    if (f != null && f.length > 0) {
                        if (handleBufferCallCount <= 3) {
                            logI(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": CONVERT src=" + currentSampleRate + "Hz/"
                                    + currentChannelCount + "ch → " + usbSampleRate + "Hz/"
                                    + usbChannelCount + "ch");
                        }
                        if (needCh) f = UsbPcmResampler.convertChannels(f, currentChannelCount, usbChannelCount);
                        if (needResample) {
                            // 必须先设置重采样格式（srcRate/声道/目标率），否则 process 恒直通
                            usbResampler.setFormat(currentSampleRate, usbChannelCount, usbSampleRate);
                            f = usbResampler.process(f);
                        }
                        if (f.length > 0) {
                            streamingThread.enqueue(f);
                            hasPlayedData = true;
                        }
                    }
                    buffer.position(buffer.limit());
                    return true;
                }
                if (currentEncoding == C.ENCODING_PCM_FLOAT) {
                    int totalSamples = snapshot.remaining() / 4;
                    if (totalSamples > 0) {
                        float[] floatBuf = new float[totalSamples];
                        snapshot.asFloatBuffer().get(floatBuf);
                        if (handleBufferCallCount <= 3) {
                            logI(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": FLOAT samples=" + totalSamples);
                        }
                        streamingThread.enqueue(floatBuf);
                        hasPlayedData = true;
                    }
                } else {
                    int remaining = snapshot.remaining();
                    if (remaining > 0) {
                        byte[] rawBytes = new byte[remaining];
                        snapshot.get(rawBytes);
                        if (handleBufferCallCount <= 3) {
                            logI(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": RAW " + encName(currentEncoding) + " bytes=" + remaining);
                        }
                        streamingThread.enqueueRaw(rawBytes, currentEncoding);
                        hasPlayedData = true;
                    }
                }
                buffer.position(buffer.limit());
                return true;
            }
            unmuteDelegateIfNeeded();
            return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
        }

        @Override
        public long getCurrentPositionUs(boolean sourceEnded) {
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                if (usbStartMediaTimeNeedsInit) {
                    // 节流留痕：needsInit 期间渲染器拿到 NOT_SET（保留其内部旧位置钳位）
                    if (nowMs() - lastPosLogMs >= 1000L) {
                        lastPosLogMs = nowMs();
                        logI(TAG, "getCurrentPositionUs: NOT_SET (needsInit, ended=" + sourceEnded + ")");
                    }
                    return AudioSink.CURRENT_POSITION_NOT_SET;
                }
                long frames = activeStream.getFramesWritten();
                // 分母用有效输出采样率（usbSampleRate）：自适应时等于源率；
                // 强制采样率时 framesWritten 为重采样后的输出率帧数，用源率会漂移。
                if (usbSampleRate > 0) {
                    long posUs = usbStartMediaTimeUs + frames * C.MICROS_PER_SECOND / usbSampleRate;
                    // 节流快照（≥1s）：定位 position 停滞（停喂根因观测点）
                    if (nowMs() - lastPosLogMs >= 1000L) {
                        lastPosLogMs = nowMs();
                        logI(TAG, "posUs=" + posUs + " frames=" + frames + " usbRate=" + usbSampleRate
                                + " base=" + usbStartMediaTimeUs + " ended=" + sourceEnded);
                    }
                    return posUs;
                }
                return AudioSink.CURRENT_POSITION_NOT_SET;
            }
            return super.getCurrentPositionUs(sourceEnded);
        }

        /** 整数/浮点 PCM 统一转 interleaved float（声道转换/重采样前的中间表示）。 */
        private static float[] toFloatInterleaved(ByteBuffer b, int encoding) {
            final int rem = b.remaining();
            switch (encoding) {
                case C.ENCODING_PCM_FLOAT: {
                    final int n = rem / 4;
                    final float[] out = new float[n];
                    b.asFloatBuffer().get(out);
                    return out;
                }
                case C.ENCODING_PCM_16BIT: {
                    final ShortBuffer sb = b.asShortBuffer();
                    final int n = sb.remaining();
                    final float[] out = new float[n];
                    for (int i = 0; i < n; i++) out[i] = sb.get(i) / 32768f;
                    return out;
                }
                case C.ENCODING_PCM_24BIT: {
                    // 3 字节小端有符号，统一走字节展开（asShortBuffer 不适用 3 字节对齐）
                    final int n = rem / 3;
                    final float[] out = new float[n];
                    final int start = b.position();
                    for (int i = 0; i < n; i++) {
                        final int o = start + i * 3;
                        int v = (b.get(o) & 0xFF) | ((b.get(o + 1) & 0xFF) << 8)
                                | ((b.get(o + 2) & 0xFF) << 16);
                        if (b.get(o + 2) < 0) v |= 0xFF000000;
                        out[i] = v / 8388608f;
                    }
                    return out;
                }
                case C.ENCODING_PCM_32BIT: {
                    final IntBuffer ib = b.asIntBuffer();
                    final int n = ib.remaining();
                    final float[] out = new float[n];
                    for (int i = 0; i < n; i++) {
                        out[i] = (float) ((double) ib.get(i) / 2147483648.0);
                    }
                    return out;
                }
                default:
                    return null;
            }
        }

        @Override public void play() {
            super.play();
            isPlaying = true;
            if (streamingThread != null) streamingThread.resumeStreaming();
            logI(TAG, "sink.play() → isPlaying=true (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void pause() {
            isPlaying = false;
            if (streamingThread != null) streamingThread.pauseStreaming();
            super.pause();
            logI(TAG, "sink.pause() → isPlaying=false (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void flush() {
            super.flush();
            if (streamingThread != null) streamingThread.flush();
            usbResampler.reset();
            UsbAudioSink stream = activeStream;
            if (exclusiveEnabled && stream != null) {
                try { stream.flush(); } catch (Exception e) {
                    logE(TAG, "stream.flush failed: " + e.getMessage());
                }
            }
            usbStartMediaTimeNeedsInit = true;
            handledEndOfStream = false;
            if (streamingThread != null) streamingThread.resetEmptySnapshot();
        }

        @Override public void reset() {
            // USB 流跨 reset 存活，configure() 管理其生命周期（与 dec 一致）
            super.reset();
        }

        @Override public void release() {
            stopStreamingThread();
            super.release();
            liveSinks.remove(this);
        }

        @Override public void setVolume(float volume) {
            // 节流：音量值没变时不通知应用侧（ExoPlayer 初始化可能多次 setVolume 同值）
            boolean changed = volume != lastPlayerVolume;
            pendingVolume = volume;
            lastPlayerVolume = volume;
            if (changed) {
                // 通知应用侧更新 DAC 硬件音量（独占时有效；未独占时应用侧会忽略）
                UsbVolumeListener l = volumeListener;
                if (l != null) l.onPlayerVolumeChanged(volume);
            }
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                // 独占：委托静音（真实音量走 USB 流，原生按位深直写不受音量影响）
                if (!delegateMuted) {
                    super.setVolume(0f);
                    delegateMuted = true;
                }
            } else {
                // 透传：始终把音量传给委托（dec 是条件包装无此路径，本设计始终包装必须处理）
                super.setVolume(volume);
                delegateMuted = false;
            }
        }

        @Override public void playToEndOfStream() throws WriteException {
            // EOS 留痕：若停喂由 EOS 误判/提前结束引发，日志可直接确认
            logI(TAG, "playToEndOfStream (EOS)");
            handledEndOfStream = true;
            super.playToEndOfStream();
        }

        @Override public boolean isEnded() {
            boolean r = super.isEnded();
            if (exclusiveEnabled && (++posLogCount % 500 == 1L)) {
                logI(TAG, "isEnded=" + r + " hasPending(super)=" + super.hasPendingData()
                        + " hasPending(thread)=" + (streamingThread != null && streamingThread.hasPendingData()));
            }
            return r;
        }

        @Override public boolean hasPendingData() {
            if (exclusiveEnabled && streamingThread != null && streamingThread.hasPendingData()) {
                return true;
            }
            return super.hasPendingData();
        }

        /** 开关状态变化时由控制器调用。 */
        void onExclusiveChanged(boolean enabled) {
            if (enabled) {
                // 注意：不做 setPreferredDevice 强制路由 —— 那会重启 delegate AudioTrack，
                // 导致 ExoPlayer renderer 误判为播放中（暂停状态也会被喂数据 → 每秒滴答播放）。
                // DAC 已被我们 claim（force=true 断开内核驱动），AudioFlinger 的 usb HAL
                // 打开必然失败并自动 fallback，无需显式路由即可防抢占。
                muteDelegateIfNeeded();
                usbStartMediaTimeNeedsInit = true;
            } else {
                stopStreamingThread();
                unmuteDelegateIfNeeded();
            }
        }

        private void stopStreamingThread() {
            if (streamingThread != null) {
                streamingThread.stop();
                streamingThread = null;
            }
        }

        /**
         * 强制 AudioTrack 重新 start（直接转发，不走本类的 play/pause 状态逻辑）。
         * 关闭独占后 AudioTrack 曾迁移到未就绪 USB 设备 → 静默无声；重新 start
         * 让 AudioFlinger 重新路由到当前已就绪的设备。
         */
        void restartRouting() {
            try {
                super.pause();
                super.play();
                logI(TAG, "delegate AudioTrack restarted (re-route to USB)");
            } catch (Exception e) {
                logW(TAG, "restartRouting failed: " + e.getMessage());
            }
        }

        private void muteDelegateIfNeeded() {
            if (!delegateMuted) {
                super.setVolume(0f);
                delegateMuted = true;
            }
        }

        private void unmuteDelegateIfNeeded() {
            if (delegateMuted) {
                super.setVolume(pendingVolume);
                delegateMuted = false;
            }
        }
    }
}
