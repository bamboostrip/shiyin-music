package shiyin.famlife.top.mediacenter

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel

/**
 * EAS Framework 传输层（issue #15，Flyme Auto 方向盘切歌）。
 *
 * Flyme Auto（ECARX 平台）的方向盘按键不走 Android 标准 KeyEvent /
 * MediaSession 媒体键路由，而是由系统私有「媒体中心」下发——接入媒体
 * 中心的第一步是连上 EAS Framework 服务：系统内置 `com.ecarx.sdk.openapi`
 * 暴露的 `com.ecarx.easframework.intent.action.EASFRAMEWORK` 服务。
 * 之后所有调用都是手工拼 [Parcel]（IEASFrameworkService.call 的线上格式），
 * 只用 Android 公开 API，不依赖任何预编译组件。
 *
 * request Parcel（IEASFrameworkService.call(EASFrameworkMessage)）：
 *   writeInterfaceToken(descriptor) + writeInt(1) + service + module + method
 *   + writeByteArray(methodParam) + writeByteArray(attachParam)
 *   （asyncBinderCall 再追加一个 writeStrongBinder(extra)）
 * response Parcel（EASFrameworkRetMessage / SupportServiceRetMessage）：
 *   readException + int(hasResult) + int(code) + String(msg) + byte[](attachInfo)
 *   + String(retClassName) + [int(code) + String(msg) + byte[](data) + IBinder]
 * 两层 code 均为 200 时取 data；mBinder 供取主 Binder（getMainBinder）。
 *
 * 协议契约与 transaction code（call=4 / asyncBinderCall=6，2026-11-06
 * 实车确认）移植自 jessehoo89/lx-music-flyme_auto（Apache-2.0，实车
 * 验证过的逆向实现）；固件升级后若失效会自动扫描 1..40 自发现。
 *
 * 非 ECARX 车机/手机上 bindService 直接失败，本类整体休眠，零副作用。
 */
object EasTransport {
    private const val ACTION = "com.ecarx.easframework.intent.action.EASFRAMEWORK"
    private const val SERVICE_PKG = "com.ecarx.sdk.openapi"

    /** IEASFrameworkService.call 的 transaction code（实车确认，可自发现覆盖）。 */
    private const val DEFAULT_CALL_CODE = 4

    /** IEASFrameworkService.asyncBinderCall 的 transaction code。 */
    private const val ASYNC_BINDER_CODE = 6

    /** 只读探针请求：protobuf zoneId=0，用于自发现 transaction code。 */
    private val PROBE_REQ = byteArrayOf(0x08, 0x00)
    private val EMPTY_ATTACH = ByteArray(0)

    @Volatile
    private var binder: IBinder? = null

    /** 本进程是否成功连上过 EAS Framework（哪怕后来断开）。
     * 桥接层用它区分「ECARX 车机服务重启要自愈」与「手机上根本没有这
     * 服务、别反复重试刷日志」。 */
    @Volatile
    var everConnected = false
        private set

    @Volatile
    private var descriptor: String? = null

    /** 自发现结果；0 表示尚未发现（用 [DEFAULT_CALL_CODE]）。 */
    @Volatile
    private var callCode = 0

    @Volatile
    private var bound = false

    private val lock = Any()

    /** 通用 RPC 结果：SupportServiceRetMessage 的 mData 与 mBinder。 */
    private class Ret(val data: ByteArray?, val binder: IBinder?)

    /** 上次 bindService 失败的留痕：手机/非 ECARX 车机只记一次，避免刷屏。 */
    @Volatile
    private var bindFailedLogged = false

    /** 幂等连接，最多等 3 秒；主线程调用方需自行放后台线程。 */
    fun connectAndWait(ctx: Context?): Boolean {
        if (!ready()) {
            if (ctx == null) {
                return false
            }
            if (!bound) {
                synchronized(lock) {
                    if (!bound) {
                        val ok = runCatching {
                            val intent = Intent(ACTION).setPackage(SERVICE_PKG)
                            ctx.applicationContext.bindService(
                                intent,
                                conn,
                                Context.BIND_AUTO_CREATE,
                            )
                        }.getOrDefault(false)
                        bound = ok
                        if (!ok) {
                            if (!bindFailedLogged) {
                                bindFailedLogged = true
                                CarMediaCenterLog.log(
                                    "[eas] bindService 失败（非 ECARX 车机属预期，特性休眠）",
                                )
                            }
                            return false
                        }
                        CarMediaCenterLog.log("[eas] bindService $ACTION -> true")
                    }
                }
            }
            val deadline = System.currentTimeMillis() + 3000L
            while (binder == null && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(50L)
                } catch (_: InterruptedException) {
                }
            }
        }
        return ready()
    }

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            binder = service
            everConnected = true
            descriptor = runCatching { service?.interfaceDescriptor }.getOrNull()
            CarMediaCenterLog.log("[eas] 已连接 descriptor=$descriptor")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            binder = null
            bound = false
            CarMediaCenterLog.log("[eas] 服务断开，下次调用会重新 bind")
        }
    }

    fun ready(): Boolean {
        val b = binder ?: return false
        return b.isBinderAlive
    }

    /** 取媒体中心主 Binder（IMediaCenterSvc）的通用 RPC 入口。
     *
     * 默认 transaction code 失败（固件升级换了 code）时清缓存自发现
     * （扫描 1..40 的只读探针）后重试一次——移植源把这段自发现放在
     * call() 通用路径里，本仓只有这一个入口需要它。
     */
    fun mediaCenterBinder(): IBinder? {
        if (!connectAndWait(CarMediaCenterBridge.appContext())) {
            return null
        }
        val r = transact(
            effectiveCallCode(),
            "mediacenter",
            "MediaCenterAPI",
            "getMainBinder",
            "NoParam".toByteArray(),
            EMPTY_ATTACH,
            null,
        )
        if (r?.binder != null) {
            return r.binder
        }
        callCode = 0
        val found = discover()
        if (found > 0) {
            val retry = transact(
                found,
                "mediacenter",
                "MediaCenterAPI",
                "getMainBinder",
                "NoParam".toByteArray(),
                EMPTY_ATTACH,
                null,
            )
            return retry?.binder
        }
        return null
    }

    /**
     * IEASFrameworkService.asyncBinderCall(message, extraBinder)——比通用
     * call 多一个 Binder 参数，用于把 token / 回调交给服务端（updateZoneId、
     * registerEx 走这里）。
     */
    fun asyncBinderCall(
        service: String,
        module: String,
        method: String,
        param: ByteArray,
        extra: IBinder,
    ): Boolean {
        if (!connectAndWait(CarMediaCenterBridge.appContext())) {
            return false
        }
        val r = transact(
            ASYNC_BINDER_CODE,
            service,
            module,
            method,
            param,
            EMPTY_ATTACH,
            extra,
        )
        return r != null
    }

    /** 扫描 1..40，找到能返回合法 mData 的 transaction code 并缓存。 */
    private fun discover(): Int {
        val cached = callCode
        if (cached > 0) {
            return cached
        }
        synchronized(lock) {
            if (callCode > 0) {
                return callCode
            }
            if (binder == null) {
                return 0
            }
            for (c in 1..40) {
                val r = transact(
                    c,
                    "mediacenter",
                    "media_session_controller",
                    "getAppSourceConfig",
                    PROBE_REQ,
                    null,
                    null,
                )
                if (r?.data != null && r.data.isNotEmpty()) {
                    callCode = c
                    CarMediaCenterLog.log(
                        "[eas] 自发现 transaction code=$c，探针返回 " +
                            "${r.data.size}B（后续复用）",
                    )
                    return c
                }
            }
        }
        CarMediaCenterLog.log("[eas] 未自发现 transaction code")
        return 0
    }

    private fun effectiveCallCode(): Int {
        // 保留手动覆盖入口（对齐移植源的 carproxy_eas_call_code），真机
        // 固件异常时可 adb settings 指定，无需发版。
        val manual = runCatching {
            android.provider.Settings.Global.getInt(
                CarMediaCenterBridge.appContext()?.contentResolver,
                "shiyin_eas_call_code",
                0,
            )
        }.getOrDefault(0)
        if (manual > 0) {
            return manual
        }
        return if (callCode > 0) callCode else DEFAULT_CALL_CODE
    }

    /** 线上格式与 reply 解析见类注释；任何异常都按调用失败处理返回 null。 */
    private fun transact(
        code: Int,
        service: String,
        module: String,
        method: String,
        param: ByteArray,
        attach: ByteArray?,
        extra: IBinder?,
    ): Ret? {
        val b = binder ?: return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            descriptor?.let { data.writeInterfaceToken(it) }
            data.writeInt(1) // Parcelable 参数非 null
            data.writeString(service)
            data.writeString(module)
            data.writeString(method)
            data.writeByteArray(param)
            // attach 原样透传：null 写成长度 -1（与移植源一致）；线上路径
            // 实际都传 EMPTY_ATTACH（长度 0）。
            data.writeByteArray(attach)
            extra?.let { data.writeStrongBinder(it) }
            check(b.transact(code, data, reply, 0)) { "transact($code) 返回 false" }
            reply.readException()
            check(reply.readInt() != 0) { "_result == null" }
            val topCode = reply.readInt()
            reply.readString() // mMsg
            reply.createByteArray() // mAttachInfo
            val retCls = reply.readString() // writeParcelable 写的类名
            if (retCls == null || topCode != 200) {
                CarMediaCenterLog.log("[eas] $method 失败 topCode=$topCode retCls=$retCls")
                null
            } else {
                val subCode = reply.readInt()
                reply.readString() // SupportServiceRetMessage.mMsg
                val payload = reply.createByteArray() // mData
                val sub = reply.readStrongBinder() // mBinder（第二阶段入口）
                if (subCode != 200) {
                    CarMediaCenterLog.log("[eas] $method 失败 subCode=$subCode")
                    null
                } else {
                    Ret(payload, sub)
                }
            }
        } catch (t: Throwable) {
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
