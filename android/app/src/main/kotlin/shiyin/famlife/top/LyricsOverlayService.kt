package shiyin.famlife.top

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.Choreographer
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.Gravity
import android.util.TypedValue
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import kotlin.math.abs

class LyricsOverlayService : Service() {

    companion object {
        const val CHANNEL_ID = "shiyin_music.lyrics_overlay"
        // 改名前的旧渠道 ID，onCreate 建渠道前删除（避免通知设置里新旧并存）
        private const val OLD_CHANNEL_ID = "kgka_music_hl.lyrics_overlay"
        const val NOTIFICATION_ID = 9001

        const val ACTION_UPDATE_LYRICS = "shiyin.famlife.top.UPDATE_LYRICS"
        // 只更新原生歌词缓存，绝不建窗：App 在前台时悬浮窗必须保持隐藏，但
        // 回桌面自愈重建要用的内容得持续跟随播放（伴奏期没有换句推送兜底）。
        const val ACTION_CACHE_LYRICS = "shiyin.famlife.top.CACHE_LYRICS"
        const val ACTION_UPDATE_PLAY_STATE = "shiyin.famlife.top.UPDATE_PLAY_STATE"
        const val ACTION_HIDE = "shiyin.famlife.top.HIDE_LYRICS"
        const val ACTION_UPDATE_KARAOKE = "shiyin.famlife.top.UPDATE_KARAOKE"
        const val ACTION_UPDATE_SETTINGS = "shiyin.famlife.top.UPDATE_SETTINGS"
        const val ACTION_SET_APP_FOREGROUND = "shiyin.famlife.top.SET_APP_FOREGROUND"
        const val ACTION_VISIBILITY_CHANGED = "shiyin.famlife.top.LYRICS_VISIBILITY_CHANGED"

        const val EXTRA_CURRENT_LYRIC = "current_lyric"
        const val EXTRA_NEXT_LYRIC = "next_lyric"
        const val EXTRA_IS_PLAYING = "is_playing"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_OPACITY = "opacity"
        const val EXTRA_LOCKED = "locked"
        const val EXTRA_PASSTHROUGH = "passthrough"
        const val EXTRA_TEXT_COLOR = "text_color"
        const val EXTRA_BACKGROUND_COLOR = "background_color"
        const val EXTRA_FONT_SIZE = "font_size"
        // 与 Flutter 侧 DesktopLyricsSettings.toMap 同名透传：
        // 单行/双行、文字透明度、歌词色/高亮色在移动端同样生效。
        // EXTRA_TEXT_COLOR 为旧键，仅作回退（旧版 Flutter 只发 textColor）。
        const val EXTRA_UNPLAYED_TEXT_COLOR = "unplayedTextColor"
        const val EXTRA_PLAYED_TEXT_COLOR = "playedTextColor"
        const val EXTRA_TEXT_OPACITY = "textOpacity"
        const val EXTRA_SINGLE_LINE = "singleLine"
        const val EXTRA_IS_FOREGROUND = "is_foreground"
        const val EXTRA_LINE_DURATION_MS = "line_duration_ms"
        const val EXTRA_VISIBLE = "visible"
        const val EXTRA_USER_CLOSED = "user_closed"
        // HIDE 原因：true=切前台等临时隐藏（保留自愈标记与缓存歌词），
        // false=显式关闭（清除标记与缓存，不复活）。
        const val EXTRA_TRANSIENT_HIDE = "transient_hide"
        // show 请求是否自带歌词内容（新版 Flutter 恒带）：带了就以请求内容为
        // 准，没带才回退到服务内缓存，避免旧版下发空歌词时闪“暂无歌词”。
        const val EXTRA_LYRIC_PAYLOAD = "lyric_payload"

        // 停服前的静默等待：留给同一批 intent（前后台切换、冷启动设置同步）
        // 落地的窗口，避免 stopSelf 把已排队的 START 命令一起吞掉。
        private const val STOP_SETTLE_MS = 300L

        private const val PREFS_NAME = "lyrics_overlay_prefs"
        private const val KEY_POS_X = "pos_x"
        private const val KEY_POS_Y = "pos_y"
        private const val KEY_WINDOW_WIDTH = "window_width"
        private const val KEY_OPACITY = "opacity"
        private const val KEY_LOCKED = "locked"
        private const val KEY_PASSTHROUGH = "passthrough"
        private const val KEY_TEXT_COLOR = "text_color"
        private const val KEY_BACKGROUND_COLOR = "background_color"
        private const val KEY_FONT_SIZE = "font_size"
        private const val KEY_UNPLAYED_TEXT_COLOR = "unplayed_text_color"
        private const val KEY_PLAYED_TEXT_COLOR = "played_text_color"
        private const val KEY_TEXT_OPACITY = "text_opacity"
        private const val KEY_SINGLE_LINE = "single_line"

        // 悬浮窗默认宽度：取屏幕宽度的一定比例并设上限，宽度不随歌词文本长短变化。
        // 上限 320dp 沿用原布局 maxWidth 的意图（车机横屏、手机竖屏都保持紧凑），
        // 比例只在屏幕较窄时兜底防止超屏。
        private const val MAX_WINDOW_WIDTH_DP = 320f
        private const val WINDOW_WIDTH_RATIO = 0.9f

        // 用户拖拽手柄可调整的宽度范围：下限保证歌词可读，上限接近全屏。
        private const val MIN_WINDOW_WIDTH_DP = 160f
        private const val MAX_WINDOW_WIDTH_RATIO = 0.95f

        // 下一句歌词字号 = 主字号 * 该比例，跟随字体大小设置等比例缩放
        private const val NEXT_LYRIC_SIZE_RATIO = 0.85f

        // 下一句颜色 = 未播放色 * 文字透明度 * 该压暗系数，与 PC 双行
        // 非活动行（0.65）保持一致。
        private const val NEXT_LYRIC_DIM_RATIO = 0.65f

        fun isRunning(context: Context): Boolean {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            @Suppress("DEPRECATION")
            for (service in manager.getRunningServices(Int.MAX_VALUE)) {
                if (LyricsOverlayService::class.java.name == service.service.className) {
                    return true
                }
            }
            return false
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var karaokeView: KaraokeTextView? = null
    private var tvNextLyric: TextView? = null
    private var btnClose: ImageView? = null
    private var btnLock: ImageView? = null
    private var btnResize: ImageView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var fixedWidthPx = 0
    private var isShowing = false
    private var isAppForeground = false
    private val choreographer by lazy { Choreographer.getInstance() }
    private var karaokeFrameCallback: Choreographer.FrameCallback? = null
    private var karaokeAnchorProgress = 0f
    private var karaokeAnchorUptimeMs = 0L
    private var karaokeLineDurationMs = 0
    private var karaokePlaying = false

    // Settings（默认值与 Flutter 侧 DesktopLyricsSettings 对齐：
    // 透明底 + 单行；冷启动首次显示即与设置页一致）。
    private var bgOpacity: Float = 0f
    private var isLocked: Boolean = false
    private var isPassthrough: Boolean = false
    // 卡拉OK双色：active=高亮（已播放），base=歌词（未播放），与 PC 悬浮窗语义一致。
    // textColor 字段保留，仅作旧版持久化/旧版 Flutter 推送的回退来源。
    @Suppress("unused")
    private var textColor: Int = Color.WHITE
    private var playedColor: Int = Color.WHITE
    private var unplayedColor: Int = Color.WHITE
    private var textOpacity: Float = 1f
    // 单行模式只显示当前句，下一句隐藏；默认 true 与 Flutter 侧一致。
    private var isSingleLine: Boolean = true
    private var backgroundColor: Int = Color.parseColor("#1A1A2E")
    private var fontSizeSp: Float = 16f

    // 悬浮窗“应展示”意图：true = 现在本应显示（只因 App 在前台被临时隐藏），
    // 回桌面必须立刻用缓存歌词重建；false = 用户已关闭/无歌/未开启，不该复活。
    //
    // ⚠️ 该标记与歌词缓存都只活在服务实例里，所以“切前台”绝不能 stopSelf：
    // 实例一旦销毁两者就一起消失，回桌面只能赌 Flutter 侧 show 的时序 —— 而
    // 切前台会连续下发 setAppForeground/hide/show/updateLyrics 一串 intent，
    // 其中紧跟 stopSelf 的那次 startService 会被系统连实例一起丢掉。伴奏期
    // 之后没有任何歌词推送能兜底，悬浮窗就会一直空到下一句才突然出现（用户
    // 报的正是这个）。保持实例存活，回桌面直接用缓存重建即可根治。
    private var overlayWanted: Boolean = false
    private var lastCurrent: String? = null
    private var lastNext: String? = null

    // 前台返回重建用的播放快照：不重建逐字高亮会闪回 0%（正在伴奏时当前句
    // 其实已整句唱完，进度必须恢复成 100%）。
    private var lastProgress: Float = 0f
    private var lastLineDurationMs: Int = 0
    private var lastPlaying: Boolean = false
    // 快照归属的歌词文本。回桌面自愈时缓存可能已被 App 内的换句/切歌刷新——
    // 文本新、进度旧地把新句画成旧句的高亮，比不恢复更糟（伴奏期应该整句
    // 亮着，恢复成半亮会一直错到下一次推送）。两者不同就只上屏文字、不恢复
    // 进度，交给随后 Flutter 侧的高亮推送。
    private var lastProgressLine: String? = null

    private fun hasCachedLyrics(): Boolean =
        !lastCurrent.isNullOrEmpty() || !lastNext.isNullOrEmpty()

    private fun clearCachedLyrics() {
        lastCurrent = null
        lastNext = null
        lastProgress = 0f
        lastLineDurationMs = 0
        lastPlaying = false
        lastProgressLine = null
    }

    /** 记下当前逐字进度快照，供回桌面重建时恢复高亮。 */
    private fun savePlaybackSnapshot() {
        lastProgress = karaokeView?.progress ?: karaokeAnchorProgress
        lastLineDurationMs = karaokeLineDurationMs
        lastPlaying = karaokePlaying
        lastProgressLine = lastCurrent
    }

    /** 快照是否仍属于当前缓存的那一句（否则不能拿来恢复高亮）。 */
    private fun hasSnapshotForCurrentLine(): Boolean =
        lastProgressLine != null && lastProgressLine == lastCurrent

    // 停服延迟二次确认：前后台切换/冷启动设置同步会把多条 intent 挤在极短的
    // 时间里，若在其中一条的处理里立刻 stopSelf，AMS 会把已排队但尚未派发的
    // START 命令连实例一起丢掉（ActivityThread.handleServiceArgs 找不到实例
    // 即静默丢弃），表现就是"回桌面 show 丢失、悬浮窗空到下一句"。改为等这一
    // 批 intent 静默下来再确认一次；期间若悬浮窗/意图状态被改回来就不停服。
    // 空转期没有通知，所以延迟停服对用户不可见。
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable {
        if (!isShowing && !overlayWanted) {
            stopSelf()
        }
    }

    private fun scheduleStopIfIdle() {
        if (isShowing || overlayWanted) return
        // 重新计时（debounce）：同批 intent 里任意一条到达都顺延，避免把
        // 紧随其后的 intent 连同实例一起停掉。
        mainHandler.removeCallbacks(stopRunnable)
        mainHandler.postDelayed(stopRunnable, STOP_SETTLE_MS)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        loadSettings()
        createNotificationChannel()
        // 不在这里 startForeground：服务会被设置同步等非展示类 intent 拉起，
        // 无条件挂常驻通知就是“桌面歌词显示中但悬浮窗不在”的幽灵通知。
        // 改为仅在悬浮窗真正展示时挂出（showOverlay），隐藏即撤下。
    }

    /** 悬浮窗展示期间挂常驻通知（失败不影响悬浮窗本身）。 */
    private fun startForegroundCompat() {
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /** 悬浮窗隐藏后撤下通知，避免用户回到 App 后还挂着“桌面歌词显示中”。 */
    private fun stopForegroundCompat() {
        try {
            // minSdk 26：直接用 API 24+ 的整数版本，不用已废弃的 boolean 重载。
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 空 action：只会来自旧版本 START_STICKY 残留的系统拉活（本服务已改为
        // NOT_STICKY）——没有展示内容，直接停掉，避免只剩“桌面歌词显示中”
        // 常驻通知、悬浮窗却不在的幽灵态。
        if (intent?.action == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_UPDATE_LYRICS -> {
                val current = intent.getStringExtra(EXTRA_CURRENT_LYRIC) ?: ""
                val next = intent.getStringExtra(EXTRA_NEXT_LYRIC) ?: ""
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                val artist = intent.getStringExtra(EXTRA_ARTIST) ?: ""
                // MainActivity 的 show 请求固定携带 TITLE extra（可能为空串），
                // 普通歌词推送不带：以此区分“初始显示”与“歌词更新”。
                val isShowRequest = intent.hasExtra(EXTRA_TITLE)
                // show 请求 = 明确要求“把悬浮窗建出来”（回桌面重建、设置页悬浮
                // 预览都走它），因此不看前后台；普通歌词推送只是内容更新，只有
                // “后台 + 本应展示”时才补建窗口。overlayWanted 这道门是必需的：
                // 用户点关闭那一刻往往正好有一句换句推送在途，它落在关闭之后的
                // 实例上，若只看前后台就会把用户刚关掉的悬浮窗又建出来（且
                // Flutter 侧已把开关置 false，再也不会下发 hide，窗口会一直挂着
                // 盖在应用上）。
                if (!isShowing &&
                    (isShowRequest || (!isAppForeground && overlayWanted))
                ) {
                    showOverlay(title, artist)
                }
                // 新版 Flutter 的 show 请求自带歌词字段（EXTRA_LYRIC_PAYLOAD），
                // 以此为准（空歌词 = 这首歌确实没歌词，要显式显示“暂无歌词”）；
                // 只有旧版只发 title/artist 时，才保留缓存文本避免先闪“暂无歌词”
                // 再弹回。
                val hasLyricPayload = intent.getBooleanExtra(EXTRA_LYRIC_PAYLOAD, false)
                if (isShowRequest && !hasLyricPayload && current.isEmpty() &&
                    next.isEmpty() && hasCachedLyrics()
                ) {
                    // keep cached text; visibility already ensured above.
                } else {
                    updateLyrics(current, next)
                }
            }
            ACTION_UPDATE_PLAY_STATE -> {
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                updatePlayState(isPlaying)
            }
            ACTION_CACHE_LYRICS -> {
                // 仅写缓存（悬浮窗此刻本就隐藏，view 为 null 时上屏是空操作）。
                // 不用 ACTION_UPDATE_LYRICS：那条路径可能补建窗口，而前台补建
                // 会把悬浮窗盖在应用之上。
                updateLyrics(
                    intent.getStringExtra(EXTRA_CURRENT_LYRIC) ?: "",
                    intent.getStringExtra(EXTRA_NEXT_LYRIC) ?: "",
                )
            }
            ACTION_HIDE -> {
                val transient = intent.getBooleanExtra(EXTRA_TRANSIENT_HIDE, false)
                if (transient) {
                    // 临时隐藏（切前台/预览结束）：保留“应展示”意图与歌词缓存，
                    // 服务实例也保持存活（见 overlayWanted 注释）。回桌面时同一
                    // 实例直接用缓存重建，伴奏期也立刻有歌词。
                    overlayWanted = true
                } else {
                    // 显式关闭（关开关/无歌/用户点关闭）：清除标记与缓存歌词，
                    // 回桌面不再复活；是否停服由方法尾统一裁决。
                    overlayWanted = false
                    clearCachedLyrics()
                }
                hideOverlay()
            }
            ACTION_UPDATE_KARAOKE -> {
                val progress = intent.getFloatExtra(EXTRA_PROGRESS, 0f)
                val lineDurationMs = intent.getIntExtra(EXTRA_LINE_DURATION_MS, 0)
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                updateKaraokeProgress(progress, lineDurationMs, isPlaying)
            }
            ACTION_UPDATE_SETTINGS -> {
                bgOpacity = intent.getFloatExtra(EXTRA_OPACITY, bgOpacity)
                isLocked = intent.getBooleanExtra(EXTRA_LOCKED, isLocked)
                // 锁定与触摸穿透相互独立：锁定只禁止拖动，穿透由用户单独开启，
                // 否则穿透（NOT_TOUCHABLE）会让悬浮窗收不到任何点击，无法再解锁
                isPassthrough = intent.getBooleanExtra(EXTRA_PASSTHROUGH, isPassthrough)
                // 旧版 Flutter 只发 EXTRA_TEXT_COLOR，新版发双色键；旧键作回退。
                val legacyColor = intent.getIntExtra(EXTRA_TEXT_COLOR, unplayedColor)
                unplayedColor = intent.getIntExtra(EXTRA_UNPLAYED_TEXT_COLOR, legacyColor)
                playedColor = intent.getIntExtra(EXTRA_PLAYED_TEXT_COLOR, legacyColor)
                textColor = unplayedColor
                textOpacity = intent.getFloatExtra(EXTRA_TEXT_OPACITY, textOpacity)
                    .coerceIn(0f, 1f)
                isSingleLine = intent.getBooleanExtra(EXTRA_SINGLE_LINE, isSingleLine)
                val bgColorInt = intent.getIntExtra(EXTRA_BACKGROUND_COLOR, backgroundColor)
                val sizeSp = intent.getFloatExtra(EXTRA_FONT_SIZE, fontSizeSp)
                backgroundColor = bgColorInt
                fontSizeSp = sizeSp
                saveSettings()
                applySettings()
            }
            ACTION_SET_APP_FOREGROUND -> {
                val foreground = intent.getBooleanExtra(EXTRA_IS_FOREGROUND, false)
                if (foreground) {
                    isAppForeground = true
                    // 切前台：先记下“本应展示”再隐藏（随后到达的 transient HIDE
                    // 只隐藏、不碰标记）。这里绝不能 stopSelf —— 见 overlayWanted
                    // 注释：实例一销毁，回桌面自愈的依据就全丢了。
                    if (isShowing) overlayWanted = true
                    savePlaybackSnapshot()
                    hideOverlay()
                } else {
                    isAppForeground = false
                    // 回桌面自愈：用实例内的缓存歌词立刻重建悬浮窗，不依赖
                    // Flutter 侧紧跟着的 show/updateLyrics（那一串 intent 可能
                    // 被系统的 stop/start 竞态吞掉，而伴奏期没有任何后续推送
                    // 兜底，是“悬浮窗空到下一句”的直接成因）。
                    if (overlayWanted && !isShowing && hasCachedLyrics()) {
                        showOverlay("", "")
                        if (isShowing) {
                            // 恢复逐字高亮：正在伴奏时当前句其实已整句唱完，
                            // 不恢复会从 0% 重新点亮。仅当快照还属于这一句时
                            // 才恢复（见 lastProgressLine）。
                            if (hasSnapshotForCurrentLine()) {
                                updateKaraokeProgress(
                                    lastProgress,
                                    lastLineDurationMs,
                                    lastPlaying,
                                )
                            }
                        } else {
                            // 建窗失败（悬浮窗权限被撤等）：不留空转的服务，
                            // 由 Flutter 侧下次推送/开关重新拉起。
                            overlayWanted = false
                        }
                    }
                }
            }
        }
        // 服务存活裁决：悬浮窗在展示就继续；不在展示但“本应展示”（App 在
        // 前台，回桌面要立刻重建）也继续；只有明确不需要时才停 —— 停服会
        // 连歌词缓存一起丢掉，所以它只能是显式关闭（关开关/无歌/用户关闭）
        // 或与悬浮窗无关的散装 intent 的收尾，且延迟二次确认（见
        // scheduleStopIfIdle），避免吞掉紧随其后的 intent。
        // 注意悬浮窗的真实存活由 Flutter 侧 _shouldShowDesktopLyrics gate，
        // 播放器播控/歌词推送只在该条件成立时下发，这里只做兜底。
        scheduleStopIfIdle()
        // 常驻拉活对悬浮窗无意义：进程死后 Flutter 侧的歌词内容/播态全丢，
        // 拉活只能得到空通知 + 空窗（且 audio_service 的播控是独立服务，
        // 后台播歌不受本返回值影响），故用 NOT_STICKY。
        return START_NOT_STICKY
    }

    /** 计算悬浮窗默认宽度（px）：min(屏幕宽 * 0.9, 320dp)，不随歌词文本长度变化。 */
    private fun computeFixedWidthPx(): Int {
        val displayMetrics = resources.displayMetrics
        val capPx = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, MAX_WINDOW_WIDTH_DP, displayMetrics
        ).toInt()
        return (displayMetrics.widthPixels * WINDOW_WIDTH_RATIO).toInt().coerceAtMost(capPx)
    }

    /** 用户拖拽可调到的最大宽度（px）：屏幕宽 * 0.95，保证窗口边缘仍在屏内。 */
    private fun maxResizeWidthPx(): Int {
        return (resources.displayMetrics.widthPixels * MAX_WINDOW_WIDTH_RATIO).toInt()
    }

    /** 用户拖拽可调到的最小宽度（px）。 */
    private fun minResizeWidthPx(): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, MIN_WINDOW_WIDTH_DP, resources.displayMetrics
        ).toInt()
    }

    /** 读取记忆的窗口宽度：用户拖拽过则用记忆值（限制在可调范围内），否则用默认宽度。 */
    private fun loadWindowWidthPx(): Int {
        val saved = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getInt(KEY_WINDOW_WIDTH, 0)
        if (saved <= 0) return computeFixedWidthPx()
        return saved.coerceIn(minResizeWidthPx(), maxResizeWidthPx())
    }

    private fun showOverlay(title: String, artist: String) {
        if (isShowing) return

        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val inflater = LayoutInflater.from(this)
        overlayView = inflater.inflate(R.layout.overlay_lyrics, null)

        karaokeView = overlayView?.findViewById(R.id.tv_current_lyric)
        tvNextLyric = overlayView?.findViewById(R.id.tv_next_lyric)
        btnClose = overlayView?.findViewById(R.id.btn_close)
        btnLock = overlayView?.findViewById(R.id.btn_lock)
        btnResize = overlayView?.findViewById(R.id.btn_resize)

        // 下一句歌词用原生 TextView 跑马灯（ellipsize=marquee）。悬浮窗
        // 无焦点窗口，需手动选中才能触发长行滚动。
        tvNextLyric?.isSelected = true

        btnClose?.setOnClickListener {
            // 用户主动关闭：等同显式关闭，清除标记与缓存，回桌面不复活。
            overlayWanted = false
            clearCachedLyrics()
            hideOverlay(userClosed = true)
            stopSelf()
        }

        btnLock?.setOnClickListener {
            // Toggle lock from overlay；锁定只禁止拖动，保持窗口可点击以便再次解锁
            isLocked = !isLocked
            saveSettings()
            applySettings()
            // Notify Flutter side
            notifySettingsChanged()
        }

        applySettings()

        // 窗口宽度：优先用用户拖拽后的记忆值（限制在可调范围内），
        // 没有记忆时用默认固定宽度；横竖屏切换时在 onConfigurationChanged 里重算
        fixedWidthPx = loadWindowWidthPx()
        layoutParams = WindowManager.LayoutParams(
            fixedWidthPx,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE,
            buildWindowFlags(),
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            x = prefs.getInt(KEY_POS_X, 50)
            y = prefs.getInt(KEY_POS_Y, 100)
        }

        setupDragListener(overlayView!!, layoutParams!!)
        setupResizeListener(btnResize!!, layoutParams!!)

        try {
            windowManager?.addView(overlayView, layoutParams)
            isShowing = true
            // 通知只在悬浮窗真的展示期间挂出（隐藏即撤，见 stopForegroundCompat），
            // 避免“桌面歌词显示中”却看不到悬浮窗的幽灵通知。
            startForegroundCompat()
            // 建窗即上屏：任何一次重建（回桌面自愈、设置页预览、冷启动 show）
            // 都直接用最近一次歌词填充，绝不留下空白窗 —— 伴奏/间奏期没有
            // 下一句推送来兜底，空窗会一直挂到下一句才“突然出现”。
            if (hasCachedLyrics()) {
                updateLyrics(lastCurrent.orEmpty(), lastNext.orEmpty())
            }
            notifyVisibilityChanged(visible = true, userClosed = false)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun buildWindowFlags(): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        if (isPassthrough) {
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return flags
    }

    private fun setupDragListener(view: View, lp: WindowManager.LayoutParams) {
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        var isDragging = false

        view.setOnTouchListener { _, event ->
            if (isPassthrough) return@setOnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = lp.x
                    initialY = lp.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isLocked) return@setOnTouchListener false
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (!isDragging && (abs(dx) > 10 || abs(dy) > 10)) {
                        isDragging = true
                    }
                    if (isDragging) {
                        lp.x = initialX + dx.toInt()
                        lp.y = initialY + dy.toInt()
                        try {
                            windowManager?.updateViewLayout(view, lp)
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (isDragging) {
                        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                            .edit()
                            .putInt(KEY_POS_X, lp.x)
                            .putInt(KEY_POS_Y, lp.y)
                            .apply()
                    }
                    isDragging
                }
                else -> false
            }
        }
    }

    /** 右下角手柄：横向拖动调整窗口宽度，松手后记忆宽度。 */
    private fun setupResizeListener(view: View, lp: WindowManager.LayoutParams) {
        var initialWidth = 0
        var initialTouchX = 0f
        var isResizing = false

        view.setOnTouchListener { _, event ->
            if (isPassthrough) return@setOnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialWidth = lp.width
                    initialTouchX = event.rawX
                    isResizing = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isLocked) return@setOnTouchListener false
                    val dx = event.rawX - initialTouchX
                    if (!isResizing && abs(dx) > 10) {
                        isResizing = true
                    }
                    if (isResizing) {
                        lp.width = (initialWidth + dx.toInt())
                            .coerceIn(minResizeWidthPx(), maxResizeWidthPx())
                        try {
                            windowManager?.updateViewLayout(overlayView, lp)
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (isResizing) {
                        fixedWidthPx = lp.width
                        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                            .edit()
                            .putInt(KEY_WINDOW_WIDTH, lp.width)
                            .apply()
                    }
                    isResizing
                }
                else -> false
            }
        }
    }

    private fun updateLyrics(current: String, next: String) {
        // 缓存最近一次歌词：供回桌面自愈重建；show 请求的空歌词不经此处
        // （调用方已做缓存保持判断），不会冲掉缓存。
        // 同句重复推送（回桌面自愈 + show 各来一次）不得重置逐字进度：伴奏期
        // 当前句往往已整句唱完，进度被清零会让高亮从头点亮一遍。
        val textChanged = current != lastCurrent || next != lastNext
        lastCurrent = current
        lastNext = next
        if (textChanged) {
            stopKaraokeTicker()
        }
        karaokeView?.post {
            karaokeView?.text = if (current.isEmpty()) "暂无歌词" else current
            if (textChanged) {
                karaokeView?.progress = 0f
            }
            // 先选中再设文本：文本变化触发重排时选中态已就位，跑马灯才会启动
            tvNextLyric?.isSelected = true
            tvNextLyric?.text = next
            // 单行模式只显示当前句，下一句恒隐藏；双行下沿用“无下一句则隐藏”。
            tvNextLyric?.visibility =
                if (next.isEmpty() || isSingleLine) View.GONE else View.VISIBLE
        }
    }

    private fun updateKaraokeProgress(progress: Float) {
        updateKaraokeProgress(progress, 0, karaokePlaying)
    }

    private fun updateKaraokeProgress(progress: Float, lineDurationMs: Int, isPlaying: Boolean) {
        karaokeAnchorProgress = progress.coerceIn(0f, 1f)
        karaokeAnchorUptimeMs = SystemClock.uptimeMillis()
        karaokeLineDurationMs = lineDurationMs.coerceAtLeast(0)
        karaokePlaying = isPlaying
        karaokeView?.post {
            karaokeView?.progress = karaokeAnchorProgress
        }
        if (karaokePlaying && karaokeLineDurationMs > 0 && karaokeAnchorProgress < 1f) {
            startKaraokeTicker()
        } else {
            stopKaraokeTicker()
        }
    }

    private fun updatePlayState(isPlaying: Boolean) {
        karaokePlaying = isPlaying
        if (isPlaying && karaokeLineDurationMs > 0 && karaokeAnchorProgress < 1f) {
            karaokeAnchorUptimeMs = SystemClock.uptimeMillis()
            startKaraokeTicker()
        } else {
            stopKaraokeTicker()
        }
    }

    private fun startKaraokeTicker() {
        if (karaokeFrameCallback != null) {
            return
        }
        val callback = object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                val duration = karaokeLineDurationMs
                if (!karaokePlaying || duration <= 0 || karaokeAnchorProgress >= 1f) {
                    karaokeFrameCallback = null
                    return
                }

                val frameTimeMs = frameTimeNanos / 1_000_000
                val elapsed = (frameTimeMs - karaokeAnchorUptimeMs).coerceAtLeast(0L)
                val nextProgress = (karaokeAnchorProgress + elapsed.toFloat() / duration)
                    .coerceIn(0f, 1f)
                karaokeView?.progress = nextProgress
                if (nextProgress < 1f) {
                    choreographer.postFrameCallback(this)
                } else {
                    karaokeFrameCallback = null
                }
            }
        }
        karaokeFrameCallback = callback
        choreographer.postFrameCallback(callback)
    }

    private fun stopKaraokeTicker() {
        karaokeFrameCallback?.let { choreographer.removeFrameCallback(it) }
        karaokeFrameCallback = null
    }

    /** 颜色整体乘透明度系数（保留原 RGB，只缩放 alpha）。 */
    private fun withOpacity(color: Int, scale: Float): Int {
        val alpha = (Color.alpha(color) * scale).toInt().coerceIn(0, 255)
        return Color.argb(
            alpha,
            Color.red(color),
            Color.green(color),
            Color.blue(color),
        )
    }

    private fun applySettings() {
        overlayView?.post {
            // Background color & opacity
            overlayView?.background?.let { bg ->
                if (bg is android.graphics.drawable.GradientDrawable) {
                    bg.setColor(backgroundColor)
                }
                bg.alpha = (bgOpacity * 255).toInt().coerceIn(0, 255)
            }

            // 卡拉OK双色直通（与 PC 悬浮窗/设置页预览同一语义）：
            // 高亮行 active=高亮色，未播放部分 base=歌词色，均叠加文字透明度。
            karaokeView?.activeColor = withOpacity(playedColor, textOpacity)
            karaokeView?.baseColor = withOpacity(unplayedColor, textOpacity)
            karaokeView?.textSizeSp = fontSizeSp

            // 下一句取未播放色再压暗（PC 双行非活动行 0.65 系数），字号跟随主行缩放。
            tvNextLyric?.setTextColor(
                withOpacity(unplayedColor, textOpacity * NEXT_LYRIC_DIM_RATIO)
            )
            tvNextLyric?.setTextSize(
                TypedValue.COMPLEX_UNIT_SP, fontSizeSp * NEXT_LYRIC_SIZE_RATIO
            )
            // 单行/双行切换时下一句显隐跟随（文本不变，仅行数设置变化时）。
            val nextText = tvNextLyric?.text?.toString().orEmpty()
            tvNextLyric?.visibility =
                if (nextText.isEmpty() || isSingleLine) View.GONE else View.VISIBLE

            // Lock state: hide buttons when locked (compact mode)
            if (isLocked) {
                btnClose?.visibility = View.GONE
                btnLock?.visibility = View.VISIBLE
                btnLock?.setImageResource(android.R.drawable.ic_lock_idle_lock)
                btnLock?.alpha = 0.4f
                btnResize?.visibility = View.GONE
            } else {
                btnClose?.visibility = View.VISIBLE
                btnLock?.visibility = View.VISIBLE
                btnLock?.setImageResource(android.R.drawable.ic_lock_lock)

                btnLock?.alpha = 0.7f
                btnResize?.visibility = View.VISIBLE
            }

            // Touch flags
            if (isShowing) {
                layoutParams?.let { lp ->
                    lp.flags = buildWindowFlags()
                    try {
                        windowManager?.updateViewLayout(overlayView, lp)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    private fun notifySettingsChanged() {
        // Broadcast settings change so Flutter side can update its state
        val intent = Intent("shiyin.famlife.top.LYRICS_SETTINGS_CHANGED")
        intent.putExtra(EXTRA_LOCKED, isLocked)
        intent.putExtra(EXTRA_PASSTHROUGH, isPassthrough)
        intent.setPackage(packageName)
        sendBroadcast(intent)
    }

    private fun loadSettings() {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        // 新鲜安装默认值与 Flutter 侧 DesktopLyricsSettings 对齐（透明底、
        // 单行）；老用户已持久化的选择不受影响。
        bgOpacity = prefs.getFloat(KEY_OPACITY, 0f)
        isLocked = prefs.getBoolean(KEY_LOCKED, false)
        isPassthrough = prefs.getBoolean(KEY_PASSTHROUGH, false)
        // 旧版只有 KEY_TEXT_COLOR 单键：双色缺省时用它回退，保持升级后外观不变。
        val legacyText = prefs.getInt(KEY_TEXT_COLOR, Color.WHITE)
        unplayedColor = prefs.getInt(KEY_UNPLAYED_TEXT_COLOR, legacyText)
        playedColor = prefs.getInt(KEY_PLAYED_TEXT_COLOR, legacyText)
        textColor = unplayedColor
        textOpacity = prefs.getFloat(KEY_TEXT_OPACITY, 1f).coerceIn(0f, 1f)
        isSingleLine = prefs.getBoolean(KEY_SINGLE_LINE, true)
        backgroundColor = prefs.getInt(KEY_BACKGROUND_COLOR, Color.parseColor("#1A1A2E"))
        fontSizeSp = prefs.getFloat(KEY_FONT_SIZE, 16f)
    }

    private fun saveSettings() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putFloat(KEY_OPACITY, bgOpacity)
            .putBoolean(KEY_LOCKED, isLocked)
            .putBoolean(KEY_PASSTHROUGH, isPassthrough)
            .putInt(KEY_TEXT_COLOR, unplayedColor)
            .putInt(KEY_UNPLAYED_TEXT_COLOR, unplayedColor)
            .putInt(KEY_PLAYED_TEXT_COLOR, playedColor)
            .putFloat(KEY_TEXT_OPACITY, textOpacity)
            .putBoolean(KEY_SINGLE_LINE, isSingleLine)
            .putInt(KEY_BACKGROUND_COLOR, backgroundColor)
            .putFloat(KEY_FONT_SIZE, fontSizeSp)
            .apply()
    }

    private fun hideOverlay(userClosed: Boolean = false) {
        if (!isShowing) return
        stopKaraokeTicker()
        // 悬浮窗不在了，常驻通知也一并撤下（回 App 期间不该还挂着
        // “桌面歌词显示中”）。
        stopForegroundCompat()
        try {
            windowManager?.removeView(overlayView)
        } catch (_: Exception) {}
        overlayView = null
        karaokeView = null
        tvNextLyric = null
        btnClose = null
        btnLock = null
        btnResize = null
        layoutParams = null
        isShowing = false
        notifyVisibilityChanged(visible = false, userClosed = userClosed)
    }

    private fun notifyVisibilityChanged(visible: Boolean, userClosed: Boolean) {
        val intent = Intent(ACTION_VISIBILITY_CHANGED)
        intent.putExtra(EXTRA_VISIBLE, visible)
        intent.putExtra(EXTRA_USER_CLOSED, userClosed)
        intent.setPackage(packageName)
        sendBroadcast(intent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            // 渠道改名迁移：删除旧 ID 渠道（不存在时为空操作）
            manager.deleteNotificationChannel(OLD_CHANNEL_ID)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "桌面歌词服务通知"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder: Notification.Builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle("时音 桌面歌词")
        builder.setContentText("桌面歌词显示中")
        builder.setSmallIcon(android.R.drawable.ic_dialog_info)
        builder.setContentIntent(pendingIntent)
        builder.setOngoing(true)
        return builder.build()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 横竖屏切换后屏幕宽度变化，按新屏幕钳制窗口宽度并应用到悬浮窗
        if (isShowing) {
            val newWidth = loadWindowWidthPx().coerceIn(
                minResizeWidthPx(), maxResizeWidthPx()
            )
            if (newWidth != fixedWidthPx) {
                fixedWidthPx = newWidth
                layoutParams?.let { lp ->
                    lp.width = newWidth
                    try {
                        windowManager?.updateViewLayout(overlayView, lp)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    override fun onDestroy() {
        // 实例将销毁：撤掉在途的延迟停服回调，避免它对已销毁的实例再操作。
        mainHandler.removeCallbacks(stopRunnable)
        hideOverlay()
        super.onDestroy()
    }
}
