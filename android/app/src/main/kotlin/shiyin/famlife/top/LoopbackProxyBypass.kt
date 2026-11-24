package shiyin.famlife.top

import android.util.Log
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * 让回环地址的 HTTP 连接绕过系统代理。
 *
 * 背景（2026-11-24 小米 8 / Android 10 实测）：播放器（just_audio → media3
 * DefaultHttpDataSource → HttpURLConnection）取流的地址是本进程的本地代理
 * `http://127.0.0.1:<port>/play/<seq>.mp3`（见 Dart 侧
 * MusicAudioHandler._loadViaProxy）。HttpURLConnection 默认走系统代理；WiFi 上
 * 配了 HTTP 代理（Clash / v2ray 的「系统代理」、公司代理）且排除列表为空时，
 * 这个回环地址的请求会被发给代理服务器，代理去连**它自己那台机器**上的
 * 127.0.0.1，必然失败并回 502。
 *
 * 表现：歌名、图片都正常（走 Dart / Rust，不读系统代理，直连），唯独歌曲放不
 * 出来，日志是 `Source error — Response code: 502`；换流量（没有代理配置）
 * 即恢复。是否豁免回环地址取决于 ROM 的 ProxySelector 实现，不能依赖。
 *
 * 修法：进程内包一层全局 ProxySelector——回环地址一律返回「不走代理」，其余
 * 地址原样交给系统默认实现。播放器每次建连都从 ProxySelector.getDefault()
 * 取代理，必须在任何播放器实例创建之前安装（MusicApplication.onCreate）。
 */
object LoopbackProxyBypass {

    private const val TAG = "ShiyinProxy"

    fun install() {
        val delegate = ProxySelector.getDefault() ?: return
        if (delegate is LoopbackAware) return
        ProxySelector.setDefault(LoopbackAware(delegate))
        Log.i(
            TAG,
            "已安装回环地址代理豁免；系统代理 http=${System.getProperty("http.proxyHost")} " +
                "https=${System.getProperty("https.proxyHost")}"
        )
    }

    /**
     * 主机是否为回环地址：localhost / *.localhost，或 127.0.0.0/8、::1 的 IP 字面量。
     *
     * 只认字面量、绝不触发 DNS：select() 跑在播放器的建连线程上，一次解析的
     * 阻塞就是一次加载超时。认不准的写法一律按「非回环」处理，交给系统默认逻辑。
     */
    fun isLoopbackHost(host: String?): Boolean {
        if (host.isNullOrEmpty()) return false
        if (host.equals("localhost", ignoreCase = true)) return true
        // *.localhost：点号前必须有内容，光秃秃的 ".localhost" 不是主机名。
        val lastDot = host.lastIndexOf('.')
        if (lastDot > 0 && host.substring(lastDot + 1).equals("localhost", ignoreCase = true)) {
            return true
        }
        // URI.getHost() 对 IPv6 字面量带方括号。
        val literal = host.removePrefix("[").removeSuffix("]")
        return when {
            literal.contains(':') -> isIpv6Loopback(literal)
            else -> isIpv4Loopback(literal)
        }
    }

    /**
     * 点分四段的 127.x.x.x。四段都必须是不带前导零、不超过 255 的十进制数才算
     * 字面量：`0127.0.0.1`、`127.1` 这类写法是否合法各版本 JVM 口径不一，
     * 交给默认逻辑。
     */
    private fun isIpv4Loopback(literal: String): Boolean {
        val parts = literal.split('.')
        if (parts.size != 4) return false
        if (parts.any { part -> !isDecimalOctet(part) }) return false
        return parts[0].toInt() == 127
    }

    private fun isDecimalOctet(part: String): Boolean {
        if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return false
        if (part.length > 1 && part.startsWith('0')) return false
        return part.toInt() <= 255
    }

    /**
     * 含冒号的主机名只可能是 IPv6 字面量：JVM 对这种输入只做字面量解析，
     * 解析失败直接抛异常，不会退化成 DNS 查询。
     */
    private fun isIpv6Loopback(literal: String): Boolean =
        runCatching { InetAddress.getByName(literal).isLoopbackAddress }.getOrDefault(false)

    /** 仅供单测：用任意默认实现构造包装层（install() 依赖进程全局状态与 android.util.Log）。 */
    internal fun wrap(delegate: ProxySelector): ProxySelector = LoopbackAware(delegate)

    private class LoopbackAware(private val delegate: ProxySelector) : ProxySelector() {

        override fun select(uri: URI?): List<Proxy> {
            if (isLoopbackHost(uri?.host)) return listOf(Proxy.NO_PROXY)
            return delegate.select(uri)
        }

        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {
            delegate.connectFailed(uri, sa, ioe)
        }
    }
}
