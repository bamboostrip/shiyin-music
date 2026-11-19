package shiyin.famlife.top

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build

class MusicApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        setupNotificationChannels()
        registerCarMediaBroadcastReceiver()
    }

    /**
     * 车机私有媒体广播兜底（issue #15）：进程级运行时注册，App 存活期间
     * 前台/后台都能收到。两类广播都来自车机系统/其他应用，必须
     * RECEIVER_EXPORTED；Manifest 静态注册在 targetSdk 26+ 收不到这些
     * 隐式广播（不在 Android 8+ 豁免清单），运行时注册是唯一途径。
     * 广播本身只在车机发媒体指令时才会到达，手机上零开销。
     */
    private fun registerCarMediaBroadcastReceiver() {
        val filter = IntentFilter().apply {
            addAction(CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND)
            // 带动作后缀的变体：部分固件按整条 action 下发而不是用 extra。
            addAction("${CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND}.next")
            addAction("${CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND}.previous")
            addAction("${CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND}.togglepause")
            addAction("${CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND}.pause")
            addAction("${CarMediaBroadcastReceiver.ACTION_SERVICE_COMMAND}.play")
            addAction(Intent.ACTION_MEDIA_BUTTON)
        }
        val receiver = CarMediaBroadcastReceiver()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    private fun setupNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 清理旧版本渠道：未分流的单一播放渠道 + kgka 改名前的手机/车机
        // 渠道（避免老车机缓存旧配置、通知设置里新旧并存）。
        // 新渠道 ID 与 Dart 侧 resolvePlaybackNotificationChannel 一一对应。
        LEGACY_CHANNEL_IDS.forEach(notificationManager::deleteNotificationChannel)

        // 手机端标准媒体渠道：IMPORTANCE_LOW，无提示音无震动，支持下拉通知中心、
        // 锁屏卡片与状态栏胶囊（灵动岛/流体云）。
        // 仅在缺失时创建：渠道重要性等设置一旦创建即归用户所有，不得覆盖用户改过的配置。
        if (notificationManager.getNotificationChannel(PHONE_PLAYBACK_CHANNEL_ID) == null) {
            notificationManager.createNotificationChannel(
                NotificationChannel(
                    PHONE_PLAYBACK_CHANNEL_ID,
                    "时音 播放控制",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "后台音乐播放服务与通知中心控制"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(false)
                }
            )
        }

        // 车机端静默渠道：IMPORTANCE_MIN，杜绝 heads-up 顶部弹窗。
        // 渠道重要性创建后无法程序化下调；若已被 audio_service 以 IMPORTANCE_LOW
        // 预建（服务先于本方法运行的路径），删除重建为 MIN。仅修正 LOW 这一种
        // 插件默认值，用户主动选择的其他等级（含手动关闭）不动。
        val carChannel = notificationManager.getNotificationChannel(CAR_PLAYBACK_CHANNEL_ID)
        if (carChannel == null || carChannel.importance == NotificationManager.IMPORTANCE_LOW) {
            if (carChannel != null) {
                notificationManager.deleteNotificationChannel(CAR_PLAYBACK_CHANNEL_ID)
            }
            notificationManager.createNotificationChannel(
                NotificationChannel(
                    CAR_PLAYBACK_CHANNEL_ID,
                    "时音 车机播放控制",
                    NotificationManager.IMPORTANCE_MIN
                ).apply {
                    description = "车机静默后台音乐播放服务（防顶部弹窗）"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(false)
                }
            )
        }
    }

    companion object {
        // 渠道 ID 与 Dart 侧 resolvePlaybackNotificationChannel
        // （lib/services/music_audio_handler.dart）一一对应，改动需双端同步
        const val PHONE_PLAYBACK_CHANNEL_ID = "shiyin_music.playback_phone"
        const val CAR_PLAYBACK_CHANNEL_ID = "shiyin_music.playback_car"

        // kgka 时代的旧渠道 ID，启动时统一删除（delete 不存在的渠道为空操作）
        private val LEGACY_CHANNEL_IDS = listOf(
            "kgka_music_hl.playback",
            "kgka_music_hl.playback_phone",
            "kgka_music_hl.playback_car",
        )
    }
}
