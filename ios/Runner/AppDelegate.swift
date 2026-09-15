import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers

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

    channelsConfigured = true
    NSLog("[MD3Music] picker MethodChannels registered on FlutterViewController")
  }

  /// 通过 connectedScenes 找 keyWindow 的根 FlutterViewController
  private func findFlutterViewController() -> FlutterViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    for window in windows {
      if let root = window.rootViewController as? FlutterViewController {
        return root
      }
      // 根不是（例如被导航/容器包住）时向下找一层
      for child in root?.children ?? [] {
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
      let dst = dir.appendingPathComponent("user_custom.\(ext)")
      if FileManager.default.fileExists(atPath: dst.path) {
        try FileManager.default.removeItem(at: dst)
      }
      try FileManager.default.copyItem(at: src, to: dst)
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
        let dst = dir.appendingPathComponent("background.jpg")
        if FileManager.default.fileExists(atPath: dst.path) {
          try FileManager.default.removeItem(at: dst)
        }
        guard let data = image.jpegData(compressionQuality: 0.95) else {
          DispatchQueue.main.async {
            self.pendingResult = nil
            result(nil)
          }
          return
        }
        try data.write(to: dst)
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
