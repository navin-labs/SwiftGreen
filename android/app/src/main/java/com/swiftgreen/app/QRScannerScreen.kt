package com.swiftgreen.app

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "QRScannerScreen"

@Composable
fun QRScannerScreen(
    pairingManager: PairingManager,
    onPairingComplete: () -> Unit
) {
    val context = LocalContext.current
    val pairingState by pairingManager.state.collectAsState()
    val pairingPin by pairingManager.pairingPin.collectAsState()
    val scannedHostname by pairingManager.scannedHostname.collectAsState()
    val errorMessage by pairingManager.errorMessage.collectAsState()
    val unpairNotice by pairingManager.unpairNotice.collectAsState()
    val coroutineScope = rememberCoroutineScope()

    // An unpair the Mac couldn't hear at the time (it was off or away) is retried here.
    LaunchedEffect(Unit) { pairingManager.deliverPendingUnpair() }

    // Camera permission state
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        hasCameraPermission = isGranted
        if (isGranted) {
            pairingManager.startScanning()
        }
    }

    // Start scanning on first composition. This screen only shows while unpaired, so a
    // PAIRED left over from an earlier pairing in this process (the Mac has since
    // unpaired us) is stale too, and must not bring back the success card.
    LaunchedEffect(Unit) {
        if (pairingState == PairingManager.PairingState.IDLE || pairingState == PairingManager.PairingState.PAIRED) {
            pairingManager.startScanning()
        }
    }

    val colors = getThemeColors()
    val showingPin = pairingState == PairingManager.PairingState.PIN_DISPLAYED ||
        pairingState == PairingManager.PairingState.PAIRING
    val scanning = hasCameraPermission && !showingPin &&
        pairingState != PairingManager.PairingState.ERROR &&
        pairingState != PairingManager.PairingState.PAIRED

    // The camera fills the screen; everything else sits in the usual header layout.
    if (scanning) {
        QRCameraView(pairingManager = pairingManager, notice = unpairNotice)
        return
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp)
    ) {
        ScreenHeader(
            "Pair with your Mac",
            if (showingPin) "Enter the PIN shown on your Mac"
            else if (unpairNotice.isNotEmpty()) "$unpairNotice On your Mac, open SwiftGreen → Settings, then point this camera at the code"
            else "On your Mac, open SwiftGreen → Settings, then point this camera at the code"
        )
        Spacer(Modifier.height(20.dp))

        Box(Modifier.fillMaxWidth().weight(1f)) {
            when {
                !hasCameraPermission -> CameraPermissionCard(
                    onRequestPermission = { permissionLauncher.launch(Manifest.permission.CAMERA) }
                )
                pairingState == PairingManager.PairingState.ERROR -> ErrorCard(
                    message = errorMessage,
                    onRetry = { pairingManager.resetToScanning() }
                )
                showingPin -> PinConfirmationCard(
                    hostname = scannedHostname,
                    pin = pairingPin,
                    onPinChange = { pairingManager.setEnteredPin(it) },
                    isPairing = pairingState == PairingManager.PairingState.PAIRING,
                    onConfirm = {
                        coroutineScope.launch(Dispatchers.IO) {
                            performPairingHandshake(context, pairingManager, onPairingComplete)
                        }
                    },
                    onScanAgain = { pairingManager.resetToScanning() }
                )
                // Continue always leads somewhere: the dashboard when paired (MainActivity
                // switches on isPaired), otherwise back to the scanner.
                else -> PairedSuccessCard(onContinue = {
                    if (!pairingManager.isPaired.value) pairingManager.startScanning()
                    onPairingComplete()
                })
            }
        }

        PrivacyFooter()
    }
}

@Composable
private fun PrivacyFooter() {
    val colors = getThemeColors()
    Row(Modifier.fillMaxWidth().padding(vertical = 16.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Lock, null, tint = colors.textSecondary, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(6.dp))
        Text("Encrypted · local network · no cloud", color = colors.textSecondary, fontSize = 12.sp)
    }
}

// =============================================================================
// Camera Preview with QR Detection
// =============================================================================

@Composable
private fun QRCameraView(pairingManager: PairingManager, notice: String) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val colors = getThemeColors()
    val haptics = rememberHaptics()

    val scannerExecutor = remember { Executors.newSingleThreadExecutor() }
    val barcodeScanner = remember {
        val options = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build()
        BarcodeScanning.getClient(options)
    }

    // Thread-safe flag to prevent the analyzer from firing after a QR is found.
    // Compose mutableStateOf is NOT visible across threads, so we use AtomicBoolean.
    val hasScanned = remember { AtomicBoolean(false) }

    // Observe pairing state to gate the analyzer
    val currentPairingState by pairingManager.state.collectAsState()

    // The bound camera, for the torch. Null until CameraX binds, or if binding failed.
    var camera by remember { mutableStateOf<Camera?>(null) }
    var torchOn by remember { mutableStateOf(false) }

    // A locked code draws the brackets in a little and to full strength.
    var locked by remember { mutableStateOf(false) }
    val lockProgress by animateFloatAsState(if (locked) 1f else 0f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "lock")

    // The camera stays bound after a code locks; never leave the torch burning behind the PIN.
    DisposableEffect(Unit) { onDispose { camera?.cameraControl?.enableTorch(false) } }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // CameraX Preview, edge to edge
        AndroidView(
            factory = { ctx ->
                val previewView = PreviewView(ctx).apply {
                    scaleType = PreviewView.ScaleType.FILL_CENTER
                }

                val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                cameraProviderFuture.addListener({
                    try {
                        val cameraProvider = cameraProviderFuture.get()

                        val preview = Preview.Builder().build().also {
                            it.surfaceProvider = previewView.surfaceProvider
                        }

                        val imageAnalysis = ImageAnalysis.Builder()
                            .setResolutionSelector(
                                androidx.camera.core.resolutionselector.ResolutionSelector.Builder()
                                    .setAspectRatioStrategy(androidx.camera.core.resolutionselector.AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                                    .setResolutionStrategy(androidx.camera.core.resolutionselector.ResolutionStrategy(
                                        Size(1280, 720),
                                        androidx.camera.core.resolutionselector.ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                                    .build())
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                            .also { analysis ->
                                analysis.setAnalyzer(scannerExecutor) { imageProxy ->
                                    processImageForQR(
                                        imageProxy = imageProxy,
                                        scanner = barcodeScanner,
                                        scanLock = hasScanned,
                                        currentState = currentPairingState,
                                        onScanned = { rawValue ->
                                            // ML Kit's listeners run on the main thread.
                                            locked = true
                                            haptics.confirm()
                                            pairingManager.onQRScanned(rawValue)
                                        }
                                    )
                                }
                            }

                        val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

                        cameraProvider.unbindAll()
                        camera = cameraProvider.bindToLifecycle(
                            lifecycleOwner,
                            cameraSelector,
                            preview,
                            imageAnalysis
                        )
                        Log.d(TAG, "CameraX bound to lifecycle")
                    } catch (e: Exception) {
                        Log.e(TAG, "CameraX binding failed", e)
                    }
                }, ContextCompat.getMainExecutor(ctx))

                previewView
            },
            modifier = Modifier.fillMaxSize()
        )

        // Dim everything outside a centred, rounded viewfinder; four soft corner brackets.
        Canvas(modifier = Modifier.fillMaxSize()) {
            val viewfinderSize = minOf(size.width, size.height) * 0.68f
            val left = (size.width - viewfinderSize) / 2f
            val top = (size.height - viewfinderSize) / 2f
            val right = left + viewfinderSize
            val bottom = top + viewfinderSize
            val cr = 28.dp.toPx()

            val overlayPath = Path().apply {
                addRect(Rect(0f, 0f, size.width, size.height))
                addRoundRect(RoundRect(Rect(left, top, right, bottom), CornerRadius(cr)))
                fillType = PathFillType.EvenOdd
            }
            drawPath(overlayPath, Color.Black.copy(alpha = 0.55f))

            // On lock the brackets move in by 6dp and reach full white.
            val inset = 6.dp.toPx() * lockProgress
            drawBrackets(Rect(left + inset, top + inset, right - inset, bottom - inset),
                radius = cr, arm = 22.dp.toPx(), width = 4.dp.toPx(),
                color = Color.White.copy(alpha = 0.85f + 0.15f * lockProgress))
        }

        // One instruction, one line on where to find the code.
        Column(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            if (notice.isNotEmpty()) {
                Text(notice, color = Color.White, fontSize = 13.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))
                        .padding(horizontal = 14.dp, vertical = 6.dp))
                Spacer(Modifier.height(16.dp))
            }
            Text("Scan the code on your Mac", color = Color.White, fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            Text("On your Mac: SwiftGreen → Settings", color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp, textAlign = TextAlign.Center)
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally) {
            // Torch, only on a camera that has one.
            if (camera?.cameraInfo?.hasFlashUnit() == true) {
                IconButton(
                    onClick = {
                        torchOn = !torchOn
                        camera?.cameraControl?.enableTorch(torchOn)
                        haptics.tick()
                    },
                    modifier = Modifier.size(56.dp).clip(CircleShape)
                        .background(if (torchOn) Color.White else Color.Black.copy(alpha = 0.45f))
                ) {
                    Icon(if (torchOn) Icons.Default.FlashlightOn else Icons.Default.FlashlightOff,
                        contentDescription = if (torchOn) "Turn off flashlight" else "Turn on flashlight",
                        tint = if (torchOn) Color.Black else Color.White)
                }
            }
            PrivacyFooter()
        }
    }
}

/**
 * Four soft corner brackets around [frame]: per corner a short arm, the corner's own
 * arc, the other arm, with round caps. The scanner's viewfinder and the state glyphs
 * share it, so every pairing screen reads as one piece.
 */
private fun DrawScope.drawBrackets(frame: Rect, radius: Float, arm: Float, width: Float, color: Color) {
    val stroke = Stroke(width = width, cap = StrokeCap.Round, join = StrokeJoin.Round)
    // (cx, cy) is the corner; sx/sy point into the frame.
    fun bracket(cx: Float, cy: Float, sx: Float, sy: Float) {
        val oval = Rect(minOf(cx, cx + sx * 2 * radius), minOf(cy, cy + sy * 2 * radius),
                        maxOf(cx, cx + sx * 2 * radius), maxOf(cy, cy + sy * 2 * radius))
        val path = Path().apply {
            moveTo(cx, cy + sy * (radius + arm))
            lineTo(cx, cy + sy * radius)
            arcTo(oval, startAngleDegrees = if (sx > 0) 180f else 0f,
                sweepAngleDegrees = if (sx * sy > 0) 90f else -90f, forceMoveTo = false)
            lineTo(cx + sx * (radius + arm), cy)
        }
        drawPath(path, color, style = stroke)
    }
    bracket(frame.left, frame.top, 1f, 1f)
    bracket(frame.right, frame.top, -1f, 1f)
    bracket(frame.left, frame.bottom, 1f, -1f)
    bracket(frame.right, frame.bottom, -1f, -1f)
}

@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
private fun processImageForQR(
    imageProxy: ImageProxy,
    scanner: BarcodeScanner,
    scanLock: AtomicBoolean,
    currentState: PairingManager.PairingState,
    onScanned: (String) -> Unit
) {
    // Gate: only process frames when we are actively SCANNING.
    // Once a QR is found, the AtomicBoolean lock prevents re-entry even if
    // the Compose state hasn't propagated to this background thread yet.
    if (scanLock.get() || currentState != PairingManager.PairingState.SCANNING) {
        imageProxy.close()
        return
    }

    val mediaImage = imageProxy.image
    if (mediaImage == null) {
        imageProxy.close()
        return
    }

    val inputImage = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

    scanner.process(inputImage)
        .addOnSuccessListener { barcodes ->
            for (barcode in barcodes) {
                val rawValue = barcode.rawValue
                if (rawValue != null && rawValue.contains("publicKey") && rawValue.contains("hostname")) {
                    // Atomically lock — only the first detection wins
                    if (scanLock.compareAndSet(false, true)) {
                        Log.d(TAG, "QR code detected (locked): $rawValue")
                        onScanned(rawValue)
                    }
                    break
                }
            }
        }
        .addOnFailureListener { e ->
            Log.e(TAG, "Barcode scanning failed", e)
        }
        .addOnCompleteListener {
            imageProxy.close()
        }
}

// =============================================================================
// States around the camera: PIN check, camera permission, error, success
// =============================================================================

/** One centred state: a glyph in a circle, a title, a line of help, then actions. */
@Composable
private fun CenteredState(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
    content: @Composable ColumnScope.() -> Unit
) {
    val colors = getThemeColors()
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center) {
        // The glyph sits in a small copy of the viewfinder's brackets.
        Box(Modifier.size(88.dp).drawBehind {
                drawBrackets(Rect(Offset.Zero, size), radius = 16.dp.toPx(), arm = 10.dp.toPx(),
                    width = 3.dp.toPx(), color = colors.textSecondary)
            }, contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = colors.textPrimary, modifier = Modifier.size(34.dp))
        }
        Spacer(Modifier.height(16.dp))
        Text(title, color = colors.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center)
        Spacer(Modifier.height(6.dp))
        Text(body, color = colors.textSecondary, fontSize = 14.sp, lineHeight = 20.sp,
            textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
        Spacer(Modifier.height(28.dp))
        content()
    }
}

/** Full-width white capsule: the one thing to do next. */
@Composable
private fun WideButton(text: String, loading: Boolean = false, onClick: () -> Unit) {
    val colors = getThemeColors()
    Button(onClick = onClick, enabled = !loading,
        modifier = Modifier.fillMaxWidth().height(52.dp),
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(containerColor = colors.textPrimary,
            disabledContainerColor = colors.surfaceHigh)) {
        if (loading) {
            CircularProgressIndicator(Modifier.size(18.dp), color = colors.textPrimary, strokeWidth = 2.dp)
            Spacer(Modifier.width(10.dp))
        }
        Text(text, color = if (loading) colors.textPrimary else colors.background,
            fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun PinConfirmationCard(
    hostname: String,
    pin: String,
    onPinChange: (String) -> Unit,
    isPairing: Boolean,
    onConfirm: () -> Unit,
    onScanAgain: () -> Unit
) {
    val colors = getThemeColors()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    CenteredState(Icons.Default.Laptop, hostname.removeSuffix(".local").ifBlank { "Your Mac" },
        "Type the 6-digit PIN your Mac is showing") {
        // Same digit tiles as the Mac's pairing card, typed through one hidden field so
        // the number keyboard, paste and backspace all behave natively.
        BasicTextField(pin, onValueChange = onPinChange, enabled = !isPairing,
            modifier = Modifier.focusRequester(focus).semantics { contentDescription = "PIN" },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (pin.length == 6) onConfirm() }),
            decorationBox = {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    repeat(6) { i ->
                        Box(Modifier.size(width = 48.dp, height = 60.dp).clip(RoundedCornerShape(12.dp))
                                .background(colors.surface), contentAlignment = Alignment.Center) {
                            Text(pin.getOrNull(i)?.toString() ?: "", color = colors.textPrimary, fontSize = 30.sp,
                                fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                        }
                    }
                }
            })
        Spacer(Modifier.weight(1f))
        WideButton(if (isPairing) "Pairing…" else "Pair", loading = isPairing,
            onClick = { if (pin.length == 6) onConfirm() })
        TextButton(onClick = onScanAgain, enabled = !isPairing, modifier = Modifier.padding(top = 4.dp)) {
            Text("Scan Again", color = colors.textSecondary, fontSize = 15.sp)
        }
    }
}

@Composable
private fun CameraPermissionCard(onRequestPermission: () -> Unit) {
    CenteredState(Icons.Default.CameraAlt, "Allow the camera",
        "It's only used to read the pairing code. Nothing is recorded or saved.") {
        Spacer(Modifier.weight(1f))
        WideButton("Allow Camera", onClick = onRequestPermission)
    }
}

@Composable
private fun ErrorCard(message: String, onRetry: () -> Unit) {
    CenteredState(Icons.Default.Warning, "Couldn't pair",
        message.ifBlank { "Make sure your Mac and this phone are on the same Wi‑Fi network, then try again." }) {
        Spacer(Modifier.weight(1f))
        WideButton("Try Again", onClick = onRetry)
    }
}

@Composable
private fun PairedSuccessCard(onContinue: () -> Unit) {
    CenteredState(Icons.Default.CheckCircle, "Paired",
        "This phone and your Mac now trust each other. Future connections are verified with the same keys.") {
        Spacer(Modifier.weight(1f))
        WideButton("Continue", onClick = onContinue)
    }
}

// =============================================================================
// Pairing Handshake (connect to Mac, send public key, complete ECDH)
// =============================================================================

/**
 * Performs the full pairing handshake:
 * 1. Discovers the Mac via mDNS (using the hostname from the QR code)
 * 2. Connects via TLS
 * 3. Sends Android's public key
 * 4. Waits for pairing-complete response
 * 5. Completes ECDH + HKDF key derivation
 */
private suspend fun performPairingHandshake(
    context: android.content.Context,
    pairingManager: PairingManager,
    onPairingComplete: () -> Unit
) {
    try {
        // Set state to PAIRING to show loading indicator and lock the UI
        kotlinx.coroutines.withContext(Dispatchers.Main) {
            pairingManager.setPairingInProgress()
        }

        Log.d(TAG, "Starting pairing handshake...")

        // Get the active MdnsQuicClient or create a temporary one
        val client = MdnsQuicClient.getActiveClient() ?: MdnsQuicClient(context)

        // Get Android's public key to send
        val androidPubKeyBase64 = pairingManager.getAndroidPublicKeyBase64()
        Log.d(TAG, "Android public key ready (base64)")

        // Dial the Mac's address from the QR first: many routers (ISP, office, guest) drop
        // mDNS between devices but pass direct connections. Only "nothing answered" moves
        // on; a wrong PIN or expired code still fails here. mDNS remains the fallback.
        val qrPort = pairingManager.scannedPort
        if (qrPort > 0) {
            for (ip in pairingManager.scannedAddresses) {
                try {
                    client.connectForPairing(ip, qrPort, pairingManager.scannedHostname.value, pairingManager)
                    Log.d(TAG, "Pairing handshake completed via QR address $ip:$qrPort")
                    kotlinx.coroutines.withContext(Dispatchers.Main) {
                        onPairingComplete()
                    }
                    return
                } catch (e: java.net.ConnectException) {
                    Log.w(TAG, "QR address unreachable — ${e.message}")
                }
            }
        }

        // Discover and connect to the Mac for pairing
        val discoveryManager = MdnsDiscoveryManager(context)
        discoveryManager.startDiscovery()

        // Wait for discovery with timeout (15s max)
        var attempts = 0
        var targetService: android.net.nsd.NsdServiceInfo? = null
        val scannedHostname = pairingManager.scannedHostname.value

        // Discovery holds a Wi-Fi multicast lock: stop it as soon as the Mac is found,
        // or on timeout or cancel. Left running, it kept the radio awake after pairing.
        try {
            while (attempts < 30 && targetService == null) {
                kotlinx.coroutines.delay(500)
                val services = discoveryManager.discoveredServices.value
                // Try to find a service matching the scanned hostname
                targetService = services.firstOrNull { service ->
                    service.serviceName?.contains(scannedHostname, ignoreCase = true) == true ||
                            service.firstHost?.hostName?.contains(scannedHostname, ignoreCase = true) == true
                } ?: services.firstOrNull()  // fallback to first discovered service
                attempts++
            }
        } finally {
            discoveryManager.stopDiscovery()
        }

        if (targetService == null) {
            throw Exception("Could not discover Mac on network. Make sure both devices are on the same Wi-Fi network.")
        }

        Log.d(TAG, "Found Mac service: ${targetService.serviceName}")

        // Connect for pairing — this is a blocking one-shot TLS connection
        client.connectForPairing(targetService, pairingManager)

        Log.d(TAG, "Pairing handshake completed successfully")

        // Switch to main thread for UI callback
        kotlinx.coroutines.withContext(Dispatchers.Main) {
            onPairingComplete()
        }

    } catch (e: Exception) {
        Log.e(TAG, "Pairing handshake failed", e)
        // Show the error to the user instead of silently resetting to camera
        kotlinx.coroutines.withContext(Dispatchers.Main) {
            pairingManager.setPairingError("Pairing failed: ${e.localizedMessage}")
        }
    }
}
