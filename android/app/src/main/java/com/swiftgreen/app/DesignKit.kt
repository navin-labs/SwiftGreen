package com.swiftgreen.app

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import java.io.File
import androidx.core.net.toUri

// The phone half of the Mac's design system: one large title per screen, short
// inset groups split by hairlines, monochrome except where colour carries meaning.

/** Status colours, same as on the Mac. See ui/theme/Color.kt. */
val SGSuccess = com.swiftgreen.app.ui.theme.StatusSuccess
val SGDanger = com.swiftgreen.app.ui.theme.StatusDanger
val SGWarning = com.swiftgreen.app.ui.theme.StatusWarning
val SGWarningYellow = com.swiftgreen.app.ui.theme.StatusWarningYellow

// The phone is the Mac's look in its cheapest form: pure black (OLED pixels off),
// flat very dark cards with a hairline, the same status colours and SwiftGreen green
// for selection. No blur, gradients, translucency or custom animation: nothing here
// costs the GPU more than a solid fill.

/** The app background: pure black, the same in the system's light and dark themes. */
val SGBlack = Color(0xFF000000)
/** SwiftGreen green, the Mac's glow colour: the selected tab, and nothing else. */
val SGAccent = com.swiftgreen.app.ui.theme.AccentGreen
/** Solid charcoal for dialogs and sheets: they float over content. */
val SGSheet = Color(0xFF1C1D21)
/** A card's hairline edge, white 10%. */
val SGHairlineEdge = Color(0x1AFFFFFF)

@Composable
fun ScreenHeader(
    title: String,
    subtitle: String?,
    onTitleLongPress: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {}
) {
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f)) {
            Text(title, color = colors.textPrimary, fontSize = 32.sp, fontWeight = FontWeight.Bold,
                letterSpacing = (-0.5).sp,
                modifier = if (onTitleLongPress == null) Modifier
                    else Modifier.pointerInput(Unit) { detectTapGestures(onLongPress = { haptics.longPress(); onTitleLongPress() }) })
            if (subtitle != null) {
                Text(subtitle, color = colors.textSecondary, fontSize = 14.sp, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
            }
        }
        trailing()
    }
}

/** Small grey label above a group, with an optional action on the right. */
@Composable
fun SectionTitle(text: String, action: (@Composable () -> Unit)? = null) {
    val colors = getThemeColors()
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, bottom = 8.dp).heightIn(min = 20.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(text, color = colors.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

/** Grey text action for a section title, e.g. Clear. */
@Composable
fun SectionAction(text: String, onClick: () -> Unit) {
    Text(text, color = getThemeColors().textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 2.dp))
}

/** Flat card: a solid very dark fill and a hairline edge. No shadow, no blur. */
@Composable
fun GroupCard(content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(getThemeColors().surface)
            .border(0.5.dp, SGHairlineEdge, shape),
        content = content)
}

/** Inset to line up with row text when the rows carry an icon tile. */
val RowTextInset = 60.dp

@Composable
fun Hairline(inset: Dp = RowTextInset) {
    Box(Modifier.padding(start = inset).fillMaxWidth().height(1.dp).background(getThemeColors().border))
}

@Composable
fun IconTile(icon: ImageVector) {
    val colors = getThemeColors()
    Box(Modifier.size(32.dp).clip(RoundedCornerShape(9.dp)).background(colors.surfaceHigh),
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = colors.textPrimary, modifier = Modifier.size(18.dp))
    }
}

@Composable
fun GroupRow(
    icon: ImageVector?,
    title: String,
    detail: String? = null,
    onClick: (() -> Unit)? = null,
    titleLines: Int = 1,
    detailColor: Color? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: @Composable () -> Unit = {}
) {
    val colors = getThemeColors()
    Row(Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .heightIn(min = 36.dp),
        verticalAlignment = Alignment.CenterVertically) {
        when {
            leading != null -> { leading(); Spacer(Modifier.width(12.dp)) }
            icon != null -> { IconTile(icon); Spacer(Modifier.width(12.dp)) }
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = colors.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                maxLines = titleLines, overflow = TextOverflow.Ellipsis)
            if (detail != null) {
                Text(detail, color = detailColor ?: colors.textSecondary, fontSize = 13.sp, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.width(8.dp))
        trailing()
    }
}

@Composable
fun Chevron() {
    Icon(Icons.Default.ChevronRight, contentDescription = null, tint = getThemeColors().textSecondary,
        modifier = Modifier.size(20.dp))
}

/** Green when connected, yellow while connecting, red when disconnected or not paired. */
@Composable
fun StatusDot(on: Boolean, connecting: Boolean = false) {
    Box(Modifier.size(8.dp).clip(CircleShape)
        .background(if (on) SGSuccess else if (connecting) SGWarningYellow else SGDanger))
}

/** White capsule for the one main action on a screen; grey for everything else. */
@Composable
fun PillButton(text: String, primary: Boolean, enabled: Boolean = true, small: Boolean = false,
               onClick: () -> Unit) {
    val colors = getThemeColors()
    Box(Modifier.clip(CircleShape)
            .background(if (primary) colors.textPrimary else colors.surfaceHigh)
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.4f)
            .padding(horizontal = if (small) 12.dp else 16.dp, vertical = if (small) 6.dp else 9.dp)) {
        Text(text, color = if (primary) colors.background else colors.textPrimary,
            fontSize = if (small) 13.sp else 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
fun SearchPill(value: String, onValueChange: (String) -> Unit, placeholder: String, autoFocus: Boolean = false) {
    val colors = getThemeColors()
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    if (autoFocus) LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Row(Modifier.fillMaxWidth().height(44.dp).clip(CircleShape).background(colors.surface)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Search, contentDescription = null, tint = colors.textSecondary,
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(placeholder, color = colors.textSecondary, fontSize = 15.sp)
            BasicTextField(value = value, onValueChange = onValueChange, singleLine = true,
                textStyle = TextStyle(color = colors.textPrimary, fontSize = 15.sp),
                cursorBrush = SolidColor(colors.textPrimary),
                modifier = Modifier.fillMaxWidth().focusRequester(focus))
        }
        if (value.isNotEmpty()) {
            Icon(Icons.Default.Close, contentDescription = "Clear search", tint = colors.textSecondary,
                modifier = Modifier.size(18.dp).clip(CircleShape).clickable { onValueChange("") })
        }
    }
}

/** Quiet centred note for an empty list, inside or outside a group. */
@Composable
fun EmptyNote(text: String) {
    Text(text, color = getThemeColors().textSecondary, fontSize = 14.sp,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 24.dp))
}

/** Bumps on every resume, so permission checks re-run after a trip to system settings. */
@Composable
fun rememberResumeTick(): Int {
    var tick by remember { mutableIntStateOf(0) }
    val owner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) tick++
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    return tick
}

/** Opens a file this phone received, in whatever app handles its type. */
fun openReceivedFile(context: Context, path: String) {
    val uri: android.net.Uri
    val mime: String
    if (path.startsWith("content://")) {   // Android 10+: the MediaStore row FileTransferReceiver wrote
        uri = path.toUri()
        mime = context.contentResolver.getType(uri) ?: "*/*"
    } else {
        val file = File(path)
        if (!file.exists()) return
        uri = FileProvider.getUriForFile(context, "com.swiftgreen.app.fileprovider", file)
        mime = android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
    }
    runCatching {
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
