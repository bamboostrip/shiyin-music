package shiyin.famlife.top

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * 听歌识曲麦克风采集(通道 shiyin_music/audio_capture 的原生实现)。
 *
 * 与桌面端 Rust cpal 采集对齐的 PCM 契约:8000Hz / 16bit / 单声道。
 * 8000Hz 由 AudioRecord 原生重采样,无需rubato——这也是 Android 不走
 * Rust 采集的原因:权限弹窗与音频焦点在原生侧更自然,且省一次重采样。
 *
 * start 后台线程持续读 AudioRecord 进有界缓冲(最多 MAX_BUFFER_MS),
 * stop 取末尾 durationMs 毫秒字节返回并释放。取消语义对齐响度分析:
 * cancel 直接丢弃,不返回数据。
 *
 * 线程模型:一次 start 对应一个 [Session](独享 AudioRecord + reader 线程 +
 * 存活标记)。release 顺序必须是「标记失效 → stop 让阻塞中的 read 尽快返回
 * → join 等 reader 线程退出 → release」——AudioRecord 官方文档明确:
 * 另一线程 read 进行中时直接 release() 属未定义行为(可原生崩溃);
 * 共享全局 reading 标记的旧实现里,新一轮 start 把标记翻回 true 还会让
 * 旧 reader 线程复活、把旧设备的数据混进新会话缓冲。
 */
internal object AudioCaptureHandler {
    private const val SAMPLE_RATE = 8000
    private const val MAX_BUFFER_MS = 15_000
    /** 16bit 单声道每毫秒字节数 */
    private const val BYTES_PER_MS = SAMPLE_RATE * 2 / 1000
    private const val PERMISSION_CODE = 4101

    /** 单次采集会话:独享录音实例、reader 线程与存活标记。 */
    private class Session(val record: AudioRecord) {
        val alive = AtomicBoolean(true)
        lateinit var thread: Thread
    }

    @Volatile private var session: Session? = null
    private val buffer = ArrayDeque<ByteArray>()
    private var bufferedBytes = 0
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result, activity: MainActivity) {
        when (call.method) {
            "requestPermission" -> requestPermission(result, activity)
            "start" -> start(result, activity)
            "stop" -> {
                val durationMs = call.argument<Int>("durationMs") ?: 10_000
                result.success(stop(durationMs))
            }
            "cancel" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_CODE) return
        pendingPermissionResult?.let { result ->
            mainHandler.post {
                result.success(
                    grantResults.isNotEmpty() &&
                        grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
                )
            }
        }
        pendingPermissionResult = null
    }

    private fun requestPermission(result: MethodChannel.Result, activity: MainActivity) {
        if (activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // 新请求顶掉尚未应答的旧请求时,旧 result 必须以错误收尾,
        // 否则 Dart 侧第一个调用者的 Future 永远悬挂。
        pendingPermissionResult?.error("permission", "已被新的权限请求取代", null)
        pendingPermissionResult = result
        androidx.core.app.ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.RECORD_AUDIO),
            PERMISSION_CODE,
        )
    }

    @SuppressLint("MissingPermission") // start 只在权限授予后被调用
    private fun start(result: MethodChannel.Result, activity: MainActivity) {
        if (activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission", "缺少麦克风权限,请先 requestPermission", null)
            return
        }
        release()
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, 8192)
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            result.error("init", "AudioRecord 初始化失败", null)
            return
        }
        synchronized(buffer) { buffer.clear(); bufferedBytes = 0 }
        val s = Session(rec)
        session = s
        rec.startRecording()
        s.thread = thread(name = "identify-capture") {
            val chunk = ByteArray(BYTES_PER_MS * 200) // 200ms 一块
            // 循环条件绑定本会话的存活标记(而非共享全局标记):
            // 旧会话失效后即使标记被新会话复用也不会复活。
            while (s.alive.get()) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n <= 0) break
                synchronized(buffer) {
                    buffer.addLast(chunk.copyOf(n))
                    bufferedBytes += n
                    val cap = BYTES_PER_MS * MAX_BUFFER_MS
                    while (bufferedBytes > cap) {
                        bufferedBytes -= buffer.removeFirst().size
                    }
                }
            }
        }
        result.success(null)
    }

    /** 取末尾 durationMs 毫秒并停止释放。缓冲不足时返回已有部分。 */
    private fun stop(durationMs: Int): ByteArray? {
        val chunks = ArrayList<ByteArray>()
        synchronized(buffer) {
            var acc = 0
            val want = BYTES_PER_MS * durationMs.coerceAtLeast(0)
            for (c in buffer.reversed()) {
                chunks.add(c)
                acc += c.size
                if (acc >= want) break
            }
            chunks.reverse()
        }
        release()
        if (chunks.isEmpty()) return null
        val total = chunks.sumOf { it.size }
        val out = ByteArray(total)
        var off = 0
        for (c in chunks) {
            c.copyInto(out, off)
            off += c.size
        }
        return out
    }

    private fun release() {
        val s = session ?: return
        session = null
        // 顺序见类注释:read 进行中直接 release 是未定义行为;stop() 让
        // 阻塞中的 read 尽快返回,join 兜底等线程退出后再 release。
        s.alive.set(false)
        try { s.record.stop() } catch (_: IllegalStateException) {}
        try { s.thread.join(300) } catch (_: InterruptedException) {}
        s.record.release()
        synchronized(buffer) { buffer.clear(); bufferedBytes = 0 }
    }
}
