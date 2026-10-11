package com.swiftgreen.app.ui.theme

import androidx.compose.ui.graphics.Color

// ponytail: names kept from the Compose template so Theme.kt needs no edit.
// Values are monochrome — this app has no accent colour.
val Purple80 = Color(0xFFFFFFFF)
val PurpleGrey80 = Color(0xFF2A2A2A)
val Pink80 = Color(0xFF1A1A1A)

// Status colours: iOS/macOS system colours, dark-appearance values (the app is always
// dark). Only where colour carries meaning: the connection dot, destructive
// confirmations, and sent/failed markers. Nothing else should reach for these.
/** systemGreen (dark). */
val StatusSuccess = Color(0xFF30D158)
/** systemRed (dark). */
val StatusDanger = Color(0xFFFF453A)
/** systemOrange (dark). */
val StatusWarning = Color(0xFFFF9F0A)
/** systemYellow (dark): connecting, and battery in Low Power Mode. */
val StatusWarningYellow = Color(0xFFFFD60A)
/** SwiftGreen green, the Mac's ambient glow colour; the phone's selection accent. */
val AccentGreen = Color(0xFF30D158)

val Purple40 = Color(0xFFFFFFFF)
val PurpleGrey40 = Color(0xFF2A2A2A)
val Pink40 = Color(0xFF1A1A1A)