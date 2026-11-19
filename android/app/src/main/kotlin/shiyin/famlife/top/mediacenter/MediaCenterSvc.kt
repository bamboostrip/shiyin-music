package shiyin.famlife.top.mediacenter

import android.os.IBinder
import android.os.Parcel

/**
 * IMediaCenterSvc 的 AIDL Proxy（issue #15）。
 *
 * 通过 [EasTransport.mediaCenterBinder] 拿到媒体中心主 Binder 后，本类用
 * 标准 AIDL Parcel 布局直接调用它。契约（接口 descriptor 与 transaction
 * code）属于跨进程接口规格，移植自 jessehoo89/lx-music-flyme_auto
 * （Apache-2.0，实车验证），实现为独立编写。
 *
 * 调用模式：writeInterfaceToken(DESCRIPTOR) + [writeStrongBinder(token) +
 * 参数] + transact(code, data, reply, 0) + readException() + 读返回值。
 * 只保留本仓用到的入口：注册 / 注销 / 抢焦点 / 状态上行 / 进度歌词 /
 * 焦点查询 / 恢复监听。
 */
class MediaCenterSvc(private val remote: IBinder) {

    companion object {
        const val DESCRIPTOR = "ecarx.xsf.mediacenter.IMediaCenterSvc"

        // IMediaCenterSvc transaction codes（完整 44 项见移植源协议笔记）。
        private const val T_UNREGISTER = 4
        private const val T_REQUEST_PLAY = 5
        private const val T_UPDATE_MUSIC_PLAYBACK_STATE = 6
        private const val T_UPDATE_MEDIA_SOURCE_TYPE_LIST = 7
        private const val T_UPDATE_CURRENT_SOURCE_TYPE = 8
        private const val T_UPDATE_CURRENT_PROGRESS = 10
        private const val T_UPDATE_CURRENT_LYRIC = 14
        private const val T_REGISTER_IN_MUSIC = 19
        private const val T_GET_STATE_BINDER = 31
        private const val T_QUERY_CURRENT_FOCUS_CLIENT = 42

        /** IStateRecoverApiSvc（getStateBinder 返回）的 descriptor 与事务码。 */
        const val STATE_DESCRIPTOR =
            "ecarx.xsf.mediacenter.staterecover.IStateRecoverApiSvc"
        const val LISTENER_DESCRIPTOR =
            "ecarx.xsf.mediacenter.staterecover.IMusicRecoveryListener"
        private const val S_SET_RECOVERY_CALLBACK = 5
    }

    fun alive(): Boolean = remote.isBinderAlive

    private fun <T> transact(
        code: Int,
        filler: ((Parcel) -> Unit)?,
        reader: ((Parcel) -> T)?,
    ): T? {
        if (!alive()) {
            return null
        }
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            filler?.invoke(data)
            if (!remote.transact(code, data, reply, 0)) {
                return null
            }
            reply.readException()
            reader?.invoke(reply)
        } catch (t: Throwable) {
            CarMediaCenterLog.log("[mcsvc] transact code=$code 失败: $t")
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    // ------------------------------------------------------------ 注册 / 注销

    /**
     * registerInMusic(String pkg, IMusicClient) → IMediaCenterClientToken
     * （code=19）。注册入口：包名从这里带进去，服务端据此把「音源条目」
     * 与客户端对上——方向盘按键只会派给当前焦点音源对应的客户端。
     */
    fun registerInMusic(pkg: String, client: IBinder): IBinder? {
        if (pkg.isEmpty()) {
            return null
        }
        return transact(
            T_REGISTER_IN_MUSIC,
            { d ->
                d.writeString(pkg)
                d.writeStrongBinder(client)
            },
            { r -> r.readStrongBinder() },
        )
    }

    /** unregister(IMediaCenterClientToken) → boolean（code=4）。 */
    fun unregister(token: IBinder): Boolean? {
        return transact(
            T_UNREGISTER,
            { d -> d.writeStrongBinder(token) },
            { r -> r.readInt() != 0 },
        )
    }

    // ------------------------------------------------------------ 焦点 / 音源

    /** requestPlay(token) → boolean（code=5）：抢媒体焦点，方控按键的归属权。 */
    fun requestPlay(token: IBinder): Boolean? {
        return transact(
            T_REQUEST_PLAY,
            { d -> d.writeStrongBinder(token) },
            { r -> r.readInt() != 0 },
        )
    }

    /** queryCurrentFocusClient(token) → String（code=42）：当前焦点音源包名。 */
    fun queryCurrentFocusClient(token: IBinder): String? {
        return transact(
            T_QUERY_CURRENT_FOCUS_CLIENT,
            { d -> d.writeStrongBinder(token) },
            { r -> r.readString() },
        )
    }

    fun updateCurrentSourceType(token: IBinder, type: Int) {
        transact<Unit>(
            T_UPDATE_CURRENT_SOURCE_TYPE,
            { d ->
                d.writeStrongBinder(token)
                d.writeInt(type)
            },
            null,
        )
    }

    fun updateMediaSourceTypeList(token: IBinder, types: IntArray) {
        transact<Unit>(
            T_UPDATE_MEDIA_SOURCE_TYPE_LIST,
            { d ->
                d.writeStrongBinder(token)
                d.writeIntArray(types)
            },
            null,
        )
    }

    // ------------------------------------------------------------ 数据上行（push）

    /**
     * updateMusicPlaybackState(token, IMusicPlaybackInfo)（code=6）。
     * 第二个参数是 Binder 接口，服务端拿到后会回调 Info 的 33 个 getter，
     * 上行播放信息不需要任何 Parcelable。
     */
    fun updateMusicPlaybackState(token: IBinder, info: IBinder): Boolean? {
        return transact(
            T_UPDATE_MUSIC_PLAYBACK_STATE,
            { d ->
                d.writeStrongBinder(token)
                d.writeStrongBinder(info)
            },
            { r -> r.readInt() != 0 },
        )
    }

    fun updateCurrentProgress(token: IBinder, positionMs: Long) {
        transact<Unit>(
            T_UPDATE_CURRENT_PROGRESS,
            { d ->
                d.writeStrongBinder(token)
                d.writeLong(positionMs)
            },
            null,
        )
    }

    fun updateCurrentLyric(token: IBinder, lyric: String) {
        transact<Unit>(
            T_UPDATE_CURRENT_LYRIC,
            { d ->
                d.writeStrongBinder(token)
                d.writeString(lyric)
            },
            null,
        )
    }

    // ------------------------------------------------------------ 恢复监听

    /** getStateBinder() → IStateRecoverApiSvc（code=31）。 */
    fun stateBinder(): IBinder? {
        return transact(T_GET_STATE_BINDER, null) { r -> r.readStrongBinder() }
    }

    /**
     * setMusicRecoveryCallback(token, listener)（code=5）：车机「恢复上次
     * 音源」时回调 listener（code=2 = 请求播放信息 → 立即补推一次状态）。
     */
    fun setRecoveryCallback(token: IBinder, listener: IBinder): Boolean? {
        val state = stateBinder() ?: run {
            CarMediaCenterLog.log("[nfull] 拿不到 IStateRecoverApiSvc，恢复回调未注册")
            return null
        }
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(STATE_DESCRIPTOR)
            data.writeStrongBinder(token)
            data.writeStrongBinder(listener)
            if (!state.transact(S_SET_RECOVERY_CALLBACK, data, reply, 0)) {
                return null
            }
            reply.readException()
            reply.readInt() != 0
        } catch (t: Throwable) {
            CarMediaCenterLog.log("[nfull] setRecoveryCallback 失败: $t")
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
