import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // FlutterImplicitEngineBridge 只暴露 pluginRegistry（没有 engine 成员），
    // 所以从 registry 取一个 registrar 拿 binaryMessenger——与 GeneratedPluginRegistrant
    // 内部注册插件走的是同一套机制。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LoudnessChannel") {
      LoudnessChannel.register(with: registrar.messenger())
    }
  }
}
