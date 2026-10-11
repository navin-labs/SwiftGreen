package com.swiftgreen.app

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

/** The service's first address. API 34 replaced `host` with `hostAddresses`; `host` is `hostAddresses[0]` there. */
val NsdServiceInfo.firstHost: InetAddress?
    get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) hostAddresses.firstOrNull()
            else @Suppress("DEPRECATION") host   // the only accessor below API 34

/**
 * Resolves [info] once. API 34+ uses `registerServiceInfoCallback` (where `resolveService` is
 * deprecated) and stops at the first update that carries an address; below 34 `resolveService`
 * is the only API. Exactly one of [onResolved] / [onFailed] runs, unless the returned cancel runs first.
 */
fun NsdManager.resolveOnce(
    info: NsdServiceInfo,
    onResolved: (NsdServiceInfo) -> Unit,
    onFailed: (errorCode: Int) -> Unit,
): () -> Unit {
    val done = AtomicBoolean(false)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                if (done.compareAndSet(false, true)) onFailed(errorCode)
            }
            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.hostAddresses.isEmpty() || !done.compareAndSet(false, true)) return
                runCatching { unregisterServiceInfoCallback(this) }
                onResolved(serviceInfo)
            }
            override fun onServiceLost() = Unit
            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        registerServiceInfoCallback(info, Runnable::run, callback)
        return { if (done.compareAndSet(false, true)) runCatching { unregisterServiceInfoCallback(callback) } }
    }
    val listener = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            if (done.compareAndSet(false, true)) onFailed(errorCode)
        }
        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            if (done.compareAndSet(false, true)) onResolved(serviceInfo)
        }
    }
    @Suppress("DEPRECATION") resolveService(info, listener)   // the only resolve API below 34
    // Below 34 there is no API to cancel a resolve; later callbacks are ignored.
    return { done.set(true) }
}
