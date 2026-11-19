package shiyin.famlife.top.mediacenter

import android.app.PendingIntent
import android.net.Uri

/**
 * 归一化后的「正在播放」模型（issue #15）。
 *
 * 只存放要推给媒体中心的数据，不持有 Context，避免泄漏。字段全部
 * volatile：写线程（Dart pushState / 进度 ticker）与读线程（媒体中心
 * 的 Binder 回调 getter）无锁交错，允许读到略旧的整体一致的快照值。
 */
object CarNowPlaying {
    @JvmField
    var title: String = ""

    @JvmField
    var artist: String = ""

    @JvmField
    var album: String = ""

    @JvmField
    var durationMs: Long = 0L

    @JvmField
    var positionMs: Long = 0L

    @JvmField
    var playing: Boolean = false

    @JvmField
    var artwork: String? = null

    /** 整篇 LRC 文本（HUD 歌词用，可空）。 */
    @JvmField
    var lyric: String? = null

    /** 当前歌词句（HUD 单行歌词，车机经 getter 主动 pull）。 */
    @JvmField
    var lyricLine: String? = null

    /** 卡片上的音源图标（本 APK 内的 resource uri，别的 App 的 adaptive icon 车机解不出）。 */
    @JvmField
    var appIcon: String? = null

    /** 媒体中心卡片点击时打开本 App 的意图。 */
    @JvmField
    var launchIntent: PendingIntent? = null

    /**
     * 媒体中心用 uuid 区分「当前曲目」，切歌必须变——但同一首歌里必须
     * **保持稳定**，否则卡片每秒重载。
     */
    fun uuid(): String {
        val t = title
        if (t.isEmpty()) {
            return "shiyin-empty"
        }
        return Integer.toHexString((t + '|' + artist + '|' + album).hashCode())
    }

    fun artworkUri(): Uri? {
        val s = artwork ?: return null
        if (s.isEmpty()) {
            return null
        }
        return runCatching { Uri.parse(s) }.getOrNull()
    }

    fun reset() {
        title = ""
        artist = ""
        album = ""
        durationMs = 0L
        positionMs = 0L
        playing = false
        artwork = null
        lyric = null
        lyricLine = null
    }
}
