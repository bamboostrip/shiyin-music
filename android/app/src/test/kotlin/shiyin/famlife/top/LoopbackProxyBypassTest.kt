package shiyin.famlife.top

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * 回环地址代理豁免的纯逻辑单测。判错的两个方向都有代价：
 * 把回环判成非回环 = 修复无效（WiFi 代理下歌曲放不出来）；
 * 把公网主机判成回环 = 悄悄绕过了用户的代理。
 */
class LoopbackProxyBypassTest {

    @Test
    fun `IPv4 回环段都是回环`() {
        for (host in listOf("127.0.0.1", "127.0.0.2", "127.255.255.254", "127.1.2.3")) {
            assertTrue(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `localhost 主机名大小写与子域都算回环`() {
        for (host in listOf("localhost", "LOCALHOST", "Localhost", "a.localhost", "x.y.localhost")) {
            assertTrue(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `IPv6 回环字面量带不带方括号都算回环`() {
        for (host in listOf("::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]", "::ffff:127.0.0.1")) {
            assertTrue(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `公网地址与域名一律不算回环`() {
        for (host in listOf(
            "192.168.1.223", "0.0.0.0", "126.255.255.255", "128.0.0.1",
            "gateway.kugou.com", "imge.kugou.com", "trackercdn.kugou.com",
            "192.168.0.1:8080", "fe80::1", "[fe80::1]", "::ffff:192.168.1.1",
        )) {
            assertFalse(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `伪装成回环的主机名不算回环`() {
        for (host in listOf("localhost.kugou.com", "127.0.0.1.kugou.com", "a-localhost", "xlocalhost", ".localhost")) {
            assertFalse(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `认不准的数字写法按非回环处理`() {
        for (host in listOf("127.1", "127", "1.2.3.4.5", "0127.0.0.1", "127.0.0.1.", ".127.0.0.1", "127.0.0.256", "127..0.1", "999.0.0.1")) {
            assertFalse(host, LoopbackProxyBypass.isLoopbackHost(host))
        }
    }

    @Test
    fun `空值与非 ASCII 不算回环`() {
        assertFalse(LoopbackProxyBypass.isLoopbackHost(null))
        assertFalse(LoopbackProxyBypass.isLoopbackHost(""))
        assertFalse(LoopbackProxyBypass.isLoopbackHost("本地主机"))
    }

    /** 记录调用情况、对任何地址都回同一个「走代理」列表的假默认实现。 */
    private class RecordingSelector : ProxySelector() {
        val answer = listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("192.168.1.223", 7890)))
        var selects = 0
        var connectFailures = 0

        override fun select(uri: URI?): List<Proxy> {
            selects++
            return answer
        }

        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {
            connectFailures++
        }
    }

    @Test
    fun `回环地址直接返回不走代理，且不惊动默认实现`() {
        val recording = RecordingSelector()
        val selector = LoopbackProxyBypass.wrap(recording)

        val proxies = selector.select(URI("http://127.0.0.1:37013/play/7.mp3"))

        assertEquals(listOf<Proxy>(Proxy.NO_PROXY), proxies)
        assertEquals(0, recording.selects)
    }

    @Test
    fun `非回环地址原样交给系统默认实现`() {
        val recording = RecordingSelector()
        val selector = LoopbackProxyBypass.wrap(recording)

        val proxies = selector.select(URI("https://gateway.kugou.com/v5/url?hash=abc"))

        // 返回的就是默认实现给出的那个列表实例，不做任何改写。
        assertSame(recording.answer, proxies)
        assertEquals(1, recording.selects)
    }

    @Test
    fun `连接失败上报原样转交默认实现`() {
        val recording = RecordingSelector()
        val selector = LoopbackProxyBypass.wrap(recording)

        selector.connectFailed(URI("http://127.0.0.1:1/x"), InetSocketAddress.createUnresolved("127.0.0.1", 1), IOException("refused"))

        assertEquals(1, recording.connectFailures)
    }
}
