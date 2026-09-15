import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// 场景连接后 window.rootViewController 才可用，
  /// 此时兜底注册 AppDelegate 里的 MethodChannel（字体/背景选择器）。
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    (UIApplication.shared.delegate as? AppDelegate)?.configureChannelsIfPossible()
  }
}
