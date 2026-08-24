package shiyin.famlife.top

import android.Manifest
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.os.Handler
import android.util.Log
import android.os.Looper
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File
import kotlin.concurrent.thread

class MainActivity : AudioServiceActivity() {
    private val updateDownloads = mutableMapOf<Long, String>()
    private var downloadReceiverRegistered = false
    private var lyricsStateReceiverRegistered = false
    private var desktopLyricsChannel: MethodChannel? = null
    // audio_effects channel 引用,供响度分析中途反向 invokeMethod 推进度给 Dart。
    private var audioEffectsChannel: MethodChannel? = null
    private var bassBoost: BassBoost? = null
    private var bassBoostSessionId: Int? = null
    private var equalizer: Equalizer? = null
    private var equalizerSessionId: Int? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int? = null
    // 当前响度分析的取消标志。切歌时调用 cancelLoudnessAnalysis 置 true,
    // 让解码循环立即结束,避免旧歌曲分析空跑占 CPU。
    @Volatile private var loudnessAnalysisCancelled: Boolean = false
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val REQUEST_READ_AUDIO = 1001
    }

    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
            val fileName = updateDownloads.remove(downloadId) ?: return
            if (isDownloadSuccessful(downloadId)) {
                installDownloadedApk(fileName)
            }
        }
    }

    private val lyricsStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != LyricsOverlayService.ACTION_VISIBILITY_CHANGED) {
                return
            }
            desktopLyricsChannel?.invokeMethod(
                "onVisibilityChanged",
                mapOf(
                    "visible" to intent.getBooleanExtra(
                        LyricsOverlayService.EXTRA_VISIBLE,
                        false
                    ),
                    "userClosed" to intent.getBooleanExtra(
                        LyricsOverlayService.EXTRA_USER_CLOSED,
                        false
                    )
                )
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 车机检测：isAutomotive 判别车机。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAutomotive" -> result.success(isAutomotiveDevice())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "ka_music_update.apk"
                        if (url.isNullOrBlank()) {
                            result.error("invalid_url", "APK download url is empty", null)
                            return@setMethodCallHandler
                        }

                        runCatching {
                            enqueueApkDownload(url, fileName)
                        }.onSuccess {
                            result.success(null)
                        }.onFailure { error ->
                            result.error("download_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/audio_effects")
            .also { audioEffectsChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getEqualizerConfig" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        runCatching {
                            equalizerConfig(audioSessionId)
                        }.onSuccess { config ->
                            result.success(config)
                        }.onFailure { error ->
                            result.error("equalizer_config_failed", error.message, null)
                        }
                    }
                    "configureEqualizer" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val levels = call.argument<List<Int>>("levels") ?: emptyList()

                        runCatching {
                            configureEqualizer(audioSessionId, enabled, levels)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseEqualizer()
                            result.error("equalizer_failed", error.message, null)
                        }
                    }
                    "configureBassBoost" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val strength = call.argument<Int>("strength") ?: 0

                        runCatching {
                            configureBassBoost(audioSessionId, enabled, strength)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseBassBoost()
                            result.error("bass_boost_failed", error.message, null)
                        }
                    }
                    "analyzeLoudness" -> {
                        val url = call.argument<String>("url")
                        val maxDurationMs = call.argument<Int>("maxDurationMs") ?: 1800000
                        val progressIntervalMs = call.argument<Int>("progressIntervalMs") ?: 500
                        if (url.isNullOrBlank()) {
                            result.error("invalid_url", "url is null or empty", null)
                            return@setMethodCallHandler
                        }
                        Log.i("Loudness", "channel analyzeLoudness 收到 url=$url interval=${progressIntervalMs}ms")
                        // 每次新分析重置取消标志。切歌时 Dart 侧调 cancelLoudnessAnalysis
                        // 置 true,解码循环检测到后立即抛异常结束,不再空跑。
                        loudnessAnalysisCancelled = false
                        val channel = audioEffectsChannel
                        thread {
                            try {
                                val analyzed = LoudnessAnalyzer.analyze(
                                    url,
                                    maxDurationMs,
                                    progressIntervalMs,
                                    isCancelled = { loudnessAnalysisCancelled },
                                    onProgress = { lufs, analyzedMs ->
                                        // 反向 invokeMethod 把中途 LUFS 推给 Dart,
                                        // Dart 侧用序号守卫决定是否应用。切到主线程调用
                                        // (Flutter MethodChannel 要求主线程)。
                                        if (channel != null && !loudnessAnalysisCancelled) {
                                            mainHandler.post {
                                                channel.invokeMethod(
                                                    "onLoudnessProgress",
                                                    mapOf(
                                                        "lufs" to lufs,
                                                        "analyzedMs" to analyzedMs
                                                    )
                                                )
                                            }
                                        }
                                    },
                                )
                                mainHandler.post {
                                    result.success(
                                        mapOf(
                                            "lufs" to analyzed.lufs,
                                            "sampleRate" to analyzed.sampleRate,
                                            "analyzedMs" to analyzed.analyzedMs
                                        )
                                    )
                                }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    if (loudnessAnalysisCancelled) {
                                        // 取消不算失败,返回 success(false) 让 Dart 侧
                                        // 走"已丢弃"路径(序号守卫也会拦截)。
                                        result.success(null)
                                    } else {
                                        result.error("analyze_failed", e.message, null)
                                    }
                                }
                            }
                        }
                    }
                    "cancelLoudnessAnalysis" -> {
                        // 切歌时调用,让正在跑的解码循环立即结束。
                        Log.i("Loudness", "channel cancelLoudnessAnalysis 取消在途分析")
                        loudnessAnalysisCancelled = true
                        result.success(true)
                    }
                    "configureLoudnessGain" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val gainMb = call.argument<Int>("gainMb") ?: 0
                        Log.i("Loudness", "channel configureLoudnessGain enabled=$enabled gainMb=$gainMb session=$audioSessionId")

                        runCatching {
                            configureLoudnessGain(audioSessionId, enabled, gainMb)
                        }.onSuccess { supported ->
                            Log.i("Loudness", "configureLoudnessGain 成功 supported=$supported gainMb=$gainMb")
                            result.success(supported)
                        }.onFailure { error ->
                            Log.e("Loudness", "configureLoudnessGain 失败 gainMb=$gainMb", error)
                            releaseLoudnessGain()
                            result.error("loudness_gain_failed", error.message, null)
                        }
                    }
                    "releaseLoudnessGain" -> {
                        releaseLoudnessGain()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/local_music")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> {
                        result.success(hasReadAudioPermission())
                    }
                    "requestPermission" -> {
                        if (hasReadAudioPermission()) {
                            result.success(true)
                        } else {
                            pendingPermissionResult = result
                            requestAudioPermission()
                        }
                    }
                    "getLocalSongs" -> {
                        if (!hasReadAudioPermission()) {
                            result.error("no_permission", "READ_MEDIA_AUDIO permission not granted", null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            queryLocalSongs()
                        }.onSuccess { songs ->
                            result.success(songs)
                        }.onFailure { error ->
                            result.error("query_failed", error.message, null)
                        }
                    }
                    "getAlbumArt" -> {
                        val albumId = call.argument<Number>("albumId")?.toLong()
                        if (albumId == null || albumId <= 0) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            getAlbumArtBytes(albumId)
                        }.onSuccess { bytes ->
                            result.success(bytes)
                        }.onFailure { error ->
                            result.error("album_art_failed", error.message, null)
                        }
                    }
                    "getEmbeddedLyrics" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrEmpty()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        runCatching {
                            getEmbeddedLyrics(filePath)
                        }.onSuccess { lyrics ->
                            result.success(lyrics)
                        }.onFailure { error ->
                            result.error("lyrics_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        desktopLyricsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kgka_music_hl/desktop_lyrics"
        )
        registerLyricsStateReceiver()
        desktopLyricsChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }
                    "show" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("no_permission", "No overlay permission", null)
                            return@setMethodCallHandler
                        }
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_LYRICS
                            putExtra(LyricsOverlayService.EXTRA_TITLE, title)
                            putExtra(LyricsOverlayService.EXTRA_ARTIST, artist)
                            putExtra(LyricsOverlayService.EXTRA_CURRENT_LYRIC, "")
                            putExtra(LyricsOverlayService.EXTRA_NEXT_LYRIC, "")
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "hide" -> {
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_HIDE
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updateLyrics" -> {
                        val current = call.argument<String>("current") ?: ""
                        val next = call.argument<String>("next") ?: ""
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_LYRICS
                            putExtra(LyricsOverlayService.EXTRA_CURRENT_LYRIC, current)
                            putExtra(LyricsOverlayService.EXTRA_NEXT_LYRIC, next)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updatePlayState" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_PLAY_STATE
                            putExtra(LyricsOverlayService.EXTRA_IS_PLAYING, isPlaying)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "isVisible" -> {
                        result.success(LyricsOverlayService.isRunning(this))
                    }
                    "updateKaraokeProgress" -> {
                        val progress = call.argument<Double>("progress")?.toFloat() ?: 0f
                        val lineDurationMs = call.argument<Int>("lineDurationMs") ?: 0
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_KARAOKE
                            putExtra(LyricsOverlayService.EXTRA_PROGRESS, progress)
                            putExtra(LyricsOverlayService.EXTRA_LINE_DURATION_MS, lineDurationMs)
                            putExtra(LyricsOverlayService.EXTRA_IS_PLAYING, isPlaying)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updateSettings" -> {
                        val opacity = call.argument<Double>("opacity")?.toFloat() ?: 0.8f
                        val locked = call.argument<Boolean>("locked") ?: false
                        val passthrough = call.argument<Boolean>("passthrough") ?: false
                        val textColorLong = call.argument<Long>("textColor") ?: 0xFFFFFFFF
                        val backgroundColorLong = call.argument<Long>("backgroundColor") ?: 0xFF1A1A2E
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 16f
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_SETTINGS
                            putExtra(LyricsOverlayService.EXTRA_OPACITY, opacity)
                            putExtra(LyricsOverlayService.EXTRA_LOCKED, locked)
                            putExtra(LyricsOverlayService.EXTRA_PASSTHROUGH, passthrough)
                            putExtra(LyricsOverlayService.EXTRA_TEXT_COLOR, textColorLong.toInt())
                            putExtra(LyricsOverlayService.EXTRA_BACKGROUND_COLOR, backgroundColorLong.toInt())
                            putExtra(LyricsOverlayService.EXTRA_FONT_SIZE, fontSize)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "setAppForeground" -> {
                        val isForeground = call.argument<Boolean>("isForeground") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_SET_APP_FOREGROUND
                            putExtra(LyricsOverlayService.EXTRA_IS_FOREGROUND, isForeground)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readAudioPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun hasReadAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, readAudioPermission()) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestAudioPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(readAudioPermission()),
            REQUEST_READ_AUDIO
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_READ_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun queryLocalSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.IS_MUSIC,
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(
                collection,
                projection,
                selection,
                null,
                sortOrder
            )

            cursor?.let {
                val idColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val dataColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                val albumIdColumn = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)

                while (it.moveToNext()) {
                    val id = it.getLong(idColumn)
                    val title = it.getString(titleColumn) ?: "未知歌曲"
                    val artist = it.getString(artistColumn) ?: "未知艺人"
                    val album = it.getString(albumColumn) ?: ""
                    val duration = it.getLong(durationColumn)
                    val filePath = it.getString(dataColumn) ?: ""
                    val albumId = it.getLong(albumIdColumn)

                    // 构建专辑封面 URI
                    val albumArtUri = ContentUris.withAppendedId(
                        Uri.parse("content://media/external/audio/albumart"),
                        albumId
                    )

                    if (filePath.isNotEmpty()) {
                        songs.add(
                            mapOf(
                                "id" to filePath,
                                "title" to title,
                                "artist" to artist,
                                "album" to album,
                                "duration" to duration,
                                "filePath" to filePath,
                                "albumArtUri" to albumArtUri.toString(),
                            )
                        )
                    }
                }
            }
        } finally {
            cursor?.close()
        }

        return songs
    }

    private fun registerLyricsStateReceiver() {
        if (lyricsStateReceiverRegistered) {
            return
        }
        val filter = IntentFilter(LyricsOverlayService.ACTION_VISIBILITY_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(lyricsStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(lyricsStateReceiver, filter)
        }
        lyricsStateReceiverRegistered = true
    }

    private fun equalizerConfig(audioSessionId: Int?): Map<String, Any>? {
        if (audioSessionId == null || audioSessionId <= 0) {
            return null
        }
        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bands = (0 until effect.numberOfBands).map { index ->
            val band = index.toShort()
            mapOf(
                "centerHz" to effect.getCenterFreq(band) / 1000,
                "level" to effect.getBandLevel(band).toInt()
            )
        }
        return mapOf(
            "range" to listOf(range[0].toInt(), range[1].toInt()),
            "bands" to bands
        )
    }

    private fun configureEqualizer(
        audioSessionId: Int?,
        enabled: Boolean,
        levels: List<Int>
    ): Boolean {
        if (!enabled) {
            releaseEqualizer()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bandCount = minOf(effect.numberOfBands.toInt(), levels.size)
        for (index in 0 until bandCount) {
            val level = levels[index].coerceIn(range[0].toInt(), range[1].toInt())
            effect.setBandLevel(index.toShort(), level.toShort())
        }
        effect.enabled = true
        return true
    }

    private fun ensureEqualizer(audioSessionId: Int): Equalizer {
        if (equalizerSessionId == audioSessionId && equalizer != null) {
            return equalizer!!
        }
        releaseEqualizer()
        return Equalizer(0, audioSessionId).also {
            equalizer = it
            equalizerSessionId = audioSessionId
        }
    }

    private fun releaseEqualizer() {
        equalizer?.runCatching {
            enabled = false
            release()
        }
        equalizer = null
        equalizerSessionId = null
    }

    private fun configureBassBoost(
        audioSessionId: Int?,
        enabled: Boolean,
        strength: Int
    ): Boolean {
        if (!enabled) {
            releaseBassBoost()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (bassBoostSessionId == audioSessionId && bassBoost != null) {
            bassBoost!!
        } else {
            releaseBassBoost()
            BassBoost(0, audioSessionId).also {
                bassBoost = it
                bassBoostSessionId = audioSessionId
            }
        }

        val clampedStrength = strength.coerceIn(0, 1000).toShort()
        if (effect.strengthSupported) {
            effect.setStrength(clampedStrength)
        } else {
            effect.setStrength(if (clampedStrength > 0) 1000 else 0)
        }
        effect.enabled = true
        return true
    }

    private fun releaseBassBoost() {
        bassBoost?.runCatching {
            enabled = false
            release()
        }
        bassBoost = null
        bassBoostSessionId = null
    }

    /**
     * 配置响度增益(基于已分析的 LUFS 差值)。
     * 使用 Android [LoudnessEnhancer] 仅放大轻歌(增益范围 0~1500 mB);
     * 响歌衰减由 Dart 侧 [AudioPlayer.setVolume] 完成,LoudnessEnhancer 不支持负增益。
     * 仿照 [configureBassBoost] 范式:sessionId 不变则复用,否则释放重建。
     */
    private fun configureLoudnessGain(
        audioSessionId: Int?,
        enabled: Boolean,
        gainMb: Int
    ): Boolean {
        if (!enabled) {
            releaseLoudnessGain()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (loudnessEnhancerSessionId == audioSessionId &&
            loudnessEnhancer != null
        ) {
            loudnessEnhancer!!
        } else {
            releaseLoudnessGain()
            LoudnessEnhancer(audioSessionId).also {
                loudnessEnhancer = it
                loudnessEnhancerSessionId = audioSessionId
            }
        }

        // LoudnessEnhancer 仅支持正向放大(setTargetGain 文档限定 "amplified"),
        // 负值衰减属未定义行为,故下限为 0;响歌衰减由 Dart 侧 setVolume 完成。
        val clampedGain = gainMb.coerceIn(0, 1500)
        effect.setTargetGain(clampedGain)
        effect.enabled = true
        return true
    }

    private fun releaseLoudnessGain() {
        loudnessEnhancer?.runCatching {
            enabled = false
            release()
        }
        loudnessEnhancer = null
        loudnessEnhancerSessionId = null
    }

    private fun enqueueApkDownload(url: String, fileName: String) {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle("KA Music 更新包")
            .setDescription("正在下载新版本")
            .setMimeType("application/vnd.android.package-archive")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)

        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = downloadManager.enqueue(request)
        updateDownloads[downloadId] = fileName
        registerDownloadReceiver()
    }

    private fun registerDownloadReceiver() {
        if (downloadReceiverRegistered) {
            return
        }
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(downloadReceiver, filter)
        }
        downloadReceiverRegistered = true
    }

    private fun isDownloadSuccessful(downloadId: Long): Boolean {
        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val query = DownloadManager.Query().setFilterById(downloadId)
        var cursor: Cursor? = null
        return try {
            cursor = downloadManager.query(query)
            cursor != null &&
                cursor.moveToFirst() &&
                cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) ==
                DownloadManager.STATUS_SUCCESSFUL
        } finally {
            cursor?.close()
        }
    }

    private fun installDownloadedApk(fileName: String) {
        val apkFile = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
        if (!apkFile.exists()) {
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(installIntent)
    }

    /// 是否为 Android Automotive 车机设备。
    /// 仅依赖官方 FEATURE_AUTOMOTIVE 标记：国产定制 AOSP 车机通常未声明，
    /// 会判为 false，需用户在设置→个性化手动开启车机模式。
    private fun isAutomotiveDevice(): Boolean {
        return packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)
    }

    private fun getAlbumArtBytes(albumId: Long): ByteArray? {
        val uri = ContentUris.withAppendedId(
            Uri.parse("content://media/external/audio/albumart"),
            albumId
        )
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        }
    }

    private fun getEmbeddedLyrics(filePath: String): String? {
        return try {
            val retriever = android.media.MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            // METADATA_KEY_LYRICS = 26，API 29+ 才有常量名，直接用数字 key 兼容旧版本
            val lyrics = retriever.extractMetadata(26)
            retriever.release()
            lyrics
        } catch (e: Exception) {
            null
        }
    }

    override fun onDestroy() {
        releaseEqualizer()
        releaseBassBoost()
        releaseLoudnessGain()
        if (downloadReceiverRegistered) {
            unregisterReceiver(downloadReceiver)
            downloadReceiverRegistered = false
        }
        if (lyricsStateReceiverRegistered) {
            unregisterReceiver(lyricsStateReceiver)
            lyricsStateReceiverRegistered = false
        }
        super.onDestroy()
    }
}
