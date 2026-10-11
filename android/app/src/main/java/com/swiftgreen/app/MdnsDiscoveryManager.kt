package com.swiftgreen.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class MdnsDiscoveryManager(private val context: Context) {

    private val TAG = "MdnsDiscovery"
    private val SERVICE_TYPE = "_swiftgreen._tcp."

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    // Resolves still in flight; on API 34+ each holds a callback registration until cancelled.
    private val pendingResolves = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()

    // Reactive state containing discovered services
    private val _discoveredServices = MutableStateFlow<List<NsdServiceInfo>>(emptyList())
    val discoveredServices: StateFlow<List<NsdServiceInfo>> = _discoveredServices.asStateFlow()

    // Reactive state for status message
    private val _status = MutableStateFlow("Stopped")
    val status: StateFlow<String> = _status.asStateFlow()

    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    fun startDiscovery() {
        if (_isDiscovering.value) {
            Log.d(TAG, "Discovery already running")
            return
        }

        // Acquire MulticastLock to ensure mDNS packets are received
        try {
            multicastLock = wifiManager.createMulticastLock("SwiftGreenMulticastLock").apply {
                setReferenceCounted(false)
                acquire()
            }
            Log.d(TAG, "MulticastLock acquired")
        } catch (e: Exception) {
            Log.e(TAG, "Could not acquire MulticastLock", e)
        }

        _discoveredServices.value = emptyList()
        initializeDiscoveryListener()

        try {
            nsdManager.discoverServices(
                SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener
            )
            _isDiscovering.value = true
            _status.value = "Starting discovery..."
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery", e)
            _status.value = "Failed to start: ${e.localizedMessage}"
            _isDiscovering.value = false
        }
    }

    fun stopDiscovery() {
        pendingResolves.forEach { it() }
        pendingResolves.clear()

        // Release MulticastLock
        try {
            multicastLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            multicastLock = null
            Log.d(TAG, "MulticastLock released")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release MulticastLock", e)
        }

        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
                _status.value = "Stopping discovery..."
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop discovery", e)
                _status.value = "Failed to stop: ${e.localizedMessage}"
            }
        }
        discoveryListener = null
        _isDiscovering.value = false
    }

    private fun initializeDiscoveryListener() {
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery failed to start: Error code $errorCode")
                _status.value = "Start failed: Error $errorCode"
                stopDiscovery()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery failed to stop: Error code $errorCode")
                _status.value = "Stop failed: Error $errorCode"
                nsdManager.stopServiceDiscovery(this)
            }

            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "Service discovery started")
                _status.value = "Scanning local network..."
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "Service discovery stopped")
                _status.value = "Stopped"
                _discoveredServices.value = emptyList()
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service found: $serviceInfo")
                // Filter and make sure we only resolve SwiftGreen services
                if (serviceInfo.serviceType.contains(SERVICE_TYPE)) {
                    resolveService(serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
                _discoveredServices.value = _discoveredServices.value.filter {
                    it.serviceName != serviceInfo.serviceName
                }
                if (_discoveredServices.value.isEmpty()) {
                    _status.value = "Scanning local network... (No devices found)"
                } else {
                    _status.value = "Found ${_discoveredServices.value.size} device(s)"
                }
            }
        }
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        pendingResolves += nsdManager.resolveOnce(serviceInfo,
            onResolved = { resolvedServiceInfo ->
                Log.d(TAG, "Resolve succeeded: $resolvedServiceInfo")

                // Avoid adding duplicate services with the same name
                val currentList = _discoveredServices.value.toMutableList()
                val index = currentList.indexOfFirst { it.serviceName == resolvedServiceInfo.serviceName }
                if (index != -1) {
                    currentList[index] = resolvedServiceInfo
                } else {
                    currentList.add(resolvedServiceInfo)
                }

                _discoveredServices.value = currentList
                _status.value = "Found ${currentList.size} device(s)"
            },
            // Sometimes resolving fails if multiple requests are sent concurrently.
            // We still report the service but warn that we couldn't resolve port/IP yet.
            onFailed = { errorCode -> Log.e(TAG, "Resolve failed: Error code $errorCode") })
    }
}
