package app.androp.android.presentation.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.SpaceBar
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.unit.dp
import app.androp.android.R
import app.androp.android.AirSyncApp
import app.androp.android.data.ble.BleGattServer
import app.androp.android.presentation.ui.components.KeyboardInputSheet
import app.androp.android.presentation.ui.components.KeyboardModifiers
import app.androp.android.presentation.ui.components.ModifierStatus
import app.androp.android.utils.HapticUtil
import app.androp.android.utils.MacRemoteStatus
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RemoteControlScreen(
    modifier: Modifier = Modifier,
    showKeyboard: Boolean,
    onDismissKeyboard: () -> Unit,
    isActive: Boolean = true
) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    val isForeground = lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val wifiConnected by WebSocketUtil.connectionState.collectAsState()
    val bluetoothState by remember {
        AirSyncApp.getBleConnectionManager()?.connectionState
            ?: flowOf(BleGattServer.BleConnectionState.DISCONNECTED)
    }.collectAsState(initial = BleGattServer.BleConnectionState.DISCONNECTED)
    // Any authenticated link drives the whole remote; Bluetooth just batches motion more.
    val supportsPointer = wifiConnected || bluetoothState == BleGattServer.BleConnectionState.AUTHENTICATED
    val supportsKeyboard = supportsPointer
    val macInputAllowed by MacRemoteStatus.inputAllowed.collectAsState()
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dataStoreManager =
        remember { app.androp.android.data.local.DataStoreManager.getInstance(context) }
    val isFlipped by dataStoreManager.isRemoteFlipped().collectAsState(initial = null)

    if (isFlipped == null) return
    val flippedValue = isFlipped!!

    fun sendRemoteAction(
        action: String,
        value: Any? = null,
        extras: Map<String, Any> = emptyMap(),
        performHaptic: Boolean = true
    ) {
        if (!isActive || !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        // Observe state for the UI, then verify the live transport at dispatch time:
        // a disconnect can happen between recomposition and the next key/gesture.
        if (!WebSocketUtil.isConnected()) return
        try {
            val data = JSONObject().put("action", action)
            if (value != null) data.put("value", value)
            extras.forEach { (key, item) ->
                data.put(key, if (item is List<*>) JSONArray(item) else item)
            }
            val json = JSONObject().put("type", "remoteControl").put("data", data)
            val accepted = WebSocketUtil.sendMessage(json.toString())
            if (accepted && performHaptic) HapticUtil.performLightTick(haptics)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // Accumulate deltas rather than queueing every pointer event. The conflated signal
    // wakes the sender only on input, so an idle or hidden trackpad does no polling.
    val motion = remember { PendingRemoteMotion() }
    LaunchedEffect(isActive, supportsPointer, wifiConnected, lifecycle) {
        motion.clear()
        if (!isActive || !supportsPointer) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try {
                while (true) {
                    motion.signal.receive()
                    // One batch per frame on Wi-Fi; fewer, larger batches fit Bluetooth.
                    delay(if (wifiConnected) 16 else 40)
                    val move = motion.move
                    val scroll = motion.scroll
                    motion.move = Offset.Zero
                    motion.scroll = Offset.Zero
                    if (move != Offset.Zero) {
                        sendRemoteAction(
                            "mouse_move",
                            extras = mapOf("dx" to move.x.toDouble(), "dy" to move.y.toDouble()),
                            performHaptic = false
                        )
                    }
                    if (scroll != Offset.Zero) {
                        sendRemoteAction(
                            "mouse_scroll",
                            extras = mapOf("dx" to scroll.x.toDouble(), "dy" to scroll.y.toDouble()),
                            performHaptic = false
                        )
                    }
                }
            } finally {
                motion.clear()
            }
        }
    }

    fun clickMouse(button: String) {
        if (!supportsPointer) return
        // Enqueue both edges together: leaving the screen cannot cancel a delayed
        // release and leave the Mac's mouse button held down.
        sendRemoteAction("mouse_click", extras = mapOf("button" to button, "isDown" to true))
        sendRemoteAction(
            "mouse_click",
            extras = mapOf("button" to button, "isDown" to false),
            performHaptic = false
        )
    }

    var activeModifiers by remember { mutableStateOf(setOf<String>()) }

    val modifiers = remember(activeModifiers) {
        KeyboardModifiers(
            shift = ModifierStatus(activeModifiers.contains("shift")),
            ctrl = ModifierStatus(activeModifiers.contains("ctrl")),
            option = ModifierStatus(activeModifiers.contains("option")),
            command = ModifierStatus(activeModifiers.contains("command")),
            fn = ModifierStatus(activeModifiers.contains("fn"))
        )
    }


    val handleType = { text: String, _: Boolean, mods: List<String> ->
            sendRemoteAction(
                "type",
                extras = mapOf(
                    "text" to text,
                    "modifiers" to mods
                ),
                performHaptic = false
            )
    }

    val handleKeyPress = { code: Int, _: Boolean, mods: List<String> ->
            sendRemoteAction(
                "keypress",
                extras = mapOf(
                    "keycode" to code,
                    "modifiers" to mods
                ),
                performHaptic = false
            )
    }

    val handleToggleModifier = remember {
        { modifier: String ->
            activeModifiers = if (activeModifiers.contains(modifier)) {
                activeModifiers - modifier
            } else {
                activeModifiers + modifier
            }
        }
    }

    val handleClearModifiers = remember {
        {
            activeModifiers = emptySet()
        }
    }


    if (showKeyboard && isActive && isForeground && !supportsKeyboard) {
        AlertDialog(
            onDismissRequest = onDismissKeyboard,
            title = { Text("Mac not connected") },
            text = { Text("Bring your phone near your Mac.") },
            confirmButton = {
                TextButton(onClick = onDismissKeyboard) { Text("Got it") }
            }
        )
    } else if (showKeyboard && isActive && isForeground) {
        KeyboardInputSheet(
            onDismiss = onDismissKeyboard,
            onType = handleType,
            onKeyPress = handleKeyPress,
            onClearModifiers = handleClearModifiers,
            modifiers = modifiers,
            onToggleModifier = handleToggleModifier
        )
    }

    @Composable
    fun ExtraKeys(isWide: Boolean) {
        // Extra Keys
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 0.dp),
            horizontalArrangement = Arrangement.Center,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            maxItemsInEachRow = 3
        ) {
            OutlinedButton(
                onClick = { sendRemoteAction("escape") },
                modifier = Modifier.heightIn(min = 48.dp)
            ) {
                Text("Esc")
            }

            OutlinedButton(
                onClick = { sendRemoteAction("space") },
                modifier = Modifier.heightIn(min = 48.dp)
            ) {
                Icon(Icons.Default.SpaceBar, "Space", modifier = Modifier.size(18.dp))
            }

            OutlinedButton(
                onClick = {
                    HapticUtil.performLightTick(haptics)
                    scope.launch {
                        dataStoreManager.setRemoteFlipped(isFlipped != true)
                    }
                },
                modifier = Modifier.heightIn(min = 48.dp)
            ) {
                Icon(
                    painter = painterResource(id = if (isWide) R.drawable.rounded_compare_arrows_24 else R.drawable.rounded_mobiledata_arrows_24),
                    contentDescription = "Swap trackpad and buttons",
                    modifier = Modifier.size(18.dp)
                )
            }
        }
    }

    @Composable
    fun DPad(size: Dp) {
        // D-Pad and Navigation
        Box(
            modifier = Modifier
                .size(size)
                .background(MaterialTheme.colorScheme.surfaceContainerLow, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            // Up
            RemoteButton(
                onClick = { sendRemoteAction("arrow_up") },
                icon = Icons.Default.ArrowUpward,
                label = "Up",
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 8.dp)
            )

            // Down
            RemoteButton(
                onClick = { sendRemoteAction("arrow_down") },
                icon = Icons.Default.ArrowDownward,
                label = "Down",
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 8.dp)
            )

            // Left
            RemoteButton(
                onClick = { sendRemoteAction("arrow_left") },
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                label = "Left",
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .padding(start = 8.dp)
            )

            // Right
            RemoteButton(
                onClick = { sendRemoteAction("arrow_right") },
                icon = Icons.AutoMirrored.Filled.ArrowForward,
                label = "Right",
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .padding(end = 8.dp)
            )

            // Center (OK/Enter)
            FilledTonalIconButton(
                onClick = { sendRemoteAction("enter") },
                modifier = Modifier.size(48.dp)
            ) {
                Icon(Icons.Default.Circle, "Enter", modifier = Modifier.size(24.dp))
            }
        }
    }

    @Composable
    fun Trackpad(modifier: Modifier = Modifier) {
        // Trackpad Area
        Surface(
            modifier = modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription = if (supportsPointer) {
                        "Trackpad. Tap to click; use two fingers to scroll or right-click; hold then move to drag."
                    } else {
                        "Mac not connected."
                    }
                    if (supportsPointer) {
                        onClick(label = "Left click") { clickMouse("left"); true }
                    }
                }
                .pointerInput(isActive, isForeground, supportsPointer) {
                    if (!isActive || !isForeground || !supportsPointer) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        var totalMoved = 0f
                        var isTwoFinger = false
                        var dragging = false
                        val dragThreshold = viewConfiguration.touchSlop
                        while (true) {
                            val event = awaitPointerEvent()
                            val pointers = event.changes
                            val pressed = pointers.filter { it.pressed }
                            if (pressed.size >= 2) isTwoFinger = true
                            if (pressed.isEmpty()) {
                                if (dragging) {
                                    motion.signal.trySend(Unit)
                                    sendRemoteAction("mouse_click", extras = mapOf("button" to "left", "isDown" to false), performHaptic = false)
                                } else if (totalMoved < dragThreshold) {
                                    clickMouse(if (isTwoFinger) "right" else "left")
                                }
                                pointers.forEach { it.consume() }
                                break
                            }
                            val continuing = pointers.filter { it.pressed && it.previousPressed }
                            if (isTwoFinger && continuing.size >= 2) {
                                val delta = continuing.take(2).map { it.position - it.previousPosition }
                                    .reduce { a, b -> a + b } / 2f
                                totalMoved += delta.getDistance()
                                motion.scroll += delta * 2f
                                if (delta != Offset.Zero) motion.signal.trySend(Unit)
                            } else if (!isTwoFinger && continuing.size == 1) {
                                val change = continuing.single()
                                val delta = change.position - change.previousPosition
                                // Rest the finger, then move: drag like a held trackpad click.
                                if (!dragging && totalMoved < dragThreshold &&
                                    change.uptimeMillis - down.uptimeMillis > 400 &&
                                    totalMoved + delta.getDistance() >= dragThreshold) {
                                    dragging = true
                                    sendRemoteAction("mouse_click", extras = mapOf("button" to "left", "isDown" to true))
                                }
                                totalMoved += delta.getDistance()
                                motion.move += delta * 1.8f
                                if (delta != Offset.Zero) motion.signal.trySend(Unit)
                            }
                            pointers.forEach { it.consume() }
                        }
                    }
                },
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surfaceBright,
            border = androidx.compose.foundation.BorderStroke(
                1.dp,
                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)
            )
        ) {
            Column(
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(
                    painter = painterResource(id = R.drawable.rounded_drag_click_24),
                    contentDescription = null,
                    modifier = Modifier
                        .size(48.dp)
                        .alpha(0.35f),
                    tint = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    when {
                        !supportsPointer -> "Mac not connected"
                        macInputAllowed == false -> "On your Mac, allow androp in Accessibility"
                        else -> "Tap to click · Two fingers to scroll"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(12.dp)
                )
            }
        }
    }

    BoxWithConstraints(
        modifier = modifier.fillMaxSize().padding(12.dp)
    ) {
        val availableHeight = maxHeight
        val isWide = (maxWidth >= 480.dp && maxWidth > maxHeight) || maxWidth >= 600.dp
        val controlsWidth = minOf(216.dp, maxWidth * 0.4f).coerceAtLeast(160.dp)
        val dpadSize = if (isWide) {
            minOf(192.dp, controlsWidth)
        } else {
            minOf(192.dp, maxHeight * 0.34f).coerceAtLeast(160.dp)
        }

        @Composable
        fun Controls(modifier: Modifier) {
            Column(
                modifier = modifier.verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)
            ) {
                ExtraKeys(isWide)
                DPad(dpadSize)
            }
        }

        if (isWide) {
            Row(
                modifier = Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                if (flippedValue) {
                    Trackpad(Modifier.weight(1f).fillMaxHeight())
                    Controls(Modifier.width(controlsWidth).fillMaxHeight())
                } else {
                    Controls(Modifier.width(controlsWidth).fillMaxHeight())
                    Trackpad(Modifier.weight(1f).fillMaxHeight())
                }
            }
        } else {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // The default puts navigation above a thumb-friendly bottom trackpad.
                if (flippedValue) {
                    Trackpad(Modifier.weight(1f))
                    Controls(Modifier.fillMaxWidth().heightIn(max = availableHeight * 0.5f))
                } else {
                    Controls(Modifier.fillMaxWidth().heightIn(max = availableHeight * 0.5f))
                    Trackpad(Modifier.weight(1f))
                }
            }
        }
    }

}

@Composable
fun RemoteButton(
    onClick: () -> Unit,
    icon: ImageVector,
    label: String,
    modifier: Modifier = Modifier
) {
    FilledTonalIconButton(
        onClick = onClick,
        modifier = modifier.size(48.dp)
    ) {
        Icon(icon, contentDescription = label)
    }
}


// Confined to the UI dispatcher: pointer events and the batch consumer never race.
private class PendingRemoteMotion {
    val signal = Channel<Unit>(Channel.CONFLATED)
    var move = Offset.Zero
    var scroll = Offset.Zero

    fun clear() {
        move = Offset.Zero
        scroll = Offset.Zero
        while (signal.tryReceive().isSuccess) { /* Drain a stale wakeup. */ }
    }
}
