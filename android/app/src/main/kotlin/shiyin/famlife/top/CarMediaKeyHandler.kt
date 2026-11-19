package shiyin.famlife.top

import android.app.Activity
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 车机方向盘媒体键的前台兜底（issue #15）。
 *
 * 背景：audio_service 的 MediaSession 已覆盖「后台/系统媒体会话」路径
 * （通知栏、锁屏、蓝牙 AVRCP 等），但部分国产车机（如 Flyme Auto /
 * Android 11）把方向盘按键以 [KeyEvent] 直接派发给前台 Activity；
 * [MainActivity] 继承 AudioServiceActivity 且没有消费这些键，表现为
 * 方向盘的上一首/下一首/播放暂停完全没反应。
 *
 * 本类只做「Activity 前台收到标准媒体键 → 通过 MethodChannel
 * [CHANNEL_NAME] 转给 Dart 播控」这一层，不碰播放状态：短按一次
 * ACTION_DOWN（repeatCount == 0）只派发一次，ACTION_UP / 长按重复事件
 * 返回 false 交回系统，不做历史版本中「MEDIA_NEXT 长按暂停」的拦截
 * （实机验证不可靠，已移除，见提交 da94cc1）。
 *
 * 按键映射与向 Dart 的派发统一走 [MediaKeyDispatcher]：车机私有广播
 * 兜底（[CarMediaBroadcastReceiver]，issue #15 后续批次）与前台
 * KeyEvent 共用同一份映射和通道，避免两处漂移。
 *
 * 接线（由 MainActivity 完成，本文件不修改 MainActivity）：
 * - 字段持有本类实例；
 * - `configureFlutterEngine(flutterEngine)` 中创建（channel 需要引擎的
 *   BinaryMessenger），晚于 `super.configureFlutterEngine`；构造时把
 *   通道挂到 [MediaKeyDispatcher] 上；
 * - `dispatchKeyEvent(event)` 中调用 [handleKeyEvent]，返回 true 时直接
 *   返回 true 消费事件。
 */
class CarMediaKeyHandler(
    private val activity: Activity,
    flutterEngine: FlutterEngine,
) {
    /**
     * 原生 → Dart 的单向通道：原生只负责 invokeMethod，Dart 侧
     * [MethodChannel.setMethodCallHandler] 注册并分发到播放控制器。
     * 通道名与仓库其他通道（shiyin_music/desktop_lyrics 等）同风格；
     * 构造时同步挂到 [MediaKeyDispatcher]，供广播兜底复用。
     */
    val channel: MethodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )

    init {
        MediaKeyDispatcher.attach(channel)
    }

    /**
     * 消费一条按键事件。
     *
     * @return true 表示本类已处理（调用方应直接从 dispatchKeyEvent 返回
     * true，避免事件继续走 AudioServiceActivity/系统默认路径）；false
     * 表示不是需要兜底的媒体键，或不是首次按下（ACTION_UP、长按重复）。
     */
    fun handleKeyEvent(keyCode: Int, event: KeyEvent?): Boolean {
        val method = MediaKeyDispatcher.methodForKeyCode(keyCode)
        if (event == null) {
            return false
        }
        if (method == null) {
            // 部分车机用厂商私有键码派发方控：映射表不认识也要留痕（每个
            // keyCode 只记一次），否则真机排查时完全没日志，无从补映射。
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                MediaKeyDispatcher.logUnmappedKeyCodeOnce(keyCode, "前台KeyEvent")
            }
            return false
        }
        val firstDown = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
        // 所有被识别的媒体键都记日志（含 ACTION_UP / 长按重复），真机排查
        // 时 adb logcat -s CarMediaKey 即可看到车机到底派发了什么：
        // 有日志但不响应 = 非首次按下；完全没日志 = 车机根本没把方控派发
        // 到前台 Activity（走私有广播/媒体中心，见 CarMediaBroadcastReceiver
        // 与 mediacenter 包）。
        val action = if (firstDown) "→ $method" else "→ 忽略（非首次按下）"
        Log.i(
            CAR_MEDIA_KEY_TAG,
            "keyCode=$keyCode action=${event.action} repeat=${event.repeatCount} $action",
        )
        if (!firstDown || activity.isFinishing) {
            return false
        }

        MediaKeyDispatcher.dispatch(method)
        return true
    }

    companion object {
        /** 与 Dart 侧 MediaKeyService.channelName 必须保持一致。 */
        const val CHANNEL_NAME = "shiyin_music/media_key"

        const val METHOD_TOGGLE_PLAY = "togglePlay"
        const val METHOD_PLAY = "play"
        const val METHOD_PAUSE = "pause"
        const val METHOD_NEXT = "next"
        const val METHOD_PREVIOUS = "previous"
        const val METHOD_STOP = "stop"
    }
}
