package shiyin.famlife.top

import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.MethodChannel

/** 车机媒体键统一日志 TAG：`adb logcat -s CarMediaKey` 一网打尽。 */
internal const val CAR_MEDIA_KEY_TAG = "CarMediaKey"

/**
 * 媒体键指令的进程级分发点（issue #15）。
 *
 * 两个输入源共用同一条到 Dart 的 MethodChannel
 * （[CarMediaKeyHandler] 的前台 KeyEvent 兜底、[CarMediaBroadcastReceiver]
 * 的车机私有广播兜底），这里持有「当前存活引擎」的通道引用：
 * - MainActivity.configureFlutterEngine 时由 [CarMediaKeyHandler] 挂上；
 * - 引擎销毁重建后会被新一轮 configureFlutterEngine 覆盖；
 * - 通道未挂上时静默丢弃 + 日志（App 冷启动瞬间广播先到属正常，不重试）。
 *
 * 按键码 → 方法名的映射也集中在这里，供 KeyEvent 路径与
 * MEDIA_BUTTON 广播（KeyEvent 以 extra 携带）共用，避免两份映射漂移。
 */
object MediaKeyDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    /** 未映射按键的诊断日志去重：每个 keyCode 只打一行，避免长按刷屏。 */
    private val loggedUnmappedKeyCodes = mutableSetOf<Int>()

    /** 挂上当前引擎的媒体键通道；configureFlutterEngine 每次都会调用。 */
    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    /** 按键码 → Dart 播控方法名（与 Dart 侧 MediaKeyService 一一对应）；
     * 非标准媒体键返回 null。 */
    fun methodForKeyCode(keyCode: Int): String? = when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_NEXT -> CarMediaKeyHandler.METHOD_NEXT
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> CarMediaKeyHandler.METHOD_PREVIOUS
        KeyEvent.KEYCODE_MEDIA_PLAY -> CarMediaKeyHandler.METHOD_PLAY
        KeyEvent.KEYCODE_MEDIA_PAUSE -> CarMediaKeyHandler.METHOD_PAUSE
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_HEADSETHOOK -> CarMediaKeyHandler.METHOD_TOGGLE_PLAY
        KeyEvent.KEYCODE_MEDIA_STOP -> CarMediaKeyHandler.METHOD_STOP
        else -> null
    }

    /**
     * 记录一次「到达但未映射」的按键（每个 keyCode 只记一次）。
     *
     * 部分车机把方控以厂商私有键码派发，映射表不认识时之前完全没日志，
     * 真机排查无从下手；这里把见过的键码留痕，等用户回报即可补映射。
     */
    fun logUnmappedKeyCodeOnce(keyCode: Int, source: String) {
        synchronized(loggedUnmappedKeyCodes) {
            if (!loggedUnmappedKeyCodes.add(keyCode)) {
                return
            }
        }
        Log.i(CAR_MEDIA_KEY_TAG, "[$source] 未映射按键 keyCode=$keyCode（首次出现，已记录）")
    }

    /**
     * 向 Dart 派发一次播控指令。
     *
     * 用带 [MethodChannel.Result] 的重载：Dart 侧通道未注册（引擎未起、
     * 控制器已销毁）时不会产生未捕获的 MissingPluginException——对车机
     * 媒体键来说静默失败 + 日志即可，绝不冒泡影响调用方。同步异常
     * （通道已失效等）用 runCatching 兜住。
     */
    fun dispatch(method: String) {
        val target = channel
        if (target == null) {
            Log.i(CAR_MEDIA_KEY_TAG, "通道未就绪，丢弃播控指令: $method")
            return
        }
        runCatching {
            target.invokeMethod(
                method,
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = Unit

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        Log.w(CAR_MEDIA_KEY_TAG, "Dart 处理 $method 失败: $errorCode $errorMessage")
                    }

                    override fun notImplemented() {
                        Log.w(CAR_MEDIA_KEY_TAG, "Dart 未实现 $method（媒体键通道未接线？）")
                    }
                },
            )
        }.onFailure {
            Log.w(CAR_MEDIA_KEY_TAG, "invokeMethod($method) 异常: ${it.message}")
        }
    }
}
