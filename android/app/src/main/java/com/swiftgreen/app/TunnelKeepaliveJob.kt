package com.swiftgreen.app

import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService

/** 15-minute Wi-Fi check: brings the service back if the OEM killed it, else reconnects. */
class TunnelKeepaliveJob : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        when {
            !SyncSwitch.isOn(this) ->
                getSystemService(JobScheduler::class.java).cancel(SwiftGreenTunnelService.KEEPALIVE_JOB_ID)
            !SwiftGreenTunnelService.isRunning -> runCatching { SwiftGreenTunnelService.start(this) }
            else -> {
                MdnsQuicClient.getActiveClient()?.reconnectIfNeeded()
                // Also rolls the Bluetooth watch over to the new day's beacon ID.
                MacPresence.update(this, SwiftGreenApplication.quicClient.isConnected())
            }
        }
        Log.d("TunnelKeepalive", "Keepalive job fired")
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = true
}
