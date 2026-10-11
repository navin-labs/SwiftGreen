package com.swiftgreen.app

/**
 * The app's only logger; `android.util.Log` is used nowhere else (scripts/check-hygiene.sh
 * fails the build of a PR that imports it). Debug builds log everything. Release builds log
 * no message text at all: warnings and errors keep the tag and the exception's class, and
 * debug/info lines are dropped. So a message that interpolates a file name, a number, a
 * notification or a QR payload can't reach a release logcat or a bug report.
 *
 * ponytail: messages are still built in release (a little garbage per call); switch to
 * lambda overloads if a profiler ever shows it.
 */
object Log {
    private val debug = BuildConfig.DEBUG

    fun d(tag: String, msg: String, tr: Throwable? = null) { if (debug) android.util.Log.d(tag, msg, tr) }
    fun i(tag: String, msg: String) { if (debug) android.util.Log.i(tag, msg) }
    fun w(tag: String, msg: String, tr: Throwable? = null) {
        if (debug) android.util.Log.w(tag, msg, tr) else android.util.Log.w(tag, release(tr))
    }
    fun e(tag: String, msg: String, tr: Throwable? = null) {
        if (debug) android.util.Log.e(tag, msg, tr) else android.util.Log.e(tag, release(tr))
    }

    private fun release(tr: Throwable?) = if (tr == null) "event" else "event (${tr.javaClass.simpleName})"
}
