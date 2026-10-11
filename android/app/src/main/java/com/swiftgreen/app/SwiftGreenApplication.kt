package com.swiftgreen.app

import android.app.Application

/**
 * SwiftGreenApplication serves as the main Application subclass.
 * Creates the process-wide client and stores, and cancels work an earlier build scheduled.
 */
class SwiftGreenApplication : Application() {

    companion object {
        lateinit var instance: SwiftGreenApplication
            private set
        lateinit var quicClient: MdnsQuicClient
            private set
    }

    private val TAG = "SwiftGreenApplication"

    override fun onCreate() {
        super.onCreate()
        SyncSwitch.checkForceStop(this)
        instance = this
        Log.i(TAG, "SwiftGreenApplication: Starting application initialization lifecycle.")

        // 1. Initialise the MdnsQuicClient singleton once for the process lifetime
        quicClient = MdnsQuicClient(this)
        Log.i(TAG, "MdnsQuicClient singleton initialized")

        // Initialize NotificationHistoryManager
        NotificationHistoryManager.init(this)
        
        // Initialize ClipboardHistoryManager
        ClipboardHistoryManager.init(this)

        // 2. The old 15-min WorkManager watchdog is gone (it kept the app alive after
        // the user closed it); cancel any copy an earlier build left scheduled. WorkManager
        // ran it as a job of its own JobService, so this needs no WorkManager library.
        getSystemService(android.app.job.JobScheduler::class.java)?.let { jobs ->
            jobs.allPendingJobs
                .filter { it.service.className == "androidx.work.impl.background.systemjob.SystemJobService" }
                .forEach { jobs.cancel(it.id) }
        }

        Log.i(TAG, "SwiftGreenApplication: Finished core service setups successfully.")
    }
}
