package shiyin.famlife.top.mediacenter

import android.util.Log

/**
 * 媒体中心集成的统一日志（issue #15）。
 *
 * 双通道留痕：
 * 1. `adb logcat -s CarMediaCenter`；
 * 2. 环形缓冲（默认 200 行）经 [CarMediaCenterBridge] 的 onLog 尽力转发
 *    给 Dart 落盘（AppLogService）——issue 用户的车机 USB adb 被封堵，
 *    唯一可行的是在应用内导出日志，这里就是那条路。
 *
 * 转发是 fire-and-forget：Dart 侧通道未挂上/异常都只吞掉，绝不影响
 * Binder 回调线程。
 */
object CarMediaCenterLog {
    const val TAG = "CarMediaCenter"

    private const val RING_SIZE = 200
    private val ring = arrayOfNulls<String>(RING_SIZE)
    private var ringPos = 0

    /** 日志转发钩子（由 Bridge 挂上；null 时只落 logcat + 环形缓冲）。 */
    @Volatile
    var forwarder: ((String) -> Unit)? = null

    fun log(message: String) {
        runCatching { Log.i(TAG, message) }
        val line = "${System.currentTimeMillis()}  $message"
        synchronized(ring) {
            ring[ringPos % RING_SIZE] = line
            ringPos++
        }
        runCatching { forwarder?.invoke(line) }
    }

    /** 环形缓冲快照（Dart getDiagnostics 用，时间顺序）。 */
    fun dump(): List<String> = synchronized(ring) {
        val start = if (ringPos < RING_SIZE) 0 else ringPos - RING_SIZE
        (start until ringPos).mapNotNull { ring[it % RING_SIZE] }
    }
}
