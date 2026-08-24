package shiyin.famlife.top

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

class MusicApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        setupNotificationChannels()
    }

    private fun setupNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 清理旧版本未分流渠道（避免老车机缓存了旧配置）
        notificationManager.deleteNotificationChannel(OLD_PLAYBACK_CHANNEL_ID)

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
        const val OLD_PLAYBACK_CHANNEL_ID = "kgka_music_hl.playback"
        const val PHONE_PLAYBACK_CHANNEL_ID = "kgka_music_hl.playback_phone"
        const val CAR_PLAYBACK_CHANNEL_ID = "kgka_music_hl.playback_car"
    }
}
