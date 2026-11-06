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
 * 接线（由 MainActivity 完成，本文件不修改 MainActivity）：
 * - 字段持有本类实例；
 * - `configureFlutterEngine(flutterEngine)` 中创建（channel 需要引擎的
 *   BinaryMessenger），晚于 `super.configureFlutterEngine`；
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
     * 通道名与仓库其他通道（shiyin_music/desktop_lyrics 等）同风格。
     */
    val channel: MethodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )

    /**
     * 消费一条按键事件。
     *
     * @return true 表示本类已处理（调用方应直接从 dispatchKeyEvent 返回
     * true，避免事件继续走 AudioServiceActivity/系统默认路径）；false
     * 表示不是需要兜底的媒体键，或不是首次按下（ACTION_UP、长按重复）。
     */
    fun handleKeyEvent(keyCode: Int, event: KeyEvent?): Boolean {
        val method = methodFor(keyCode) ?: return false
        if (event == null) {
            return false
        }
        val firstDown = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
        // 所有被识别的媒体键都记日志（含 ACTION_UP / 长按重复），真机排查
        // 时 adb logcat -s CarMediaKey 即可看到车机到底派发了什么：
        // 有日志但不响应 = 非首次按下；完全没日志 = 车机根本没把方控派发
        // 到前台 Activity（需查私有广播/系统媒体会话路径）。
        val action = if (firstDown) "→ $method" else "→ 忽略（非首次按下）"
        Log.i(
            TAG,
            "keyCode=$keyCode action=${event.action} repeat=${event.repeatCount} $action",
        )
        if (!firstDown || activity.isFinishing) {
            return false
        }

        dispatch(method)
        return true
    }

    /** 按键码 → Dart 播控方法名；非媒体键返回 null。 */
    private fun methodFor(keyCode: Int): String? = when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_NEXT -> METHOD_NEXT
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> METHOD_PREVIOUS
        KeyEvent.KEYCODE_MEDIA_PLAY -> METHOD_PLAY
        KeyEvent.KEYCODE_MEDIA_PAUSE -> METHOD_PAUSE
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_HEADSETHOOK -> METHOD_TOGGLE_PLAY
        KeyEvent.KEYCODE_MEDIA_STOP -> METHOD_STOP
        else -> null
    }

    /**
     * 向 Dart 派发一次播控指令。
     *
     * 用带 [MethodChannel.Result] 的重载：Dart 侧通道未注册（引擎未起、
     * 控制器已销毁）时不会产生未捕获的 MissingPluginException——对方向盘
     * 按键来说静默失败 + 日志即可，绝不冒泡影响 Activity。同步异常
     * （通道已失效等）用 runCatching 兜住。
     */
    private fun dispatch(method: String) {
        runCatching {
            channel.invokeMethod(
                method,
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = Unit
                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        Log.w(TAG, "Dart 处理 $method 失败: $errorCode $errorMessage")
                    }

                    override fun notImplemented() {
                        Log.w(TAG, "Dart 未实现 $method（媒体键通道未接线？）")
                    }
                },
            )
        }.onFailure {
            Log.w(TAG, "invokeMethod($method) 异常: ${it.message}")
        }
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

        private const val TAG = "CarMediaKey"
    }
}
