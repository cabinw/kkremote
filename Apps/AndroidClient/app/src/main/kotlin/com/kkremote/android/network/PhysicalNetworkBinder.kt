package com.kkremote.android.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import okhttp3.Dns
import okhttp3.OkHttpClient
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Keeps Android's underlying physical network (5G CELLULAR / WIFI with NET_CAPABILITY_NOT_VPN)
 * active and binds signaling HTTP/WSS sockets directly to it so VPN tunnels / exit nodes
 * (e.g. Tailscale, Surge, Clash TUN) never throttle or hijack KKRemote native P2P sessions.
 */
object PhysicalNetworkBinder {
    @Volatile
    private var started = false

    private val activePhysicalNetwork = AtomicReference<Network?>(null)

    private val fallbackOkHttp: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build()
    }

    @Volatile
    private var boundNetSnapshot: Network? = null

    @Volatile
    private var boundOkHttp: OkHttpClient? = null

    @Synchronized
    fun ensureStarted(context: Context) {
        if (started) return
        started = true
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return

        // Seed synchronously from any currently active non-VPN network
        runCatching {
            val candidate = cm.allNetworks.firstOrNull { net ->
                val caps = cm.getNetworkCapabilities(net) ?: return@firstOrNull false
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            }
            if (candidate != null) {
                activePhysicalNetwork.set(candidate)
            }
        }

        // Request Android to keep the underlying non-VPN radio awake even when a global VPN exit-node is active
        runCatching {
            val req = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            cm.requestNetwork(req, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    activePhysicalNetwork.set(network)
                }

                override fun onLost(network: Network) {
                    activePhysicalNetwork.compareAndSet(network, null)
                }
            })
        }
    }

    fun okHttpClient(context: Context): OkHttpClient {
        ensureStarted(context)
        val net = activePhysicalNetwork.get() ?: return fallbackOkHttp
        val cachedClient = boundOkHttp
        if (cachedClient != null && boundNetSnapshot == net) {
            return cachedClient
        }
        return runCatching {
            val dns = object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    val resolved = net.getAllByName(hostname)
                    return if (resolved.isNullOrEmpty()) Dns.SYSTEM.lookup(hostname) else resolved.toList()
                }
            }
            OkHttpClient.Builder()
                .socketFactory(net.socketFactory)
                .dns(dns)
                .connectTimeout(8, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(20, TimeUnit.SECONDS)
                .build()
                .also {
                    boundNetSnapshot = net
                    boundOkHttp = it
                }
        }.getOrElse { fallbackOkHttp }
    }

    fun isVpnOrCgnatTunnelIp(sdpOrIp: String): Boolean {
        val parts = sdpOrIp.trim().split(Regex("\\s+"))
        val ip = if (parts.size >= 5 && parts[0].startsWith("candidate:")) parts[4] else sdpOrIp.trim()
        if (ip.startsWith("198.18.") || ip.startsWith("198.19.") || ip == "172.19.0.1") return true
        val octets = ip.split('.')
        if (octets.size == 4) {
            val o0 = octets[0].toIntOrNull() ?: return false
            val o1 = octets[1].toIntOrNull() ?: return false
            if (o0 == 100 && o1 in 64..127) return true
        }
        return false
    }
}
