package com.swiftgreen.app

/**
 * Idempotency window for Mac commands with a physical side effect, keyed by request_id.
 *
 * Same contract as [CallControlManager]'s handledRequests — a repeat of a completed
 * request re-sends the result line verbatim — plus an in-flight state, because a dial
 * finishes on a background coroutine: a repeat that arrives before the first has
 * answered must be dropped, not run. Thread-safe: claimed on the read loop, completed
 * on the worker.
 */
class RequestDedup(private val capacity: Int = 16) {

    sealed class Claim {
        /** First sighting — run the action, then call [complete]. */
        object Run : Claim()
        /** Already running — do nothing; the original will answer. */
        object InFlight : Claim()
        /** Already answered — re-send this exact result line. */
        data class Replay(val result: String) : Claim()
    }

    // request_id → result line, or null while the action is still running.
    private val entries = object : LinkedHashMap<String, String?>(capacity, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String?>?) = size > capacity
    }

    @Synchronized
    fun claim(requestId: String): Claim {
        if (requestId.isEmpty()) return Claim.Run
        if (!entries.containsKey(requestId)) {
            entries[requestId] = null
            return Claim.Run
        }
        return entries[requestId]?.let { Claim.Replay(it) } ?: Claim.InFlight
    }

    @Synchronized
    fun complete(requestId: String, result: String) {
        if (requestId.isNotEmpty()) entries[requestId] = result
    }
}
