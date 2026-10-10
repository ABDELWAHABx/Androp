package app.androp.android

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import app.androp.android.data.local.DataStoreManager
import app.androp.android.presentation.ui.activities.QRScannerActivity
import app.androp.android.presentation.ui.screens.AirSyncMainScreen
import app.androp.android.ui.theme.AirSyncTheme
import app.androp.android.utils.AdbMdnsDiscovery
import app.androp.android.utils.ContentCaptureManager
import app.androp.android.utils.KeyguardHelper
import app.androp.android.utils.NotesRoleManager
import app.androp.android.utils.PermissionUtil
import app.androp.android.utils.discovery.DiscoveryOrchestrator
import app.androp.android.utils.WebSocketUtil
import com.canerture.exceptionreport.handler.ExceptionReport
import app.androp.android.crash.CrashHandler
import app.androp.android.crash.CrashReportActivity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import androidx.lifecycle.lifecycleScope
import app.androp.android.utils.AppNavigation
import app.androp.android.utils.PairingLink

object AdbDiscoveryHolder {
    private var discovery: AdbMdnsDiscovery? = null

    fun initialize(context: android.content.Context) {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) return
        if (discovery == null) {
            Log.d("AdbDiscoveryHolder", "Initializing ADB discovery")
            discovery = AdbMdnsDiscovery(context.applicationContext)
            discovery?.startDiscovery()
        }
    }

    fun stop() {
        discovery?.stopDiscovery()
        discovery = null
    }

    fun restartDiscovery(context: android.content.Context) {
        Log.d("AdbDiscoveryHolder", "Restarting ADB discovery")
        discovery?.stopDiscovery()
        discovery = null
        initialize(context)
    }

    fun isDiscoveryActive(): Boolean {
        return discovery != null
    }

    fun getDiscoveredServices(): List<AdbMdnsDiscovery.AdbServiceInfo> {
        return discovery?.getDiscoveredServices() ?: emptyList()
    }
}

class MainActivity : ComponentActivity() {
    private var requestedDestination by mutableStateOf<String?>(null)
    private var navigationRequestId by mutableStateOf(0)

    private fun updateNavigationRequest(launchIntent: Intent?) {
        requestedDestination = AppNavigation.destination(
            launchIntent?.getStringExtra(AppNavigation.EXTRA_DESTINATION), launchIntent?.action
        )
        navigationRequestId++
    }

    // Flag to keep splash screen visible during app initialization
    private var isAppReady = false

    // Permission launcher for Android 13+ notification permission
    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
    }

    // Permission launchers for call-related permissions
    private val callLogPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
    }

    private val contactsPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
    }

    private val phonePermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
    }

    // Notes Role request launcher
    private val notesRoleLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            Log.d("MainActivity", "Notes Role granted successfully")
            Toast.makeText(this, "Notes Role granted!", Toast.LENGTH_SHORT).show()
        } else {
            Log.d("MainActivity", "Notes Role request denied or cancelled")
            Toast.makeText(this, "Notes Role request cancelled", Toast.LENGTH_SHORT).show()
        }
    }

    // Content capture launcher
    private val contentCaptureLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        ContentCaptureManager.handleCaptureResult(
            resultCode = result.resultCode,
            data = result.data,
            onSuccess = { uri ->
                Log.d("MainActivity", "Content captured: $uri")
                Toast.makeText(this, "Content captured successfully", Toast.LENGTH_SHORT).show()
                // TODO: Handle pasting captured image into clipboard chat
            },
            onFailed = {
                Toast.makeText(this, "Content capture failed", Toast.LENGTH_SHORT).show()
            },
            onUserCanceled = {
                Log.d("MainActivity", "User cancelled content capture")
            },
            onWindowModeUnsupported = {
                Toast.makeText(
                    this,
                    "Content capture only available in floating window",
                    Toast.LENGTH_SHORT
                ).show()
            },
            onBlockedByAdmin = {
                Toast.makeText(this, "Content capture blocked by administrator", Toast.LENGTH_SHORT)
                    .show()
            }
        )
    }

    private val qrScannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            val qrCode = result.data?.getStringExtra("QR_CODE")
            if (qrCode != null) {
                // Parse and connect with the QR code data
                handleQRCodeResult(qrCode)
            }
        } else {
            // User cancelled or invalid QR, do nothing - app remains open
        }
    }

    override fun onStart() {
        super.onStart()
        app.androp.android.service.AirSyncService.notifyAppForeground(this)
    }

    override fun onStop() {
        super.onStop()
        app.androp.android.service.AirSyncService.notifyAppBackground(this)
    }

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        // Install and configure the splash screen before any UI rendering
        val splashScreen = installSplashScreen()

        // Enable edge-to-edge for Android 15+ and backward compatibility
        enableEdgeToEdge()

        super.onCreate(savedInstanceState)

        ExceptionReport(this) { deviceInfo, stackTrace ->
            CrashHandler.onCrash(applicationContext, deviceInfo, stackTrace)
        }.setCustomActivity(CrashReportActivity::class.java)

        // Show the dashboard promptly; no database reads or long decorative hold.
        splashScreen.setOnExitAnimationListener { provider ->
            provider.view.animate().alpha(0f).setDuration(150).withEndAction {
                provider.remove()
            }.start()
        }

        // Keep splash screen visible while app is loading
        splashScreen.setKeepOnScreenCondition { !isAppReady }

        // Handle Notes Role intent
        handleNotesRoleIntent(intent)

        updateNavigationRequest(intent)

        val pairing = PairingLink.parse(intent?.data?.toString())
        if (intent?.data?.scheme == "androp" && pairing == null) {
            Toast.makeText(this, "Invalid pairing link", Toast.LENGTH_SHORT).show()
        }
        val ip = pairing?.host
        val port = pairing?.port?.toString()
        val pcName = pairing?.name
        val isPlus = pairing?.plus ?: false
        val symmetricKey = pairing?.key
        val isFromQrScan = pairing != null

        setContent {
            val viewModel: app.androp.android.presentation.viewmodel.AirSyncViewModel =
                androidx.lifecycle.viewmodel.compose.viewModel {
                    app.androp.android.presentation.viewmodel.AirSyncViewModel.create(this@MainActivity)
                }
            val uiState by viewModel.uiState.collectAsState()

            AirSyncTheme(pitchBlackTheme = uiState.isPitchBlackThemeEnabled) {
                val navController = rememberNavController()

                Scaffold(
                    modifier = Modifier
                        .fillMaxSize(),
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    contentWindowInsets = androidx.compose.foundation.layout.WindowInsets(
                        0,
                        0,
                        0,
                        0
                    ),
                ) { innerPadding ->
                    NavHost(
                        navController = navController,
                        startDestination = "main",
                        modifier = Modifier.padding(innerPadding)
                    ) {
                        composable("main") {
                            AirSyncMainScreen(
                                initialIp = ip,
                                initialPort = port,
                                showConnectionDialog = isFromQrScan,
                                pcName = pcName,
                                isPlus = isPlus,
                                symmetricKey = symmetricKey,
                                requestedDestination = requestedDestination,
                                navigationRequestId = navigationRequestId
                            )
                        }
                    }
                }

                // Mark app as ready after composing so splash screen can exit
                LaunchedEffect(Unit) {
                    isAppReady = true
                }
            }
        }
    }

    private fun handleQRCodeResult(qrCode: String) {
        try {
            if (PairingLink.parse(qrCode) == null) {
                Toast.makeText(this, "Invalid QR code format", Toast.LENGTH_SHORT).show()
                return
            }
            val uri = android.net.Uri.parse(qrCode)

            // Valid QR code, proceed with connection
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                data = uri
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            startActivity(mainIntent)
            finish()
        } catch (e: Exception) {
            Log.e("MainActivity", "Error handling QR code result: ${e.message}", e)
            Toast.makeText(
                this,
                "Invalid QR code format",
                Toast.LENGTH_SHORT
            ).show()
            // Keep the dashboard usable after an invalid scan.
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        updateNavigationRequest(intent)
        handleNotesRoleIntent(intent)
        if (intent?.data?.scheme == "androp") recreate()
    }

    override fun onResume() {
        super.onResume()
        app.androp.android.utils.SyncDashboardController.refreshNotification()
        lifecycleScope.launch {
            val ds = DataStoreManager.getInstance(applicationContext)
            if (!PermissionUtil.isLocalNetworkPermissionGranted(this@MainActivity) ||
                ds.isAppPaused().first()) return@launch
            AdbDiscoveryHolder.initialize(this@MainActivity)
            val discoveryEnabled = ds.getDeviceDiscoveryEnabled().first()
            DiscoveryOrchestrator.start(this@MainActivity, discoveryEnabled)
            DiscoveryOrchestrator.burstBroadcast(this@MainActivity)
        }
    }

    fun initializeAdbDiscovery() {
        lifecycleScope.launch {
            if (PermissionUtil.isLocalNetworkPermissionGranted(this@MainActivity) &&
                !DataStoreManager.getInstance(applicationContext).isAppPaused().first()) {
                AdbDiscoveryHolder.initialize(this@MainActivity)
            }
        }
    }

    /**
     * Get discovered ADB services from the running mDNS discovery.
     */
    fun getDiscoveredAdbServices(): List<AdbMdnsDiscovery.AdbServiceInfo> {
        return AdbDiscoveryHolder.getDiscoveredServices()
    }

    /**
     * Handles intents related to the Notes Role feature.
     * Extracts stylus mode hint and lock screen status from the intent.
     */
    private fun handleNotesRoleIntent(intent: Intent?) {
        // Check if this is an ACTION_CREATE_NOTE intent
        if (intent?.action == Intent.ACTION_CREATE_NOTE) {
            Log.d("MainActivity", "Received ACTION_CREATE_NOTE intent")

            // Check if stylus mode is requested
            val useStylusMode = NotesRoleManager.shouldUseStylusMode(intent)
            Log.d("MainActivity", "Stylus mode: $useStylusMode")

            // Check if launched from lock screen
            val launchedFromLockScreen = KeyguardHelper.isKeyguardLocked(this)
            Log.d("MainActivity", "Launched from lock screen: $launchedFromLockScreen")

            // If locked and device is secure, request unlock
            if (launchedFromLockScreen && KeyguardHelper.isKeyguardSecure(this)) {
                KeyguardHelper.requestDismissKeyguard(
                    this,
                    onDismissSucceeded = {
                        Log.d("MainActivity", "Device unlocked successfully")
                    },
                    onDismissError = {
                        Log.w("MainActivity", "Failed to unlock device")
                    }
                )
            }
        }
    }

    /**
     * Request the Notes Role for this app.
     * Call this from a UI button or during app initialization.
     */
    fun requestNotesRole() {
        if (NotesRoleManager.isNotesRoleAvailable(this)) {
            NotesRoleManager.requestNotesRole(this, notesRoleLauncher)
        } else {
            Toast.makeText(this, "Notes Role not available on this device", Toast.LENGTH_SHORT)
                .show()
        }
    }

    /**
     * Launch content capture for note annotation.
     * Should only be called when in floating window mode.
     */
    fun launchContentCapture() {
        if (!NotesRoleManager.isRunningInFloatingWindow(this)) {
            Toast.makeText(
                this,
                "Content capture only available in floating window",
                Toast.LENGTH_SHORT
            ).show()
            return
        }

        if (ContentCaptureManager.isScreenCaptureDisabled(this)) {
            Toast.makeText(this, "Screen capture disabled by administrator", Toast.LENGTH_SHORT)
                .show()
            return
        }

        ContentCaptureManager.launchContentCapture(contentCaptureLauncher)
    }
}
