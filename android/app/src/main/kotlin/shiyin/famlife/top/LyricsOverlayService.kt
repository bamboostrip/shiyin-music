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
import android.os.IBinder
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
        const val CHANNEL_ID = "kgka_music_hl.lyrics_overlay"
        const val NOTIFICATION_ID = 9001

        const val ACTION_UPDATE_LYRICS = "shiyin.famlife.top.UPDATE_LYRICS"
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
        const val EXTRA_IS_FOREGROUND = "is_foreground"
        const val EXTRA_LINE_DURATION_MS = "line_duration_ms"
        const val EXTRA_VISIBLE = "visible"
        const val EXTRA_USER_CLOSED = "user_closed"

        private const val PREFS_NAME = "lyrics_overlay_prefs"
        private const val KEY_POS_X = "pos_x"
        private const val KEY_POS_Y = "pos_y"
        private const val KEY_OPACITY = "opacity"
        private const val KEY_LOCKED = "locked"
        private const val KEY_PASSTHROUGH = "passthrough"
        private const val KEY_TEXT_COLOR = "text_color"
        private const val KEY_BACKGROUND_COLOR = "background_color"
        private const val KEY_FONT_SIZE = "font_size"

        // 悬浮窗固定宽度：取屏幕宽度的一定比例并设上限，宽度不随歌词文本长短变化。
        // 上限 320dp 沿用原布局 maxWidth 的意图（车机横屏、手机竖屏都保持紧凑），
        // 比例只在屏幕较窄时兜底防止超屏。
        private const val MAX_WINDOW_WIDTH_DP = 320f
        private const val WINDOW_WIDTH_RATIO = 0.9f

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

    // Settings
    private var bgOpacity: Float = 0.8f
    private var isLocked: Boolean = false
    private var isPassthrough: Boolean = false
    private var textColor: Int = Color.WHITE
    private var backgroundColor: Int = Color.parseColor("#1A1A2E")
    private var fontSizeSp: Float = 16f

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        loadSettings()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE_LYRICS -> {
                val current = intent.getStringExtra(EXTRA_CURRENT_LYRIC) ?: ""
                val next = intent.getStringExtra(EXTRA_NEXT_LYRIC) ?: ""
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                val artist = intent.getStringExtra(EXTRA_ARTIST) ?: ""
                if (!isShowing && !isAppForeground) {
                    showOverlay(title, artist)
                }
                updateLyrics(current, next)
            }
            ACTION_UPDATE_PLAY_STATE -> {
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                updatePlayState(isPlaying)
            }
            ACTION_HIDE -> {
                hideOverlay()
                stopSelf()
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
                // Lock auto-enables passthrough
                isPassthrough = if (isLocked) true else intent.getBooleanExtra(EXTRA_PASSTHROUGH, isPassthrough)
                val colorInt = intent.getIntExtra(EXTRA_TEXT_COLOR, textColor)
                val bgColorInt = intent.getIntExtra(EXTRA_BACKGROUND_COLOR, backgroundColor)
                val sizeSp = intent.getFloatExtra(EXTRA_FONT_SIZE, fontSizeSp)
                textColor = colorInt
                backgroundColor = bgColorInt
                fontSizeSp = sizeSp
                saveSettings()
                applySettings()
            }
            ACTION_SET_APP_FOREGROUND -> {
                isAppForeground = intent.getBooleanExtra(EXTRA_IS_FOREGROUND, false)
                if (isAppForeground) {
                    hideOverlay()
                }
            }
        }
        return START_STICKY
    }

    /** 计算悬浮窗固定宽度（px）：min(屏幕宽 * 0.9, 320dp)，不随歌词文本长度变化。 */
    private fun computeFixedWidthPx(): Int {
        val displayMetrics = resources.displayMetrics
        val capPx = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, MAX_WINDOW_WIDTH_DP, displayMetrics
        ).toInt()
        return (displayMetrics.widthPixels * WINDOW_WIDTH_RATIO).toInt().coerceAtMost(capPx)
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

        // 下一句歌词用原生 TextView 跑马灯（ellipsize=marquee）。悬浮窗
        // 无焦点窗口，需手动选中才能触发长行滚动。
        tvNextLyric?.isSelected = true

        btnClose?.setOnClickListener {
            hideOverlay(userClosed = true)
            stopSelf()
        }

        btnLock?.setOnClickListener {
            // Toggle lock from overlay
            isLocked = !isLocked
            isPassthrough = isLocked // Lock auto-enables passthrough
            saveSettings()
            applySettings()
            // Notify Flutter side
            notifySettingsChanged()
        }

        applySettings()

        // 固定窗口宽度：按当前屏幕尺寸计算一次，横竖屏切换时在
        // onConfigurationChanged 里重算，保证不随歌词文本长短变化
        fixedWidthPx = computeFixedWidthPx()
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

        try {
            windowManager?.addView(overlayView, layoutParams)
            isShowing = true
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

    private fun updateLyrics(current: String, next: String) {
        stopKaraokeTicker()
        karaokeView?.post {
            karaokeView?.text = if (current.isEmpty()) "暂无歌词" else current
            karaokeView?.progress = 0f
            // 先选中再设文本：文本变化触发重排时选中态已就位，跑马灯才会启动
            tvNextLyric?.isSelected = true
            tvNextLyric?.text = next
            tvNextLyric?.visibility = if (next.isEmpty()) View.GONE else View.VISIBLE
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

    private fun applySettings() {
        overlayView?.post {
            // Background color & opacity
            overlayView?.background?.let { bg ->
                if (bg is android.graphics.drawable.GradientDrawable) {
                    bg.setColor(backgroundColor)
                }
                bg.alpha = (bgOpacity * 255).toInt().coerceIn(0, 255)
            }

            // Text color
            karaokeView?.activeColor = textColor
            karaokeView?.baseColor = Color.argb(
                90,
                Color.red(textColor),
                Color.green(textColor),
                Color.blue(textColor)
            )
            karaokeView?.textSizeSp = fontSizeSp

            // Next lyric color (slightly dimmer)
            val dimAlpha = (Color.alpha(textColor) * 0.5f).toInt().coerceIn(0, 255)
            tvNextLyric?.setTextColor(Color.argb(
                dimAlpha,
                Color.red(textColor),
                Color.green(textColor),
                Color.blue(textColor)
            ))

            // Lock state: hide buttons when locked (compact mode)
            if (isLocked) {
                btnClose?.visibility = View.GONE
                btnLock?.visibility = View.VISIBLE
                btnLock?.setImageResource(android.R.drawable.ic_lock_idle_lock)
                btnLock?.alpha = 0.4f
            } else {
                btnClose?.visibility = View.VISIBLE
                btnLock?.visibility = View.VISIBLE
                btnLock?.setImageResource(android.R.drawable.ic_lock_lock)

                btnLock?.alpha = 0.7f
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
        bgOpacity = prefs.getFloat(KEY_OPACITY, 0.8f)
        isLocked = prefs.getBoolean(KEY_LOCKED, false)
        isPassthrough = if (isLocked) true else prefs.getBoolean(KEY_PASSTHROUGH, false)
        textColor = prefs.getInt(KEY_TEXT_COLOR, Color.WHITE)
        backgroundColor = prefs.getInt(KEY_BACKGROUND_COLOR, Color.parseColor("#1A1A2E"))
        fontSizeSp = prefs.getFloat(KEY_FONT_SIZE, 16f)
    }

    private fun saveSettings() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putFloat(KEY_OPACITY, bgOpacity)
            .putBoolean(KEY_LOCKED, isLocked)
            .putBoolean(KEY_PASSTHROUGH, isPassthrough)
            .putInt(KEY_TEXT_COLOR, textColor)
            .putInt(KEY_BACKGROUND_COLOR, backgroundColor)
            .putFloat(KEY_FONT_SIZE, fontSizeSp)
            .apply()
    }

    private fun hideOverlay(userClosed: Boolean = false) {
        if (!isShowing) return
        stopKaraokeTicker()
        try {
            windowManager?.removeView(overlayView)
        } catch (_: Exception) {}
        overlayView = null
        karaokeView = null
        tvNextLyric = null
        btnClose = null
        btnLock = null
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
            val channel = NotificationChannel(
                CHANNEL_ID,
                "桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "桌面歌词服务通知"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
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

        builder.setContentTitle("KA Music 桌面歌词")
        builder.setContentText("桌面歌词显示中")
        builder.setSmallIcon(android.R.drawable.ic_dialog_info)
        builder.setContentIntent(pendingIntent)
        builder.setOngoing(true)
        return builder.build()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 横竖屏切换后屏幕宽度变化，重算固定宽度并应用到悬浮窗
        if (isShowing) {
            val newWidth = computeFixedWidthPx()
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
        hideOverlay()
        super.onDestroy()
    }
}
