package shiyin.famlife.top

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.KeyEvent

/**
 * 车机私有媒体广播兜底（issue #15）。
 *
 * 背景：v3.0.18 的前台 KeyEvent 兜底对 Flyme Auto 无效（方控根本不派
 * KeyEvent）；而不少国产车机/方向盘 CAN 桥接固件用的是 AOSP 原生音乐
 * （com.android.music）遗留的「服务命令广播」事实标准——很多改装车机、
 * 方控盒子的切歌指令至今仍以它下发。另外 Manifest 静态注册的
 * ACTION_MEDIA_BUTTON receiver 在 targetSdk 26+ 收不到隐式广播
 * （不在 Android 8+ 隐式广播豁免清单），部分固件直接广播 MEDIA_BUTTON
 * 给所有应用，这里用运行时注册补上。
 *
 * 接收两类广播（由 [MusicApplication] 进程级运行时注册，App 存活期间
 * 一直有效，前台/后台都能收到）：
 * 1. `com.android.music.musicservicecommand` 及其带动作后缀的变体
 *    （.next/.previous/.togglepause/.pause/.play）：命令经 extra
 *    `"command"`（next/previous/togglepause/pause/play/stop）或动作
 *    后缀携带；
 * 2. `android.intent.action.MEDIA_BUTTON`：KeyEvent 经
 *    [Intent.EXTRA_KEY_EVENT] 携带，只响应首次 ACTION_DOWN。
 *
 * 两条路都汇入 [MediaKeyDispatcher] → 与前台 KeyEvent 兜底同一条
 * `shiyin_music/media_key` 通道，Dart 侧接线零改动。
 */
class CarMediaBroadcastReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_MEDIA_BUTTON -> handleMediaButton(intent)
            else -> handleServiceCommand(intent)
        }
    }

    /** MEDIA_BUTTON 广播：KeyEvent 在 extra 里，映射逻辑与前台兜底共用。 */
    private fun handleMediaButton(intent: Intent) {
        val event = intent.getParcelableExtraCompat(KeyEvent::class.java, Intent.EXTRA_KEY_EVENT)
        if (event == null) {
            Log.i(CAR_MEDIA_KEY_TAG, "[广播] MEDIA_BUTTON 无 KeyEvent extra，忽略")
            return
        }
        val method = MediaKeyDispatcher.methodForKeyCode(event.keyCode)
        if (method == null) {
            MediaKeyDispatcher.logUnmappedKeyCodeOnce(event.keyCode, "广播MEDIA_BUTTON")
            return
        }
        val firstDown = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
        Log.i(
            CAR_MEDIA_KEY_TAG,
            "[广播] MEDIA_BUTTON keyCode=${event.keyCode} action=${event.action} " +
                "repeat=${event.repeatCount} ${if (firstDown) "→ $method" else "→ 忽略（非首次按下）"}",
        )
        if (firstDown) {
            MediaKeyDispatcher.dispatch(method)
        }
    }

    /** musicservicecommand 及其变体：动作后缀优先，其次 command extra。 */
    private fun handleServiceCommand(intent: Intent) {
        val action = intent.action.orEmpty()
        val method = methodForAction(action)
            ?: intent.getStringExtra(EXTRA_COMMAND)?.let(::methodForCommand)
        if (method == null) {
            // 命令取不到也留一行日志：车机固件若用了别的 extra 名，靠它发现。
            Log.i(
                CAR_MEDIA_KEY_TAG,
                "[广播] musicservicecommand 无法识别 action=$action command=" +
                    "${intent.getStringExtra(EXTRA_COMMAND)}（忽略）",
            )
            return
        }
        Log.i(CAR_MEDIA_KEY_TAG, "[广播] musicservicecommand action=$action → $method")
        MediaKeyDispatcher.dispatch(method)
    }

    /** 动作后缀变体（com.android.music.musicservicecommand.next 等）。 */
    private fun methodForAction(action: String): String? = when {
        action == ACTION_COMMAND_NEXT -> CarMediaKeyHandler.METHOD_NEXT
        action == ACTION_COMMAND_PREVIOUS -> CarMediaKeyHandler.METHOD_PREVIOUS
        action == ACTION_COMMAND_TOGGLE_PAUSE -> CarMediaKeyHandler.METHOD_TOGGLE_PLAY
        action == ACTION_COMMAND_PAUSE -> CarMediaKeyHandler.METHOD_PAUSE
        action == ACTION_COMMAND_PLAY -> CarMediaKeyHandler.METHOD_PLAY
        else -> null
    }

    /** AOSP 原生音乐定义的 command extra 取值。 */
    private fun methodForCommand(command: String): String? = when (command) {
        COMMAND_NEXT -> CarMediaKeyHandler.METHOD_NEXT
        COMMAND_PREVIOUS -> CarMediaKeyHandler.METHOD_PREVIOUS
        COMMAND_TOGGLE_PAUSE -> CarMediaKeyHandler.METHOD_TOGGLE_PLAY
        COMMAND_PAUSE -> CarMediaKeyHandler.METHOD_PAUSE
        COMMAND_PLAY -> CarMediaKeyHandler.METHOD_PLAY
        COMMAND_STOP -> CarMediaKeyHandler.METHOD_STOP
        else -> null
    }

    /** [getParcelableExtra] 的 API 33 前后兼容封装。 */
    private fun <T : android.os.Parcelable> Intent.getParcelableExtraCompat(
        clazz: Class<T>,
        name: String,
    ): T? =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(name, clazz)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(name)
        }

    companion object {
        /** AOSP com.android.music 的服务命令 action（命令在 extra "command" 里）。 */
        const val ACTION_SERVICE_COMMAND = "com.android.music.musicservicecommand"

        // 带动作后缀的变体：部分固件按整条 action 下发而不是用 extra。
        private const val ACTION_COMMAND_NEXT = "$ACTION_SERVICE_COMMAND.next"
        private const val ACTION_COMMAND_PREVIOUS = "$ACTION_SERVICE_COMMAND.previous"
        private const val ACTION_COMMAND_TOGGLE_PAUSE = "$ACTION_SERVICE_COMMAND.togglepause"
        private const val ACTION_COMMAND_PAUSE = "$ACTION_SERVICE_COMMAND.pause"
        private const val ACTION_COMMAND_PLAY = "$ACTION_SERVICE_COMMAND.play"

        private const val EXTRA_COMMAND = "command"

        // AOSP MediaPlaybackService 的命令取值。
        private const val COMMAND_NEXT = "next"
        private const val COMMAND_PREVIOUS = "previous"
        private const val COMMAND_TOGGLE_PAUSE = "togglepause"
        private const val COMMAND_PAUSE = "pause"
        private const val COMMAND_PLAY = "play"
        private const val COMMAND_STOP = "stop"
    }
}
