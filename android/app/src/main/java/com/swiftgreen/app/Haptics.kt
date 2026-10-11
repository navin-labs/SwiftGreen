package com.swiftgreen.app

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.SoundEffectConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * The app's haptic vocabulary.
 *
 * ponytail: the platform's own [HapticFeedbackConstants] through [View.performHapticFeedback],
 * no VibrationEffect patterns. Each constant feels the way the OS decided that moment
 * should feel on this phone, and the call honours the user's Touch feedback setting
 * (we never pass FLAG_IGNORE_GLOBAL_SETTING). CONFIRM and REJECT exist from Android 11;
 * older phones get the nearest older constant.
 *
 * Rule of thumb applied at every call site: haptics confirm a *committed* action
 * (sent, paired, copied), never mere navigation or scrolling. Buzzing on every tab
 * tap is the fastest way to get haptics disabled entirely.
 */
class SwiftGreenHaptics(private val view: View) {

    /** A committed, consequential action succeeded: paired, sent, transfer done. */
    fun confirm() = perform(
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
        else HapticFeedbackConstants.VIRTUAL_KEY)

    /** A light acknowledgement: copied to clipboard, pinned, toggled. */
    fun tick() = perform(HapticFeedbackConstants.CLOCK_TICK)

    /**
     * A button press: the keyboard-tap haptic plus the system click, the one sound
     * Android itself makes for a tap (silent when Touch sounds is off).
     */
    fun tap() {
        perform(HapticFeedbackConstants.KEYBOARD_TAP)
        view.playSoundEffect(SoundEffectConstants.CLICK)
    }

    /** A long press was recognised. */
    fun longPress() = perform(HapticFeedbackConstants.LONG_PRESS)

    /** Something failed: the platform's reject feel, distinct from [confirm]. */
    fun failure() = perform(
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.REJECT
        else HapticFeedbackConstants.LONG_PRESS)

    private fun perform(constant: Int) {
        view.performHapticFeedback(constant)
    }
}

@Composable
fun rememberHaptics(): SwiftGreenHaptics {
    val view = LocalView.current
    return remember(view) { SwiftGreenHaptics(view) }
}
