package shiyin.famlife.top.mediacenter

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Parcelable
import android.app.PendingIntent
import android.net.Uri

/**
 * IMusicClient / IMusicPlaybackInfo Binder 实现（issue #15）——方向盘
 * 按键的真正入口。
 *
 * 媒体中心注册音源时只拿到我们给的一个 Binder，之后两个方向都在 Binder 上：
 *  1) 服务端主动来取数据（pull）：IMusicClient.getMusicPlaybackInfo() 返回
 *     另一个 Binder，服务端再在它上面逐个调 getter 拿曲目/进度/歌词；
 *  2) 服务端下发控制（cmd）：onPlay / onPause / onNext / onPrevious /
 *     onSourceSelected / onMediaCenterFocusChanged …——方向盘与扶手箱的
 *     播放键就是从这些回调下发的。
 *
 * 手写 onTransact 只用 IBinder/Parcel 公开 API；接口 descriptor 与
 * transaction code 属于跨进程接口规格，移植自 jessehoo89/
 * lx-music-flyme_auto（Apache-2.0，实车验证），实现为独立编写。
 *
 * reply 布局（与标准 AIDL 生成代码一致）：
 *   void    -> writeNoException()
 *   boolean -> writeNoException() + writeInt(0/1)
 *   int     -> writeNoException() + writeInt
 *   long    -> writeNoException() + writeLong
 *   String  -> writeNoException() + writeString
 *   Uri / PendingIntent -> writeNoException() + writeInt(0)=null
 *                           或 writeInt(1) + writeToParcel(reply, 1)
 *   IBinder 接口 -> writeNoException() + writeStrongBinder
 *   List    -> writeNoException() + writeTypedList
 */
class MusicClientBinder {

    /** ecarx.xsf.mediacenter.IMusicClient */
    private val clientDescriptor = "ecarx.xsf.mediacenter.IMusicClient"

    /** ecarx.xsf.mediacenter.IMusicPlaybackInfo */
    private val infoDescriptor = "ecarx.xsf.mediacenter.IMusicPlaybackInfo"

    // ---- IMusicClient.transaction（服务端 → 我们）
    private val cOnPlay = 1
    private val cOnPause = 2
    private val cOnNext = 3
    private val cOnPrevious = 4
    private val cOnForward = 5
    private val cOnRewind = 6
    private val cOnLoopModeChange = 7
    private val cOnSourceSelected = 8
    private val cOnMediaSelected = 9
    private val cGetMusicPlaybackInfo = 10
    private val cGetMediaSourceTypeList = 11
    private val cGetCurrentSourceType = 12
    private val cGetCurrentProgress = 13
    private val cGetPlaylist = 14
    private val cOnCollect = 15
    private val cOnDownload = 16
    private val cOnSourceChanged = 17
    private val cOnReplay = 18
    private val cOnMediaSelectedPlay = 21
    private val cOnMediaForward = 22
    private val cOnMediaRewind = 23
    private val cOnMediaQualityChange = 24
    private val cOnMediaCenterFocusChanged = 25
    private val cOnExit = 26
    private val cSelectListMediaPlay = 27
    private val cGetContentList = 28
    private val cGetMultiMediaList = 29
    private val cCtrlPlayMediaList = 30
    private val cCtrlPauseMediaList = 31
    private val cOperationType = 33

    // ---- IMusicPlaybackInfo.transaction（服务端 → 我们，逐个 getter）
    private val iGetLaunchIntent = 1
    private val iGetTitle = 2
    private val iGetArtist = 3
    private val iGetAlbum = 4
    private val iGetRadioFrequency = 5
    private val iGetRadioStationName = 6
    private val iGetDuration = 7
    private val iGetPositionInQueue = 8
    private val iGetSourceType = 9
    private val iGetMediaPath = 10
    private val iGetPlaybackStatus = 11
    private val iGetLyricContent = 12
    private val iGetLyric = 13
    private val iGetCurrentLyricSentence = 14
    private val iGetPreviousArtwork = 15
    private val iGetArtwork = 16
    private val iGetNextArtwork = 17
    private val iGetLoopMode = 18
    private val iGetRadioMode = 19
    private val iIsSupportCollect = 20
    private val iIsCollected = 21
    private val iIsSupportDownload = 22
    private val iIsDownloaded = 23
    private val iGetUuid = 24
    private val iGetAppName = 25
    private val iGetAppIcon = 26
    private val iGetPackageName = 27
    private val iIsSupportLoopModeSwitch = 28
    private val iIsSupportVrCtrlPlayStatus = 29
    private val iGetPlayingMediaListId = 30
    private val iGetVip = 31
    private val iGetPlayingMediaListType = 32
    private val iGetPlayerIntent = 33

    /**
     * 播放状态枚举——媒体中心自己的取值，**不是** MediaSession.PlaybackState：
     * PAUSED=0、PLAYING=1、INTERRUPT=2、PREPARE=3。
     *
     * 易踩坑：按 MediaSession 的 2/3 去填，2 会变成「被中断」、3 变成
     * 「准备中」，车机据此认为音源没准备好——表现就是 HUD 一直「正在
     * 加载」、方向盘与扶手箱的播放键全部失效。
     */
    private val statusPaused = 0
    private val statusPlaying = 1

    /** 仅供日志：车机 pull 到的播放态变化时打一条。 */
    private var lastReportedStatus = -1

    private val info = InfoBinder()
    private val client = ClientBinder()

    /** 传给 IMediaCenterSvc.registerInMusic(19) 的 Binder。 */
    fun asBinder(): IBinder = client

    /** 传给 IMediaCenterSvc.updateMusicPlaybackState(6) 的播放信息 Binder。 */
    fun infoBinder(): IBinder = info

    private fun writeUri(reply: Parcel, uri: Uri?) {
        if (uri == null) {
            reply.writeInt(0)
        } else {
            reply.writeInt(1)
            uri.writeToParcel(reply, 1)
        }
    }

    private fun writePendingIntent(reply: Parcel, pi: PendingIntent?) {
        if (pi == null) {
            reply.writeInt(0)
        } else {
            reply.writeInt(1)
            pi.writeToParcel(reply, 1)
        }
    }

    // ---------------------------------------------------------------- IMusicPlaybackInfo

    /**
     * 播放信息 Binder：媒体中心在 updateMusicPlaybackState 后回调这里的
     * 33 个 getter 拉数据。全部只读 [CarNowPlaying]，无阻塞操作。
     */
    private inner class InfoBinder : Binder() {
        override fun getInterfaceDescriptor(): String = infoDescriptor

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(infoDescriptor)
                return true
            }
            data?.let { runCatching { it.enforceInterface(infoDescriptor) } }
            if (reply == null) {
                return true
            }
            when (code) {
                iGetLaunchIntent, iGetPlayerIntent -> {
                    reply.writeNoException()
                    writePendingIntent(reply, CarNowPlaying.launchIntent)
                }
                iGetTitle -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.title)
                }
                iGetArtist -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.artist)
                }
                iGetAlbum -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.album)
                }
                iGetRadioFrequency, iGetRadioStationName -> {
                    reply.writeNoException()
                    reply.writeString("")
                }
                iGetDuration -> {
                    reply.writeNoException()
                    reply.writeLong(CarNowPlaying.durationMs)
                }
                iGetPositionInQueue, iGetRadioMode, iGetVip, iGetPlayingMediaListType -> {
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                iGetSourceType -> {
                    reply.writeNoException()
                    reply.writeInt(CarMediaCenterBridge.SOURCE_ONLINE)
                }
                iGetMediaPath, iGetLyric, iGetPreviousArtwork, iGetNextArtwork -> {
                    reply.writeNoException()
                    reply.writeInt(0) // null
                }
                iGetPlaybackStatus -> {
                    reply.writeNoException()
                    val reported =
                        if (CarNowPlaying.playing) statusPlaying else statusPaused
                    if (reported != lastReportedStatus) {
                        lastReportedStatus = reported
                        CarMediaCenterLog.log(
                            "[状态上行] getPlaybackStatus → $reported" +
                                if (reported == statusPlaying) " (PLAYING)" else " (PAUSED)",
                        )
                    }
                    reply.writeInt(reported)
                }
                iGetLyricContent -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.lyric ?: "")
                }
                iGetCurrentLyricSentence -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.lyricLine ?: "")
                }
                iGetArtwork -> {
                    reply.writeNoException()
                    writeUri(reply, CarNowPlaying.artworkUri())
                }
                iGetLoopMode -> {
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                iIsSupportCollect, iIsCollected, iIsSupportDownload, iIsDownloaded,
                iIsSupportLoopModeSwitch, iIsSupportVrCtrlPlayStatus,
                -> {
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                iGetUuid -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.uuid())
                }
                iGetAppName -> {
                    reply.writeNoException()
                    reply.writeString(CarMediaCenterBridge.APP_NAME)
                }
                iGetAppIcon -> {
                    reply.writeNoException()
                    reply.writeString(CarNowPlaying.appIcon ?: "")
                }
                iGetPackageName -> {
                    reply.writeNoException()
                    reply.writeString(CarMediaCenterBridge.appPkg())
                }
                iGetPlayingMediaListId -> {
                    reply.writeNoException()
                    // 本仓不上行播放列表（无音源列表注入），列表 id 留空。
                    reply.writeString("")
                }
                else -> {
                    // 固件的接口版本可能比已知更新（实测出现过 34/35）：
                    // 记下来便于适配，避免静默失败看不出原因。
                    CarMediaCenterLog.log("[nmc] 未知 playback code=$code")
                    return false
                }
            }
            return true
        }
    }

    // ---------------------------------------------------------------- IMusicClient

    /**
     * 客户端 Binder：媒体中心在这里下发控制动作（方向盘/扶手箱按键）与
     * 数据拉取。控制动作统一交给 [CarMediaCenterBridge.onControl]，由它
     * 做外源焦点拦截后转发 Dart。
     */
    private inner class ClientBinder : Binder() {
        override fun getInterfaceDescriptor(): String = clientDescriptor

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(clientDescriptor)
                return true
            }
            data?.let { runCatching { it.enforceInterface(clientDescriptor) } }
            if (reply == null) {
                // oneway 场景：动作照做，但没有 reply 可写。
                when (code) {
                    cOnPlay -> CarMediaCenterBridge.onControl("play", "onPlay(oneway)")
                    cOnPause -> CarMediaCenterBridge.onControl("pause", "onPause(oneway)")
                    cOnNext -> CarMediaCenterBridge.onControl("next", "onNext(oneway)")
                    cOnPrevious -> CarMediaCenterBridge.onControl("previous", "onPrevious(oneway)")
                }
                return true
            }
            when (code) {
                // ------------------------------------------------ 服务端取数据
                cGetMusicPlaybackInfo -> {
                    CarMediaCenterBridge.notePull("getMusicPlaybackInfo")
                    reply.writeNoException()
                    reply.writeStrongBinder(info)
                }
                cGetMediaSourceTypeList -> {
                    CarMediaCenterBridge.notePull("getMediaSourceTypeList")
                    reply.writeNoException()
                    reply.writeIntArray(intArrayOf(CarMediaCenterBridge.SOURCE_ONLINE))
                }
                cGetCurrentSourceType -> {
                    CarMediaCenterBridge.notePull("getCurrentSourceType")
                    reply.writeNoException()
                    reply.writeInt(CarMediaCenterBridge.SOURCE_ONLINE)
                }
                cGetCurrentProgress -> {
                    CarMediaCenterBridge.notePull("getCurrentProgress")
                    reply.writeNoException()
                    reply.writeLong(CarMediaCenterBridge.currentProgressMs())
                }
                cGetPlaylist -> {
                    CarMediaCenterBridge.notePull("getPlaylist")
                    reply.writeNoException()
                    reply.writeTypedList(ArrayList<Parcelable>())
                }
                cGetContentList -> {
                    CarMediaCenterBridge.notePull("getContentList")
                    reply.writeNoException()
                    reply.writeTypedList(ArrayList<Parcelable>())
                }
                cGetMultiMediaList -> {
                    runCatching { data?.createIntArray() }
                    CarMediaCenterBridge.notePull("getMultiMediaList")
                    reply.writeNoException()
                    reply.writeInt(0) // IMediaLists = null
                }

                // ------------------------------------------------ 服务端下发动作
                cOnPlay -> {
                    CarMediaCenterBridge.noteCmd(code, "onPlay")
                    CarMediaCenterBridge.onControl("play", "onPlay")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnPause -> {
                    CarMediaCenterBridge.noteCmd(code, "onPause")
                    CarMediaCenterBridge.onControl("pause", "onPause")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnNext -> {
                    CarMediaCenterBridge.noteCmd(code, "onNext")
                    val handled = CarMediaCenterBridge.onControl("next", "onNext")
                    reply.writeNoException()
                    reply.writeInt(if (handled) 1 else 0)
                }
                cOnPrevious -> {
                    CarMediaCenterBridge.noteCmd(code, "onPrevious")
                    val handled = CarMediaCenterBridge.onControl("previous", "onPrevious")
                    reply.writeNoException()
                    reply.writeInt(if (handled) 1 else 0)
                }
                cOnReplay -> {
                    CarMediaCenterBridge.noteCmd(code, "onReplay")
                    CarMediaCenterBridge.onControl("play", "onReplay")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnForward, cOnMediaForward -> {
                    CarMediaCenterBridge.noteCmd(code, "onForward")
                    val handled = CarMediaCenterBridge.onControl("next", "onForward")
                    reply.writeNoException()
                    reply.writeInt(if (handled) 1 else 0)
                }
                cOnRewind, cOnMediaRewind -> {
                    CarMediaCenterBridge.noteCmd(code, "onRewind")
                    val handled = CarMediaCenterBridge.onControl("previous", "onRewind")
                    reply.writeNoException()
                    reply.writeInt(if (handled) 1 else 0)
                }
                cCtrlPlayMediaList -> {
                    runCatching { data?.readInt() }
                    CarMediaCenterBridge.noteCmd(code, "ctrlPlayMediaList")
                    CarMediaCenterBridge.onControl("play", "ctrlPlayMediaList")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cCtrlPauseMediaList -> {
                    runCatching { data?.readInt() }
                    CarMediaCenterBridge.noteCmd(code, "ctrlPauseMediaList")
                    CarMediaCenterBridge.onControl("pause", "ctrlPauseMediaList")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnSourceSelected -> {
                    var type = -1
                    runCatching { type = data?.readInt() ?: -1 }
                    CarMediaCenterBridge.noteCmd(code, "onSourceSelected type=$type")
                    // 用户手动切回本音源：走完整恢复链（重注册+补推）。
                    CarMediaCenterBridge.onUserSelectSource(type)
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnSourceChanged -> {
                    var type = -1
                    var id: String? = null
                    runCatching {
                        type = data?.readInt() ?: -1
                        id = data?.readString()
                    }
                    CarMediaCenterBridge.noteCmd(code, "onSourceChanged type=$type id=$id")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnMediaCenterFocusChanged -> {
                    var who: String? = null
                    runCatching { who = data?.readString() }
                    CarMediaCenterBridge.noteCmd(code, "onMediaCenterFocusChanged $who")
                    // 焦点变化交给桥接层：切到别的音源后靠它拦截误派的控制动作。
                    CarMediaCenterBridge.onMediaFocus(who)
                    reply.writeNoException()
                }
                cOnExit -> {
                    // 不真的退出：媒体中心切源会发这个，退出就没有音源了。
                    CarMediaCenterBridge.noteCmd(code, "onExit（忽略，不注销）")
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                cOnLoopModeChange, cOnMediaQualityChange -> {
                    runCatching { data?.readInt() }
                    CarMediaCenterBridge.noteCmd(code, "int 参数回调（不影响播控）")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOperationType -> {
                    runCatching { data?.readInt() }
                    CarMediaCenterBridge.noteCmd(code, "operationType")
                    reply.writeNoException()
                }
                cSelectListMediaPlay -> {
                    runCatching {
                        data?.readInt()
                        data?.readInt()
                        data?.readString()
                    }
                    CarMediaCenterBridge.noteCmd(code, "selectListMediaPlay")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnMediaSelectedPlay -> {
                    runCatching {
                        data?.readInt()
                        data?.readString()
                    }
                    CarMediaCenterBridge.noteCmd(code, "onMediaSelectedPlay")
                    reply.writeNoException()
                    reply.writeInt(1)
                }
                cOnCollect, cOnDownload -> {
                    runCatching {
                        data?.readInt()
                        data?.readInt()
                    }
                    CarMediaCenterBridge.noteCmd(code, "onCollect/onDownload（未声明能力）")
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                cOnMediaSelected -> {
                    // 参数是设备侧 Parcelable/Binder 数据对象，不解析直接拒绝。
                    CarMediaCenterBridge.noteCmd(code, "旧式媒体对象回调（未解析）")
                    reply.writeNoException()
                    reply.writeInt(0)
                }
                else -> {
                    CarMediaCenterLog.log("[nmc] 未知 transaction code=$code")
                    return false
                }
            }
            return true
        }
    }
}
