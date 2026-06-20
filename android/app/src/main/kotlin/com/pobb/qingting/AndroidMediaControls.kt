package com.pobb.qingting

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class AndroidMediaControls(
    private val context: Context,
    private val channel: MethodChannel,
) {
    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val mediaSession = MediaSession(context, "QingTingMediaSession").apply {
        setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        setSessionActivity(launchPendingIntent())
        setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                invokeDart("play")
            }

            override fun onPause() {
                invokeDart("pause")
            }

            override fun onSkipToPrevious() {
                invokeDart("previous")
            }

            override fun onSkipToNext() {
                invokeDart("next")
            }

            override fun onSeekTo(pos: Long) {
                invokeDart("seek", mapOf("positionMs" to pos.coerceAtLeast(0L)))
            }

            override fun onStop() {
                invokeDart("pause")
            }
        })
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastArtworkPath: String? = null
    private var lastArtwork: Bitmap? = null

    init {
        activeControls = WeakReference(this)
        ensureNotificationChannel()
    }

    fun update(call: MethodCall): Boolean {
        requestNotificationPermissionIfNeeded()
        val info = MediaControlInfo(
            title = call.argument<String>("title").orEmpty().ifBlank { "QingTing" },
            artist = call.argument<String>("artist").orEmpty(),
            album = call.argument<String>("album").orEmpty(),
            durationMs = call.longArgument("durationMs", 0L).coerceAtLeast(0L),
            positionMs = call.longArgument("positionMs", 0L).coerceAtLeast(0L),
            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
            canPlayPrevious = call.argument<Boolean>("canPlayPrevious") ?: false,
            canPlayNext = call.argument<Boolean>("canPlayNext") ?: false,
            coverFilePath = call.argument<String>("coverFilePath"),
        )
        mediaSession.setMetadata(buildMetadata(info))
        mediaSession.setPlaybackState(buildPlaybackState(info))
        mediaSession.isActive = true
        notificationManager.notify(notificationId, buildNotification(info))
        return true
    }

    fun hide() {
        notificationManager.cancel(notificationId)
        mediaSession.isActive = false
    }

    fun destroy() {
        hide()
        mediaSession.release()
        if (activeControls?.get() === this) {
            activeControls = null
        }
    }

    private fun handleAction(action: String?) {
        when (action) {
            actionPlay -> invokeDart("play")
            actionPause -> invokeDart("pause")
            actionToggle -> invokeDart("toggle")
            actionPrevious -> invokeDart("previous")
            actionNext -> invokeDart("next")
        }
    }

    private fun invokeDart(method: String, arguments: Any? = null) {
        mainHandler.post {
            channel.invokeMethod(method, arguments)
        }
    }

    private fun buildMetadata(info: MediaControlInfo): MediaMetadata {
        val builder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, info.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, info.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, info.durationMs)
        decodeArtwork(info.coverFilePath)?.let { artwork ->
            builder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, artwork)
            builder.putBitmap(MediaMetadata.METADATA_KEY_ART, artwork)
        }
        return builder.build()
    }

    private fun buildPlaybackState(info: MediaControlInfo): PlaybackState {
        var actions =
            PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or
                PlaybackState.ACTION_SEEK_TO
        if (info.canPlayPrevious) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        }
        if (info.canPlayNext) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        }
        val state = if (info.isPlaying) {
            PlaybackState.STATE_PLAYING
        } else {
            PlaybackState.STATE_PAUSED
        }
        val speed = if (info.isPlaying) 1.0f else 0.0f
        return PlaybackState.Builder()
            .setActions(actions)
            .setState(state, info.positionMs, speed, SystemClock.elapsedRealtime())
            .build()
    }

    private fun buildNotification(info: MediaControlInfo): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, notificationChannelId)
        } else {
            Notification.Builder(context)
        }
        val subText = info.album.takeIf { it.isNotBlank() }
        val playPauseAction = if (info.isPlaying) {
            notificationAction(
                R.drawable.ic_media_pause_24,
                "Pause",
                actionPause,
            )
        } else {
            notificationAction(
                R.drawable.ic_media_play_24,
                "Play",
                actionPlay,
            )
        }

        builder
            .setSmallIcon(R.drawable.ic_stat_qingting)
            .setContentTitle(info.title)
            .setContentText(info.artist.ifBlank { info.album })
            .setSubText(subText)
            .setContentIntent(launchPendingIntent())
            .setDeleteIntent(actionPendingIntent(actionPause))
            .setOnlyAlertOnce(true)
            .setOngoing(info.isPlaying)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setColor(Color.rgb(47, 126, 85))
            .addAction(
                notificationAction(
                    R.drawable.ic_media_previous_24,
                    "Previous",
                    actionPrevious,
                )
            )
            .addAction(playPauseAction)
            .addAction(
                notificationAction(
                    R.drawable.ic_media_next_24,
                    "Next",
                    actionNext,
                )
            )
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
        decodeArtwork(info.coverFilePath)?.let { artwork ->
            builder.setLargeIcon(artwork)
        }
        return builder.build()
    }

    private fun notificationAction(
        icon: Int,
        title: String,
        action: String,
    ): Notification.Action {
        return Notification.Action.Builder(
            icon,
            title,
            actionPendingIntent(action),
        ).build()
    }

    private fun actionPendingIntent(action: String): PendingIntent {
        val intent = Intent(context, MediaControlReceiver::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context,
            action.hashCode(),
            intent,
            pendingIntentFlags(),
        )
    }

    private fun launchPendingIntent(): PendingIntent {
        val intent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, 0, intent, pendingIntentFlags())
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            notificationChannelId,
            "QingTing playback",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Playback controls"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        (context as? Activity)?.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequestCode,
        )
    }

    private fun decodeArtwork(path: String?): Bitmap? {
        val normalizedPath = path?.takeIf { it.isNotBlank() }
        if (normalizedPath == lastArtworkPath) {
            return lastArtwork
        }
        lastArtworkPath = normalizedPath
        lastArtwork = null
        if (normalizedPath == null) {
            return null
        }
        return try {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(normalizedPath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                return null
            }
            var sampleSize = 1
            while (
                bounds.outWidth / sampleSize > maxArtworkSize ||
                bounds.outHeight / sampleSize > maxArtworkSize
            ) {
                sampleSize *= 2
            }
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(normalizedPath, options).also {
                lastArtwork = it
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun MethodCall.longArgument(name: String, fallback: Long): Long {
        return when (val value = argument<Any>(name)) {
            is Number -> value.toLong()
            else -> fallback
        }
    }

    private data class MediaControlInfo(
        val title: String,
        val artist: String,
        val album: String,
        val durationMs: Long,
        val positionMs: Long,
        val isPlaying: Boolean,
        val canPlayPrevious: Boolean,
        val canPlayNext: Boolean,
        val coverFilePath: String?,
    )

    companion object {
        private const val notificationChannelId = "qingting_playback"
        private const val notificationId = 2301
        private const val notificationPermissionRequestCode = 2302
        private const val maxArtworkSize = 512
        private const val actionPlay = "com.pobb.qingting.action.PLAY"
        private const val actionPause = "com.pobb.qingting.action.PAUSE"
        private const val actionToggle = "com.pobb.qingting.action.TOGGLE"
        private const val actionPrevious = "com.pobb.qingting.action.PREVIOUS"
        private const val actionNext = "com.pobb.qingting.action.NEXT"
        private var activeControls: WeakReference<AndroidMediaControls>? = null

        fun dispatchAction(action: String?) {
            activeControls?.get()?.handleAction(action)
        }

        private fun pendingIntentFlags(): Int {
            return PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
        }
    }
}

class MediaControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AndroidMediaControls.dispatchAction(intent.action)
    }
}
