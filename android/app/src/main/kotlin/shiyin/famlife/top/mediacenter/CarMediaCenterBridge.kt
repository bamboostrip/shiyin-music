package shiyin.famlife.top.mediacenter

import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flyme Auto（ECARX）媒体中心桥接（issue #15）——方向盘切歌的完整链路。
 *
 * 链路：
 *   MainActivity.configureFlutterEngine → init()
 *     → 后台线程连 EAS Framework（非 ECARX 车机 bindService 失败即休眠）
 *     → register()：registerInMusic(pkg, IMusicClient) + updateZoneId(0)
 *       + registerEx + 上报音源类型 + 恢复回调
 *   方向盘按键 → IMusicClient 回调（onNext/onPrevious/onPlay/onPause…）
 *     → onControl()（外源焦点拦截）→ MethodChannel 下发 Dart 播控
 *   播放状态：Dart pushState → CarNowPlaying → updateMusicPlaybackState
 *     （服务端回调 33 个 getter 拉数据）
 *   焦点：requestPlay 只在**真实开播**时执行（Dart notifyPlayStarted），
 *     避免打开 App 就从 QQ/蓝牙抢走方控归属；暂停后车机会停止派键，
 *     由 notifyPaused 补一次 requestPlay（带外源焦点守卫）。
 *
 * 编排移植自 jessehoo89/lx-music-flyme_auto（Apache-2.0，实车验证），
 * 差异：不做音源列表注入（写系统配置，待实机验证核心链路后再评估）、
 * 不上行播放列表、requestPlay 延迟到开播。
 */
object CarMediaCenterBridge {
    /** 与 Dart 侧 CarMediaCenterService.channelName 保持一致。 */
    const val CHANNEL_NAME = "shiyin_music/car_media_center"

    /** AbstractMusicPlaybackInfo.SOURCE_TYPE_ONLINE：媒体中心用它区分音源。 */
    const val SOURCE_ONLINE = 6

    /** 媒体中心卡片上显示的音源名。 */
    const val APP_NAME = "时音"

    private var appCtx: Context? = null
    private var channel: MethodChannel? = null

    /** 服务端下发的 IMediaCenterClientToken Binder。 */
    @Volatile
    private var token: IBinder? = null

    @Volatile
    private var svc: MediaCenterSvc? = null

    @Volatile
    private var clientBinder: MusicClientBinder? = null

    @Volatile
    private var ready = false

    private var nativeInitStarted = false
    private val main = Handler(Looper.getMainLooper())
    private var tickerRunning = false

    /** 最近一次「媒体中心把播放焦点切给别的音源」的时刻（elapsedRealtime）。 */
    @Volatile
    private var lastForeignFocusAt = 0L

    /** 注册会让媒体中心立刻回一次「焦点=本音源」，这次回调要吃掉，避免自激。 */
    @Volatile
    private var expectFocusCallback = false

    private var lastRegCheckAt = 0L
    private var lastFocusWho: String? = null
    private var pullCount = 0

    // 进度锚点：车机进度条不会自己走，ticker 按锚点+速度外推。
    @Volatile
    private var posAnchorMs = 0L

    @Volatile
    private var posAnchorTs = 0L

    @Volatile
    private var speed = 1f

    @Volatile
    private var lastPushedUuid = ""

    fun appContext(): Context? = appCtx

    fun appPkg(): String = appCtx?.packageName ?: "shiyin.famlife.top"

    /** 是否已注册成功（Dart getDiagnostics 用）。 */
    fun isReady(): Boolean = ready

    // ------------------------------------------------------------------ 初始化

    /**
     * 接线入口（MainActivity.configureFlutterEngine 调用）：建通道、挂
     * Dart→native 处理器，并后台线程启动 EAS 链路（bindService 最长 3 秒，
     * 绝不阻塞启动）。
     */
    fun init(context: Context, flutterEngine: FlutterEngine) {
        if (appCtx == null) {
            appCtx = context.applicationContext
            prepareLauncher()
        }
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        ch.setMethodCallHandler { call, result ->
            handleDartCall(call.method, call.arguments, result)
        }
        channel = ch
        // 原生日志 → Dart 落盘（AppLogService）：用户无 adb 时唯一的
        // 诊断出口。
        CarMediaCenterLog.forwarder = { line ->
            runCatching { ch.invokeMethod("onLog", line) }
        }
        if (nativeInitStarted) {
            return
        }
        nativeInitStarted = true
        CarMediaCenterLog.log("初始化：连接媒体中心服务")
        Thread({
            val binder = EasTransport.mediaCenterBinder()
            if (binder == null) {
                CarMediaCenterLog.log("[nfull] 拿不到 IMediaCenterSvc（非 ECARX 车机属预期）")
                return@Thread
            }
            svc = MediaCenterSvc(binder)
            CarMediaCenterLog.log("[nfull] 已就绪 svcAlive=${svc?.alive()}")
            main.post { register() }
        }, "shiyin-mediacenter-init").start()
    }

    /** 媒体中心卡片点击要能打开本 App；图标用本 APK 自己的资源。 */
    private fun prepareLauncher() {
        val ctx = appCtx ?: return
        runCatching {
            val li = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            CarNowPlaying.launchIntent = li?.let {
                PendingIntent.getActivity(
                    ctx,
                    0,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            val icon = ctx.applicationInfo.icon
            CarNowPlaying.appIcon = "android.resource://${ctx.packageName}/$icon"
        }.onFailure { CarMediaCenterLog.log("[launch] 准备启动意图失败: $it") }
    }

    // ------------------------------------------------------------------ 注册

    private fun usable(): Boolean = svc?.alive() == true

    /** 注册：registerInMusic(19) + updateZoneId(0) + registerEx + 音源类型上报。 */
    private fun register() {
        if (ready || !usable()) {
            return
        }
        val s = svc ?: return
        runCatching {
            if (clientBinder == null) {
                clientBinder = MusicClientBinder()
            }
            val tok = s.registerInMusic(appPkg(), clientBinder!!.asBinder())
            CarMediaCenterLog.log("[nfull] registerInMusic(19) token=$tok pkg=${appPkg()}")
            if (tok == null) {
                CarMediaCenterLog.log("[nfull] token 为空——服务端拒绝注册")
                return
            }
            token = tok
            ready = true
            expectFocusCallback = true

            // zoneId 固定 0；registerEx 携带扩展回调（收藏/下载，未声明能力）。
            val zone = EasTransport.asyncBinderCall(
                "mediacenter",
                "MediaCenterAPI",
                "updateZoneId",
                "0".toByteArray(),
                tok,
            )
            val ex = EasTransport.asyncBinderCall(
                "mediacenter",
                "MediaCenterAPI",
                "registerEx",
                appPkg().toByteArray(),
                ExCallbackBinder,
            )
            CarMediaCenterLog.log("[nfull] updateZoneId(0)=$zone registerEx=$ex")

            s.updateCurrentSourceType(token!!, SOURCE_ONLINE)
            s.updateMediaSourceTypeList(token!!, intArrayOf(SOURCE_ONLINE))
            s.setRecoveryCallback(token!!, RecoveryListenerBinder)
            startTicker()
            pushState()

            // 首次注册时车机可能把本音源停在「加载中」，单靠一次 pushState
            // 有时不触发卡片刷新，补推两次确保数据落地。
            longArrayOf(800L, 2500L).forEach { delay ->
                main.postDelayed({
                    if (ready && token != null) {
                        pushState()
                    }
                }, delay)
            }
        }.onFailure {
            CarMediaCenterLog.log("[nfull] register 失败: $it")
        }
    }

    /** 重新注册：清掉本地旧 token 再走一遍（不抢焦点）。 */
    private fun reRegister(reason: String) {
        CarMediaCenterLog.log("[注册] $reason -> 重新注册 ${appPkg()}")
        ready = false
        token = null
        register()
    }

    /**
     * 切回本音源的自愈：重新注册 + 抢回焦点 + 分次补推。
     * 切换瞬间推的播放信息会被媒体中心以「please register first」拒收，
     * 必须补推才能填上内容页。
     */
    fun recoverRegistration(reason: String) {
        reRegister(reason)
        if (!ready || token == null) {
            return
        }
        runCatching {
            val ok = svc?.requestPlay(token!!) == true
            CarMediaCenterLog.log("[注册] 恢复后 requestPlay=$ok")
        }
        pushState()
        longArrayOf(600L, 1600L, 3200L, 6000L).forEach { delay ->
            main.postDelayed({
                if (ready && token != null) {
                    pushState()
                }
            }, delay)
        }
    }

    /** 用户在媒体中心音源列表里选中本音源：完整恢复并起播。 */
    fun onUserSelectSource(sourceType: Int) {
        CarMediaCenterLog.log("[音源] 用户选中本音源 type=$sourceType -> 完整恢复")
        recoverRegistration("用户选择本音源 type=$sourceType")
        onControl("play", "onSourceSelected")
    }

    // ------------------------------------------------------------------ 控制下发

    /**
     * 媒体中心下发的控制动作（方向盘/扶手箱按键）。
     *
     * next/previous 在外源焦点窗口内直接拒绝（实测从本应用切到 QQ/蓝牙后
     * 媒体中心仍会把「下一首」派给本客户端，不拦会跳回来）。
     *
     * @return 是否已接手（false = 外源焦点拦截，回给服务端表示未处理）。
     */
    fun onControl(action: String, label: String): Boolean {
        if (action == "next" || action == "previous") {
            if (foreignFocusRecently()) {
                CarMediaCenterLog.log("[nmc][拦截] 焦点已切给别的音源，忽略 $label")
                return false
            }
        }
        CarMediaCenterLog.log("[控制] $label → $action 下发 Dart")
        val ch = channel
        if (ch == null) {
            CarMediaCenterLog.log("[控制] Dart 通道未就绪，丢弃 $action")
            return true
        }
        runCatching {
            ch.invokeMethod(
                "onControl",
                mapOf("action" to action, "source" to label),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = Unit
                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        CarMediaCenterLog.log("[控制] Dart 处理 $action 失败: $errorCode")
                    }

                    override fun notImplemented() {
                        CarMediaCenterLog.log("[控制] Dart 未实现 onControl（通道未接线？）")
                    }
                },
            )
        }.onFailure {
            CarMediaCenterLog.log("[控制] invokeMethod(onControl/$action) 异常: ${it.message}")
        }
        return true
    }

    // ------------------------------------------------------------------ 焦点

    /**
     * 媒体中心是不是刚把播放焦点切给了别的音源（8 秒内）。
     */
    fun foreignFocusRecently(): Boolean {
        val now = SystemClock.elapsedRealtime()
        return lastForeignFocusAt > 0L && now - lastForeignFocusAt < 8000L
    }

    /** 焦点回调只记录 + 标记外源窗口，绝不自动抢焦点。 */
    fun onMediaFocus(who: String?) {
        CarMediaCenterLog.log("[焦点] 媒体中心焦点变化: $who ready=$ready")
        if (who == null || (who != appPkg())) {
            lastForeignFocusAt = SystemClock.elapsedRealtime()
            checkRegistrationNow()
            return
        }
        if (expectFocusCallback) {
            expectFocusCallback = false
            CarMediaCenterLog.log("[焦点] 注册自身触发的回调，跳过")
            return
        }
        CarMediaCenterLog.log("[焦点] 指向本音源，仅记录")
    }

    /** 当前焦点是否在本音源；查不到就返回 true（宁可放行不误关功能）。 */
    private fun focusIsSelf(): Boolean {
        if (!ready || token == null) {
            return true
        }
        val who = runCatching { svc?.queryCurrentFocusClient(token!!) }.getOrNull()
        if (who.isNullOrEmpty()) {
            return true
        }
        return who == appPkg()
    }

    /**
     * 暂停后重新申请播放焦点。
     *
     * 实测：方向盘中间键第一下能暂停，但暂停之后再按就完全没有回调——
     * 车机不再把这个键派给我们；补一次 requestPlay 把焦点拿回来。
     */
    private fun reacquireFocus() {
        if (!ready || token == null) {
            return
        }
        if (foreignFocusRecently()) {
            CarMediaCenterLog.log("[焦点] 焦点刚切给别的音源，不补焦")
            return
        }
        if (!focusIsSelf()) {
            CarMediaCenterLog.log("[焦点] 当前焦点不是本音源，不补焦（避免抢回用户切走的音源）")
            return
        }
        runCatching {
            val ok = svc?.requestPlay(token!!) == true
            CarMediaCenterLog.log("[焦点] 暂停后重新 requestPlay=$ok")
        }.onFailure {
            CarMediaCenterLog.log("[焦点] requestPlay 失败: $it")
        }
    }

    /** 注册看护（ticker 调用，3s 节流）：观察焦点归属，只记录不自愈。 */
    private fun ensureRegistered() {
        if (!usable()) {
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastRegCheckAt < 3000L) {
            return
        }
        lastRegCheckAt = now
        if (token == null) {
            return
        }
        val who = runCatching { svc?.queryCurrentFocusClient(token!!) }.getOrNull()
        val prev = lastFocusWho
        val changed = if (who == null) prev != null else who != prev
        lastFocusWho = who
        if (who.isNullOrEmpty()) {
            return
        }
        if (changed) {
            CarMediaCenterLog.log("[注册] 媒体中心当前焦点=$who（本音源=${appPkg()}）")
        }
    }

    private fun checkRegistrationNow() {
        lastRegCheckAt = 0L
        ensureRegistered()
    }

    // ------------------------------------------------------------------ Dart→native

    private fun handleDartCall(method: String, arguments: Any?, result: MethodChannel.Result) {
        runCatching {
            when (method) {
                "getDiagnostics" -> {
                    result.success(
                        mapOf(
                            "ready" to ready,
                            "easBound" to EasTransport.ready(),
                            "pkg" to appPkg(),
                            "logs" to CarMediaCenterLog.dump(),
                        ),
                    )
                }
                "pushState" -> {
                    val map = arguments as? Map<*, *> ?: mapOf<Any, Any>()
                    applyState(map)
                    pushState()
                    result.success(ready)
                }
                "notifyPlayStarted" -> {
                    onPlayStarted()
                    result.success(ready)
                }
                "notifyPaused" -> {
                    onPaused()
                    result.success(ready)
                }
                else -> result.notImplemented()
            }
        }.onFailure {
            CarMediaCenterLog.log("[channel] $method 处理异常: $it")
            runCatching { result.error("bridge_error", it.message, null) }
        }
    }

    /** Dart pushState 的载荷落到 [CarNowPlaying] 与进度锚点。 */
    private fun applyState(map: Map<*, *>) {
        fun str(key: String): String = (map[key] as? String) ?: ""
        fun long(key: String): Long = (map[key] as? Number)?.toLong() ?: 0L
        val title = str("title")
        val artist = str("artist")
        val album = str("album")
        val artwork = str("artwork")
        val duration = long("durationMs")
        val position = long("positionMs")
        val playing = (map["playing"] as? Boolean) ?: false
        val lyric = map["lyric"] as? String
        val lyricLine = map["lyricLine"] as? String

        CarNowPlaying.apply {
            this.title = title
            this.artist = artist
            this.album = album
            this.artwork = artwork.ifEmpty { null }
            durationMs = duration
            positionMs = position
            this.playing = playing
            if (lyric != null) {
                this.lyric = lyric
            }
            if (lyricLine != null) {
                this.lyricLine = lyricLine
            }
        }
        onPositionAnchor(position, (map["speed"] as? Number)?.toFloat() ?: 1f)
    }

    /**
     * 真实开播（Dart 播放态 false→true）：补注册（若曾被注销）+ requestPlay
     * 抢焦点——方控按键的归属权在这里取得；打开 App 不播不放不给别人
     * 抢走。
     */
    private fun onPlayStarted() {
        if (!usable()) {
            return
        }
        if (!ready || token == null) {
            ready = false
            token = null
            register()
        }
        val tok = token ?: return
        runCatching {
            val ok = svc?.requestPlay(tok) == true
            CarMediaCenterLog.log("[焦点] 开播 requestPlay=$ok")
        }
        pushState()
        longArrayOf(800L, 2500L).forEach { delay ->
            main.postDelayed({
                if (ready && token != null) {
                    pushState()
                }
            }, delay)
        }
    }

    /** 暂停：推状态 + 补焦（暂停后车机会停止派键）。 */
    private fun onPaused() {
        if (!ready || token == null) {
            return
        }
        pushState()
        reacquireFocus()
    }

    // ------------------------------------------------------------------ 上行 / ticker

    /** 一次核心上行：播放状态（服务端经 getter 拉曲目）+ 进度 + 歌词。 */
    fun pushState() {
        if (!ready || !usable() || token == null) {
            return
        }
        val tok = token ?: return
        runCatching {
            val state = svc?.updateMusicPlaybackState(tok, clientBinder!!.infoBinder())
            svc?.updateCurrentProgress(tok, currentProgressMs())
            val lyric = CarNowPlaying.lyric
            if (!lyric.isNullOrEmpty()) {
                svc?.updateCurrentLyric(tok, lyric)
            }
            val uuid = CarNowPlaying.uuid()
            if (uuid != lastPushedUuid) {
                lastPushedUuid = uuid
                val title = if (CarNowPlaying.title.isEmpty()) "(空)" else CarNowPlaying.title
                CarMediaCenterLog.log(
                    "[push] 曲目=$title 歌手=${CarNowPlaying.artist} " +
                        "歌词=${lyric?.length ?: 0}B state=$state",
                )
            }
        }.onFailure {
            CarMediaCenterLog.log("[push] 失败: $it")
        }
    }

    /** 进度锚点更新（Dart pushState / seek 后调用）。 */
    fun onPositionAnchor(posMs: Long, sp: Float) {
        posAnchorMs = posMs
        posAnchorTs = SystemClock.elapsedRealtime()
        speed = if (sp > 0) sp else 1f
    }

    /** ticker 用：锚点 + 速度外推的当前进度。 */
    fun currentProgressMs(): Long {
        var pos = posAnchorMs
        if (CarNowPlaying.playing) {
            pos += ((SystemClock.elapsedRealtime() - posAnchorTs) * speed).toLong()
        }
        val duration = CarNowPlaying.durationMs
        if (duration > 0 && pos > duration) {
            pos = duration
        }
        CarNowPlaying.positionMs = pos
        return pos
    }

    /** 每 1 秒：注册看护 + 进度上行（车机进度条不会自己走）。 */
    private fun startTicker() {
        if (tickerRunning) {
            return
        }
        tickerRunning = true
        main.postDelayed(object : Runnable {
            override fun run() {
                runCatching {
                    ensureRegistered()
                    if (ready && token != null) {
                        svc?.updateCurrentProgress(token!!, currentProgressMs())
                    }
                }
                main.postDelayed(this, 1000L)
            }
        }, 1000L)
    }

    // ------------------------------------------------------------------ 日志辅助

    /** 服务端轮询很密，只在头几次和每 50 次打一条。 */
    fun notePull(what: String) {
        pullCount++
        if (pullCount <= 6 || pullCount % 50 == 0) {
            CarMediaCenterLog.log("[nmc] 服务端取数据($pullCount): $what")
        }
    }

    fun noteCmd(code: Int, what: String) {
        CarMediaCenterLog.log("[nmc] 服务端下发动作 code=$code $what")
    }

    // ------------------------------------------------------------------ 扩展回调 Binder

    /**
     * registerEx 的扩展动作回调（onAction/onExAction）：本仓未声明收藏/
     * 下载能力，统一返回空。
     */
    private object ExCallbackBinder : Binder() {
        private const val EX_DESCRIPTOR = "com.ecarx.eas.xsf.mediacenter.IExCallback"

        override fun getInterfaceDescriptor(): String = EX_DESCRIPTOR

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(EX_DESCRIPTOR)
                return true
            }
            data?.let { runCatching { it.enforceInterface(EX_DESCRIPTOR) } }
            if (reply == null) {
                return true
            }
            reply.writeNoException()
            if (code == 1) {
                reply.writeString(null)
            } else {
                reply.writeInt(0) // IExContent = null
            }
            return true
        }
    }

    /**
     * 恢复监听：车机「恢复上次音源」时回调（code=2 = 请求播放信息），
     * 主线程补推一次完整状态（避免 Binder 线程里再同步打进媒体中心）。
     */
    private object RecoveryListenerBinder : Binder() {
        private const val LISTENER_DESCRIPTOR =
            "ecarx.xsf.mediacenter.staterecover.IMusicRecoveryListener"

        override fun getInterfaceDescriptor(): String = LISTENER_DESCRIPTOR

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(LISTENER_DESCRIPTOR)
                return true
            }
            data?.let { runCatching { it.enforceInterface(LISTENER_DESCRIPTOR) } }
            if (code == 2) {
                CarMediaCenterLog.log("[nfull] 车机请求恢复播放信息")
                main.post { pushState() }
            } else {
                CarMediaCenterLog.log("[nfull] 车机恢复回调 code=$code（忽略）")
            }
            reply?.writeNoException()
            return true
        }
    }
}
