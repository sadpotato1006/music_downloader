package com.pobb.qingting

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRouter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val storageChannel = "qingting/storage"
    private val desktopLyricsChannel = "qingting/desktop_lyrics"
    private val mediaControlsChannel = "qingting/media_controls"
    private val audioRouteChannel = "qingting/audio_route"
    private var lyricOverlayView: TextView? = null
    private var lyricOverlayParams: WindowManager.LayoutParams? = null
    private var androidMediaControls: AndroidMediaControls? = null
    private var audioRouteMethodChannel: MethodChannel? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private var mediaRouter: MediaRouter? = null
    private var mediaRouterCallback: MediaRouter.Callback? = null
    private var bluetoothAudioDeviceIds = emptySet<Int>()
    private var selectedBluetoothRouteKey: String? = null
    private var audioRouteInitialized = false
    private var lastBluetoothRouteNotificationAt = 0L
    private val overlayWindowManager: WindowManager by lazy {
        getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "openAllFilesAccessSettings" -> {
                    openAllFilesAccessSettings()
                    result.success(null)
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    result.success(openUrl(url))
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, desktopLyricsChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val shown = updateDesktopLyricsOverlay(
                        enabled = call.argument<Boolean>("enabled") ?: false,
                        text = call.argument<String>("text").orEmpty(),
                        fontSize = call.doubleArgument("fontSize", 22.0),
                        colorValue = call.longArgument("colorValue", 0xFF4AA66AL).toInt(),
                        verticalPosition = call.doubleArgument("verticalPosition", 0.78),
                        backgroundOpacity = call.doubleArgument("backgroundOpacity", 0.12),
                    )
                    result.success(shown)
                }
                "hide" -> {
                    hideDesktopLyricsOverlay()
                    result.success(null)
                }
                "isOverlayPermissionGranted" -> result.success(hasOverlayPermission())
                "openOverlayPermissionSettings" -> {
                    openOverlayPermissionSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val mediaControlsMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaControlsChannel)
        val mediaControls = AndroidMediaControls(this, mediaControlsMethodChannel)
        androidMediaControls = mediaControls
        mediaControlsMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> result.success(mediaControls.update(call))
                "hide" -> {
                    mediaControls.hide()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        startAudioRouteMonitoring(flutterEngine)
    }

    override fun onDestroy() {
        stopAudioRouteMonitoring()
        hideDesktopLyricsOverlay()
        androidMediaControls?.destroy()
        androidMediaControls = null
        super.onDestroy()
    }

    private fun startAudioRouteMonitoring(flutterEngine: FlutterEngine) {
        stopAudioRouteMonitoring()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioRouteMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioRouteChannel)
        bluetoothAudioDeviceIds = connectedBluetoothAudioDeviceIds(audioManager)
        val mediaRouter = getSystemService(Context.MEDIA_ROUTER_SERVICE) as MediaRouter
        this.mediaRouter = mediaRouter
        updateSelectedAudioRoute(mediaRouter)
        val mediaRouterCallback = object : MediaRouter.SimpleCallback() {
            override fun onRouteSelected(
                router: MediaRouter,
                type: Int,
                info: MediaRouter.RouteInfo,
            ) {
                updateSelectedAudioRoute(router)
            }

            override fun onRouteUnselected(
                router: MediaRouter,
                type: Int,
                info: MediaRouter.RouteInfo,
            ) {
                updateSelectedAudioRoute(router)
            }

            override fun onRouteChanged(
                router: MediaRouter,
                info: MediaRouter.RouteInfo,
            ) {
                updateSelectedAudioRoute(router)
            }
        }
        this.mediaRouterCallback = mediaRouterCallback
        mediaRouter.addCallback(
            MediaRouter.ROUTE_TYPE_LIVE_AUDIO,
            mediaRouterCallback,
            MediaRouter.CALLBACK_FLAG_UNFILTERED_EVENTS,
        )
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                bluetoothAudioDeviceIds = connectedBluetoothAudioDeviceIds(audioManager)
                updateSelectedAudioRoute(mediaRouter)
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                val removedConnectedBluetoothDevice = removedDevices.any {
                    isBluetoothMediaOutput(it) && bluetoothAudioDeviceIds.contains(it.id)
                }
                bluetoothAudioDeviceIds = connectedBluetoothAudioDeviceIds(audioManager)
                if (
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.N &&
                    removedConnectedBluetoothDevice
                ) {
                    notifyBluetoothRouteChanged()
                }
                updateSelectedAudioRoute(mediaRouter)
            }
        }
        audioDeviceCallback = callback
        audioManager.registerAudioDeviceCallback(
            callback,
            Handler(Looper.getMainLooper()),
        )
    }

    private fun stopAudioRouteMonitoring() {
        val callback = audioDeviceCallback
        if (callback != null) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                audioManager.unregisterAudioDeviceCallback(callback)
            } catch (_: Exception) {
            }
        }
        val router = mediaRouter
        val routerCallback = mediaRouterCallback
        if (router != null && routerCallback != null) {
            router.removeCallback(routerCallback)
        }
        audioDeviceCallback = null
        mediaRouter = null
        mediaRouterCallback = null
        audioRouteMethodChannel = null
        bluetoothAudioDeviceIds = emptySet()
        selectedBluetoothRouteKey = null
        audioRouteInitialized = false
        lastBluetoothRouteNotificationAt = 0L
    }

    private fun updateSelectedAudioRoute(router: MediaRouter) {
        val route = router.getSelectedRoute(MediaRouter.ROUTE_TYPE_LIVE_AUDIO)
        val nextBluetoothRouteKey =
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                route.deviceType == MediaRouter.RouteInfo.DEVICE_TYPE_BLUETOOTH
            ) {
                route.name.toString()
            } else {
                null
            }
        val routeLostOrSwitched =
            audioRouteInitialized &&
                selectedBluetoothRouteKey != null &&
                selectedBluetoothRouteKey != nextBluetoothRouteKey
        selectedBluetoothRouteKey = nextBluetoothRouteKey
        audioRouteInitialized = true
        if (routeLostOrSwitched) {
            notifyBluetoothRouteChanged()
        }
    }

    private fun notifyBluetoothRouteChanged() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastBluetoothRouteNotificationAt < 750L) {
            return
        }
        lastBluetoothRouteNotificationAt = now
        audioRouteMethodChannel?.invokeMethod(
            "bluetoothDisconnectedOrSwitched",
            null,
        )
    }

    private fun connectedBluetoothAudioDeviceIds(audioManager: AudioManager): Set<Int> {
        return audioManager
            .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .asSequence()
            .filter(::isBluetoothMediaOutput)
            .map(AudioDeviceInfo::getId)
            .toSet()
    }

    private fun isBluetoothMediaOutput(device: AudioDeviceInfo): Boolean {
        if (!device.isSink) {
            return false
        }
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HEARING_AID,
            -> true
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            AudioDeviceInfo.TYPE_BLE_BROADCAST ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            else -> false
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val appIntent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            )
            try {
                startActivity(appIntent)
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) {
            return false
        }
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.addCategory(Intent.CATEGORY_BROWSABLE)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun hasOverlayPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
    }

    private fun openOverlayPermissionSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {
            }
        }
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    private fun updateDesktopLyricsOverlay(
        enabled: Boolean,
        text: String,
        fontSize: Double,
        colorValue: Int,
        verticalPosition: Double,
        backgroundOpacity: Double,
    ): Boolean {
        if (!enabled || text.isBlank()) {
            hideDesktopLyricsOverlay()
            return true
        }
        if (!hasOverlayPermission()) {
            hideDesktopLyricsOverlay()
            return false
        }

        val view = lyricOverlayView ?: TextView(applicationContext).also {
            it.gravity = Gravity.CENTER
            it.maxLines = 2
            it.ellipsize = TextUtils.TruncateAt.END
            it.includeFontPadding = false
            it.typeface = Typeface.DEFAULT_BOLD
            lyricOverlayView = it
        }
        val metrics = resources.displayMetrics
        view.maxWidth = (metrics.widthPixels - dp(36f).roundToInt()).coerceAtLeast(dp(180f).roundToInt())
        view.text = text
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize.coerceIn(14.0, 72.0).toFloat())
        view.setTextColor(colorValue)
        view.setShadowLayer(dp(4f), 0f, dp(1.5f), Color.argb(132, 0, 0, 0))
        view.setPadding(
            dp(16f).roundToInt(),
            dp(9f).roundToInt(),
            dp(16f).roundToInt(),
            dp(9f).roundToInt()
        )
        view.background = GradientDrawable().apply {
            cornerRadius = dp(16f)
            setColor(Color.argb((backgroundOpacity.coerceIn(0.0, 0.85) * 255).roundToInt(), 0, 0, 0))
        }

        val params = lyricOverlayParams ?: createDesktopLyricsLayoutParams().also {
            lyricOverlayParams = it
        }
        val availableHeight = (metrics.heightPixels - dp(96f)).coerceAtLeast(dp(160f))
        params.y = (availableHeight * verticalPosition.coerceIn(0.0, 1.0)).roundToInt()

        return try {
            if (view.parent == null) {
                overlayWindowManager.addView(view, params)
            } else {
                overlayWindowManager.updateViewLayout(view, params)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun createDesktopLyricsLayoutParams(): WindowManager.LayoutParams {
        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_PHONE
        }
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = 0
        }
    }

    private fun hideDesktopLyricsOverlay() {
        val view = lyricOverlayView ?: return
        try {
            if (view.parent != null) {
                overlayWindowManager.removeView(view)
            }
        } catch (_: Exception) {
        }
        lyricOverlayView = null
        lyricOverlayParams = null
    }

    private fun MethodCall.doubleArgument(name: String, fallback: Double): Double {
        return when (val value = argument<Any>(name)) {
            is Number -> value.toDouble()
            else -> fallback
        }
    }

    private fun MethodCall.longArgument(name: String, fallback: Long): Long {
        return when (val value = argument<Any>(name)) {
            is Number -> value.toLong()
            else -> fallback
        }
    }

    private fun dp(value: Float): Float {
        return value * resources.displayMetrics.density
    }
}
