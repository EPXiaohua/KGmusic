import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import MediaPlayer
import AVFoundation
import AVKit
import CoreMedia

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
    UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
  /// 待回复的 FlutterResult（两个选择器互斥，同一时间只允许一个）
  private var pendingResult: FlutterResult?
  private var channelsConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureChannelsIfPossible()
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    configureChannelsIfPossible()
  }

  // MARK: - MethodChannel 注册

  /// Android 端由 MainActivity.kt 实现同名 channel；iOS 在此补齐。
  ///
  /// 注意：场景化生命周期下 AppDelegate.window 为 nil（窗口归 SceneDelegate 所有），
  /// 因此查找 FlutterViewController 必须走 connectedScenes -> keyWindow。
  /// didFinishLaunching / 引擎初始化 / SceneDelegate 连接三处都会尝试注册（幂等）。
  func configureChannelsIfPossible() {
    guard !channelsConfigured else { return }
    guard let vc = findFlutterViewController() else { return }
    let messenger = vc.binaryMessenger

    FlutterMethodChannel(name: "com.md3music.md3music/font_picker", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pickFontFile" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pickFontFile(result: result)
      }

    FlutterMethodChannel(name: "com.md3music.md3music/background_picker", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pickBackgroundImage" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pickBackgroundImage(result: result)
      }

    // iOS 锁屏/控制中心 Now Playing 信息与远程命令。
    // Android 的锁屏/通知由 Media3 MediaSession 负责，不经过此 channel，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    NowPlayingManager.shared.attach(messenger: messenger)

    // iOS 歌词悬浮窗（系统画中画）。Android 悬浮歌词走 FloatingLyricService，
    // 本 channel 仅在 iOS Runner 内注册，互不影响。
    LyricsPipManager.shared.attach(messenger: messenger)

    channelsConfigured = true
    NSLog("[MD3Music] picker MethodChannels registered on FlutterViewController")
  }

  /// 通过 connectedScenes 找 keyWindow 的根 FlutterViewController
  private func findFlutterViewController() -> FlutterViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    for window in windows {
      guard let root = window.rootViewController else { continue }
      if let vc = root as? FlutterViewController {
        return vc
      }
      // 根不是（例如被导航/容器包住）时向下找一层
      for child in root.children {
        if let vc = child as? FlutterViewController {
          return vc
        }
      }
    }
    return nil
  }

  /// 当前可用于 present 的最顶层控制器
  private var presenter: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var base = windows.first { $0.isKeyWindow }?.rootViewController
      ?? windows.first?.rootViewController
    while let presented = base?.presentedViewController {
      base = presented
    }
    return base
  }

  // MARK: - 字体文件选择（对齐 Android SAF：拷贝到 Documents/fonts/ 后返回路径）

  private func pickFontFile(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(nil)  // 已有选择器在运行，直接视为取消
      return
    }
    guard let presenter = presenter else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "无法获取展示控制器", details: nil))
      return
    }
    pendingResult = result
    // UTType 没有字体静态成员，用标准 UTI 构造：ttf / otf / 通用字体
    let fontTypes = [
      UTType("public.truetype-ttf"),
      UTType("public.opentype-font"),
      UTType("public.font"),
    ].compactMap { $0 }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: fontTypes, asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    guard let src = urls.first else {
      result(nil)
      return
    }
    do {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("fonts", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let ext = src.pathExtension.isEmpty ? "ttf" : src.pathExtension
      // 关键：时间戳唯一命名（对齐背景图 bg_<ts> 实现）。固定文件名 user_custom.ttf
      // 会让 Dart 端 setCustomFontPath 判定路径未变化而跳过重新加载，第二次换字体不生效。
      let name = "font_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
      let dst = dir.appendingPathComponent(name)
      try FileManager.default.copyItem(at: src, to: dst)
      // 清理旧字体文件，只保留刚拷贝的一份。
      // 注意：必须用 lastPathComponent（文件名）比较，contentsOfDirectory 返回的
      // 路径拼写（/private 前缀等）与 dst.path 可能不同，整条路径比较会把
      // 刚写入的文件误判为旧文件删除掉。
      if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for old in files where old.isFileURL
            && old.lastPathComponent != dst.lastPathComponent
            && (old.lastPathComponent.hasPrefix("font_") || old.lastPathComponent.hasPrefix("user_custom")) {
          try? FileManager.default.removeItem(at: old)
        }
      }
      result(dst.path)
    } catch {
      result(FlutterError(code: "FONT_COPY_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    result(nil)
  }

  // MARK: - 背景图片选择（对齐 Android SAF：拷贝到 Documents/background/ 后返回路径）

  private func pickBackgroundImage(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(nil)
      return
    }
    guard let presenter = presenter else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "无法获取展示控制器", details: nil))
      return
    }
    pendingResult = result
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pendingResult else { return }
    guard let provider = results.first?.itemProvider,
          provider.canLoadObject(ofClass: UIImage.self) else {
      pendingResult = nil
      result(nil)
      return
    }
    // loadObject 回调在任意队列，FlutterResult 必须回主线程
    provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
      guard let self = self else { return }
      guard let image = obj as? UIImage else {
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(nil)
        }
        return
      }
      do {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("background", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 关键：时间戳唯一命名（对齐 Android 端 bg_<ts> 实现）。
        // 固定文件名会让 Flutter Image.file 按路径命中旧缓存，更换图片后仍显示第一张。
        let name = "bg_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let dst = dir.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.95) else {
          DispatchQueue.main.async {
            self.pendingResult = nil
            result(nil)
          }
          return
        }
        try data.write(to: dst)
        // 写入成功后清理旧背景文件，避免累积（只保留刚写的一份）。
        // 同字体清理：必须用文件名比较，整条路径比较会误删刚写入的文件。
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
          for old in files where old.isFileURL
              && old.lastPathComponent != dst.lastPathComponent
              && (old.lastPathComponent.hasPrefix("bg_") || old.lastPathComponent == "background.jpg") {
            try? FileManager.default.removeItem(at: old)
          }
        }
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(dst.path)
        }
      } catch {
        DispatchQueue.main.async {
          self.pendingResult = nil
          result(FlutterError(code: "BG_COPY_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

// MARK: - iOS 锁屏/控制中心 Now Playing

/// iOS 锁屏/控制中心 Now Playing 信息与远程命令桥接。
///
/// 与 Android 的 Media3 通知路径互不影响：本类只在 iOS Runner 内编译，
/// channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/now_playing_service.dart。
final class NowPlayingManager {
  static let shared = NowPlayingManager()

  private var channel: FlutterMethodChannel?
  /// 当前倍速对应的 rate（暂停时必须为 0，否则锁屏进度条按墙钟自己走）
  private var currentRate: Double = 0
  /// 已应用到锁屏的封面 URI：同曲重复刷新（通知重建/收藏变化等）不重复下载
  private var appliedArtUri: String?
  /// 封面下载请求序号：快速切歌时旧请求返回后按序号丢弃，避免串歌封面
  private var artworkRequestId = 0

  private init() {}

  /// 注册 MethodChannel 与远程命令（幂等）。attach 与命令回调均保证在主线程。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "com.md3music/now_playing", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    registerRemoteCommands()
    NSLog("[MD3Music] now_playing channel registered")
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setMetadata":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      setMetadata(args)
      result(nil)
    case "updatePlayback":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      updatePlayback(args)
      result(nil)
    case "clear":
      clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 元数据（标题/歌手/专辑/时长 + 封面异步下载）

  private func setMetadata(_ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // 增量更新：保留封面等已有字段，不重建整个 dict
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      let newTitle = args["title"] as? String
      let oldTitle = info[MPMediaItemPropertyTitle] as? String
      // 仅切歌（标题变化）时进度归零；同曲刷新（暂停/收藏/封面覆盖路径等
      // 重建通知）保留进度，避免把锁屏进度打回 0。
      let isTrackChange = newTitle != nil && newTitle != oldTitle
      if let title = newTitle, !title.isEmpty {
        info[MPMediaItemPropertyTitle] = title
      }
      if let artist = args["artist"] as? String {
        info[MPMediaItemPropertyArtist] = artist
      }
      if let album = args["album"] as? String {
        info[MPMediaItemPropertyAlbumTitle] = album
      }
      if let durationMs = (args["duration"] as? NSNumber)?.doubleValue, durationMs > 0 {
        info[MPMediaItemPropertyPlaybackDuration] = durationMs / 1000.0
      }
      if isTrackChange {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = self.currentRate
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      self.loadArtwork(args["artUri"] as? String)
    }
  }

  /// 异步取封面：http/https/file 均由 URLSession 支持（Info.plist 已放行 ATS）。
  /// 成功构造 MPMediaItemArtwork（handler 返回对应尺寸 UIImage）后重新刷新
  /// nowPlayingInfo；失败静默跳过（锁屏仍显示文字）。
  private func loadArtwork(_ artUri: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let uri = artUri, uri == self.appliedArtUri { return }
      self.appliedArtUri = artUri
      self.artworkRequestId += 1
      let requestId = self.artworkRequestId
      guard let uri = artUri, !uri.isEmpty, let url = URL(string: uri) else {
        self.removeArtwork()
        return
      }
      URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let self = self else { return }
        DispatchQueue.main.async {
          // 已切歌：丢弃过期封面
          guard requestId == self.artworkRequestId else { return }
          guard let data = data, let image = UIImage(data: data) else { return }
          let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
          var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
          info[MPMediaItemPropertyArtwork] = artwork
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
      }.resume()
    }
  }

  private func removeArtwork() {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyArtwork] = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  // MARK: 播放进度/状态

  private func updatePlayback(_ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let positionMs = (args["position"] as? NSNumber)?.doubleValue ?? 0
      let playing = args["playing"] as? Bool ?? false
      let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0
      // 暂停时 rate=0：锁屏进度条停止走动
      let rate: Double = playing ? (speed > 0 ? speed : 1.0) : 0
      self.currentRate = rate
      // 增量更新：保持标题/封面字段
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionMs / 1000.0
      info[MPNowPlayingInfoPropertyPlaybackRate] = rate
      info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = 0
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
  }

  private func clear() {
    DispatchQueue.main.async { [weak self] in
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      self?.appliedArtUri = nil
      self?.currentRate = 0
      self?.artworkRequestId += 1
    }
  }

  // MARK: 远程命令（锁屏/控制中心/耳机线控）→ Flutter

  private func registerRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.sendCommand("toggle")
      return .success
    }
    center.playCommand.addTarget { [weak self] _ in
      self?.sendCommand("play")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.sendCommand("pause")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.sendCommand("next")
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.sendCommand("previous")
      return .success
    }
    // 控制中心进度条拖动
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.sendCommand("seek", positionMs: Int(event.positionTime * 1000))
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = true
    center.changePlaybackPositionCommand.isEnabled = true
  }

  /// 命令回传 Dart：invokeMethod("command", {'action': ..., 'position': <ms>}).
  private func sendCommand(_ action: String, positionMs: Int? = nil) {
    DispatchQueue.main.async { [weak self] in
      var args: [String: Any] = ["action": action]
      if let positionMs = positionMs {
        args["position"] = positionMs
      }
      self?.channel?.invokeMethod("command", arguments: args)
    }
  }
}

// MARK: - iOS 歌词悬浮窗（Picture-in-Picture + AVSampleBufferDisplayLayer）

/// iOS 歌词悬浮窗桥接：把滚动歌词渲染进系统 PiP 窗口（类似 Android 悬浮歌词）。
///
/// 与 Android 的 FloatingLyricService 悬浮窗路径互不影响：本类只在 iOS Runner
/// 内编译，channel 也只由 iOS 端注册。Dart 端对应 lib/core/services/lyrics_pip_service.dart。
///
/// 渲染为事件驱动：进度/播放状态由 Dart 节流推送，仅行切换（或播放状态翻转 /
/// 歌词整包更新）时重绘一帧并 enqueue，低帧率省电。
final class LyricsPipManager: NSObject {
  static let shared = LyricsPipManager()

  private var channel: FlutterMethodChannel?
  /// 按时间升序的歌词行（start 毫秒，绝对时间）
  private var lines: [(start: Int, duration: Int, text: String, translation: String?)] = []
  /// 最近一次 Dart 推送的播放进度（毫秒）与播放状态
  private var positionMs: Double = 0
  private var playing = false
  /// 当前已渲染的行下标（-1 = 行前空白/无行）
  private var renderedLineIndex = -1
  /// 强制下一帧重绘（setLyrics / start / 播放状态翻转时置位）
  private var frameDirty = false
  private var pipController: AVPictureInPictureController?
  private var displayLayer: AVSampleBufferDisplayLayer?
  /// 持有 playbackDelegate 强引用（controller.delegate 为弱引用）
  private var playbackDelegateHolder: AnyObject?

  private override init() {}

  /// 注册 MethodChannel（幂等）。attach 与各方法均保证在主线程执行。
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "com.md3music/lyrics_pip", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
    NSLog("[MD3Music] lyrics_pip channel registered")
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "gone", message: "LyricsPipManager deallocated", details: nil))
        return
      }
      switch call.method {
      case "start":
        self.start(result: result)
      case "stop":
        if #available(iOS 15.0, *) {
          self.pipController?.stopPictureInPicture()
        }
        result(nil)
      case "setLyrics":
        if let args = call.arguments as? [String: Any] {
          self.setLyrics(args)
        }
        result(nil)
      case "update":
        if let args = call.arguments as? [String: Any] {
          self.update(
            positionMs: (args["position"] as? NSNumber)?.doubleValue ?? 0,
            playing: args["playing"] as? Bool ?? false)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: setLyrics（整包歌词下发）

  private func setLyrics(_ args: [String: Any]) {
    var parsed: [(start: Int, duration: Int, text: String, translation: String?)] = []
    if let rawLines = args["lines"] as? [[String: Any]] {
      for raw in rawLines {
        let start = (raw["start"] as? NSNumber)?.intValue ?? 0
        let duration = (raw["duration"] as? NSNumber)?.intValue ?? 0
        let text = raw["text"] as? String ?? ""
        let translation = raw["translation"] as? String
        parsed.append((start, duration, text, (translation?.isEmpty ?? true) ? nil : translation))
      }
    }
    parsed.sort { $0.start < $1.start }
    lines = parsed
    frameDirty = true
    maybeRenderFrame()
  }

  // MARK: update（进度/播放状态推进）

  private func update(positionMs: Double, playing: Bool) {
    self.positionMs = positionMs
    if self.playing != playing {
      self.playing = playing
      frameDirty = true
    }
    maybeRenderFrame()
  }

  /// 二分查找 position 所在行（最后一个 start <= position 的行；行前空白为 -1）
  private func currentLineIndex() -> Int {
    guard !lines.isEmpty else { return -1 }
    var lo = 0
    var hi = lines.count - 1
    var ans = -1
    let position = Int(positionMs)
    while lo <= hi {
      let mid = (lo + hi) / 2
      if lines[mid].start <= position {
        ans = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    return ans
  }

  private func maybeRenderFrame() {
    guard #available(iOS 15.0, *) else { return }
    guard let layer = displayLayer, pipController != nil else { return }
    let target = currentLineIndex()
    guard target != renderedLineIndex || frameDirty else { return }
    renderedLineIndex = target
    frameDirty = false
    renderFrame(layer: layer)
  }

  // MARK: start / stop

  private func start(result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(FlutterError(
        code: "unsupported",
        message: "Picture-in-Picture requires iOS 15+",
        details: nil))
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(
        code: "unsupported",
        message: "Picture-in-Picture is not supported on this device",
        details: nil))
      return
    }
    if pipController == nil {
      let layer = AVSampleBufferDisplayLayer()
      // 16:9 帧尺寸；背景交给每帧自绘的半透明黑，layer 本底透明
      layer.bounds = CGRect(x: 0, y: 0, width: 720, height: 405)
      layer.backgroundColor = UIColor(white: 0, alpha: 0).cgColor
      let delegate = PipPlaybackDelegate()
      delegate.isPlaying = { [weak self] in self?.playing ?? false }
      // PiP 窗口播放/暂停按钮 → 回传 Dart 切换播放（Dart 播完经 update 回流状态）
      delegate.onSetPlaying = { [weak self] value in
        self?.playing = value
        self?.frameDirty = true
        self?.channel?.invokeMethod(
          "command", arguments: ["action": "pipPlayPause", "playing": value])
      }
      delegate.onStarted = { [weak self] in self?.notifyState(active: true) }
      delegate.onStopped = { [weak self] in self?.notifyState(active: false) }
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer,
        playbackDelegate: delegate)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = delegate
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      displayLayer = layer
      playbackDelegateHolder = delegate
      pipController = controller
    }
    // 启动时强制渲染首帧（用最近一次推送的进度），让窗口出现即有内容
    frameDirty = true
    maybeRenderFrame()
    pipController?.startPictureInPicture()
    NSLog("[MD3Music] lyrics pip start requested")
    result(true)
  }

  private func notifyState(active: Bool) {
    channel?.invokeMethod("state", arguments: ["active": active])
  }

  // MARK: 渲染（720x405 BGRA，半透明黑底 + 当前句大字 + 副行小字 + 顶部进度条）

  private func renderFrame(layer: AVSampleBufferDisplayLayer) {
    let width = 720
    let height = 405
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
    guard let ctx = CGContext(
      data: base,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }

    drawLyrics(context: ctx, width: CGFloat(width), height: CGFloat(height))

    var formatDesc: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescriptionOut: &formatDesc) == noErr,
      let format = formatDesc else { return }
    guard let sb = makeSampleBuffer(pixelBuffer: pb, formatDescription: format) else { return }

    layer.enqueue(sb)
    if layer.status == .failed {
      // 偶发渲染失败：flush 一次后重建 sample 重试一次
      layer.flush()
      if let retry = makeSampleBuffer(pixelBuffer: pb, formatDescription: format) {
        layer.enqueue(retry)
      }
    }
  }

  private func makeSampleBuffer(
    pixelBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription
  ) -> CMSampleBuffer? {
    // timing 用 hostTime 即时呈现
    let hostTime = CMClock.hostTimeClock.time
    var timing = CMSampleTimingInfo(
      duration: CMTime.invalid,
      presentationTimeStamp: hostTime,
      decodeTimeStamp: CMTime.invalid)
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer)
    guard status == noErr else { return nil }
    return sampleBuffer
  }

  /// 绘制一帧。注意：raw CGBitmapContext 默认 y 轴向上，先翻转成 UIKit 的
  /// 左上原点坐标系，文本/填充才能按常规 UIKit 语义绘制（否则整帧上下颠倒）。
  private func drawLyrics(context ctx: CGContext, width: CGFloat, height: CGFloat) {
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1.0, y: -1.0)
    UIGraphicsPushContext(ctx)
    defer { UIGraphicsPopContext() }

    // 半透明黑背景
    ctx.setFillColor(UIColor(white: 0.0, alpha: 0.75).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // 顶部细进度条（进度 = position / 最后一行结束时间）
    var progress: Double = 0
    if let last = lines.last {
      let totalMs = Double(max(last.start + last.duration, 1))
      progress = min(max(positionMs / totalMs, 0), 1)
    }
    let barHeight: CGFloat = 5
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
    ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(progress) * width, height: barHeight))

    let idx = renderedLineIndex
    guard lines.indices.contains(idx) else { return }

    let horizontalPadding: CGFloat = 48
    let maxTextWidth = width - horizontalPadding * 2
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping

    let line = lines[idx]

    // 当前句：白色粗体大字，长句自动缩字号且最多 2 行
    var fontSize: CGFloat = 44
    var currentAttrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
      .foregroundColor: UIColor.white,
      .paragraphStyle: paragraph,
    ]
    var current = NSAttributedString(string: line.text, attributes: currentAttrs)
    while fontSize > 22 {
      let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
      let measured = current.boundingRect(
        with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil)
      if measured.height <= font.lineHeight * 2.1 { break }
      fontSize -= 4
      currentAttrs[.font] = UIFont.systemFont(ofSize: fontSize, weight: .bold)
      current = NSAttributedString(string: line.text, attributes: currentAttrs)
    }
    let currentMeasured = current.boundingRect(
      with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil)
    let currentHeight = ceil(currentMeasured.height)

    // 副行：优先当前句翻译，否则下一句正文；灰色小字限 1 行
    var secondaryText = line.translation
    if (secondaryText ?? "").isEmpty, idx + 1 < lines.count {
      secondaryText = lines[idx + 1].text
    }
    var secondary: NSAttributedString?
    if let text = secondaryText, !text.isEmpty {
      var ssize: CGFloat = 24
      var sattrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: ssize, weight: .medium),
        .foregroundColor: UIColor.white.withAlphaComponent(0.6),
        .paragraphStyle: paragraph,
      ]
      var sattr = NSAttributedString(string: text, attributes: sattrs)
      while ssize > 14 {
        let sfont = UIFont.systemFont(ofSize: ssize, weight: .medium)
        let m = sattr.boundingRect(
          with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading],
          context: nil)
        if m.height <= sfont.lineHeight * 1.15 { break }
        ssize -= 2
        sattrs[.font] = UIFont.systemFont(ofSize: ssize, weight: .medium)
        sattr = NSAttributedString(string: text, attributes: sattrs)
      }
      secondary = sattr
    }
    var secondaryHeight: CGFloat = 0
    if let s = secondary {
      let m = s.boundingRect(
        with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil)
      secondaryHeight = ceil(m.height)
    }

    // 垂直居中排布：当前句 + 副行
    let gap: CGFloat = secondary != nil ? 18 : 0
    let blockHeight = currentHeight + gap + secondaryHeight
    var y = (height - blockHeight) / 2
    current.draw(
      with: CGRect(x: horizontalPadding, y: y, width: maxTextWidth, height: currentHeight),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil)
    if let s = secondary {
      y += currentHeight + gap
      s.draw(
        with: CGRect(x: horizontalPadding, y: y, width: maxTextWidth, height: secondaryHeight),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil)
    }
  }
}

/// iOS 15+ PiP sample-buffer 播放代理：转发系统播放控制到 LyricsPipManager。
@available(iOS 15.0, *)
private final class PipPlaybackDelegate: NSObject,
    AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  var isPlaying: () -> Bool = { false }
  /// PiP 窗口播放/暂停按钮 → 回传 Dart
  var onSetPlaying: (Bool) -> Void = { _ in }
  var onStarted: () -> Void = {}
  var onStopped: () -> Void = {}

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    onSetPlaying(playing)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // 歌词悬浮窗不支持快进/快退
    completionHandler()
  }

  func pictureInPictureControllerTimeRange(
    _ pictureInPictureController: AVPictureInPictureController,
    didChange timeRange: CMTimeRange
  ) {
    // 歌词进度由 Dart 端 update 推送，忽略系统 timeRange 事件
  }

  func pictureInPictureControllerDidStart(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStarted()
  }

  func pictureInPictureControllerDidStop(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStopped()
  }
}
