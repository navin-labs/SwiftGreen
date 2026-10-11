package com.swiftgreen.app

/**
 * Sent-status accounting for one outgoing SMS, which may go out as several parts that
 * each report on their own sentIntent, racing the send timeout.
 *
 * The real outcome — the first failed part, or the last part succeeding — is reported
 * exactly once, even if it arrives after the timeout: a slow IMS send used to finish
 * after the 15 s timeout had already unregistered the receiver, so its result was lost
 * and the Mac showed "timeout" for a message that went out. The timeout itself
 * only gives a provisional answer.
 */
class SmsPartTally {
    private var remaining = 1
    private var final = false
    private var provisional = false

    /** Before sending: the number of parts, and so of sentIntents, the SMS goes out as. */
    @Synchronized fun expect(parts: Int) { remaining = parts }

    /** A part's sentIntent fired. True exactly once, when this call carries the real outcome. */
    @Synchronized fun onPart(ok: Boolean): Boolean {
        if (final) return false
        if (ok && --remaining > 0) return false
        final = true
        return true
    }

    /** The timeout fired: true if nothing is known yet and a provisional answer is due. */
    @Synchronized fun timeout(): Boolean {
        if (final || provisional) return false
        provisional = true
        return true
    }

    /** The send threw, or the final wait ran out: true if no real outcome was reported. */
    @Synchronized fun claim(): Boolean {
        if (final) return false
        final = true
        return true
    }

    @Synchronized fun isFinal() = final
}
