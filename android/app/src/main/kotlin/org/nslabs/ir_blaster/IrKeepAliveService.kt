package org.nslabs.ir_blaster

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process (and therefore the Flutter isolate) alive while a long IR
 * test is running: the signal tester sweep and the finder run both continue
 * sending signals and writing to the IR log when the app is backgrounded.
 *
 * It owns a low-importance ongoing notification that shows the live progress and
 * offers a Stop action; [stopRequested] lets Dart end the run when that action is
 * tapped. Nothing is started unless Dart asks for it, and it never restarts
 * itself (START_NOT_STICKY).
 */
class IrKeepAliveService : Service() {

    companion object {
        private const val TAG = "IrKeepAliveService"
        private const val CHANNEL_ID = "ir_keep_alive"
        private const val NOTIFICATION_ID = 4711
        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L

        const val ACTION_START = "org.nslabs.irblaster.KEEP_ALIVE_START"
        const val ACTION_UPDATE = "org.nslabs.irblaster.KEEP_ALIVE_UPDATE"
        const val ACTION_STOP = "org.nslabs.irblaster.KEEP_ALIVE_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /** True while the foreground service is up (the process is protected). */
        @Volatile
        var running: Boolean = false
            private set

        /** Set when the user taps Stop in the notification. */
        @Volatile
        var stopRequested: Boolean = false
            private set

        fun start(context: Context, title: String, text: String) {
            stopRequested = false
            val intent = Intent(context, IrKeepAliveService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Throwable) {
                // Background start restrictions (Android 12+) or a dead process:
                // the run itself keeps working, only the protection is missing.
                android.util.Log.w(TAG, "start failed: ${e.message}")
            }
        }

        fun update(context: Context, title: String, text: String) {
            if (!running) return
            val intent = Intent(context, IrKeepAliveService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
            }
        }

        fun clearStopRequest() {
            stopRequested = false
        }

        fun stop(context: Context) {
            stopRequested = false
            val intent = Intent(context, IrKeepAliveService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
            }
            try {
                context.stopService(Intent(context, IrKeepAliveService::class.java))
            } catch (_: Throwable) {
            }
            running = false
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { "IR test running" }
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()

        when (intent?.action) {
            ACTION_STOP -> {
                stopRequested = true
                shutdown()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                stopRequested = false
                acquireWakeLock()
                startForegroundCompat(title, text)
                running = true
            }

            else -> {
                if (!running) {
                    acquireWakeLock()
                    startForegroundCompat(title, text)
                    running = true
                } else {
                    notify(title, text)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun shutdown() {
        running = false
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "IR test in progress",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows the running IR test and keeps it alive in the background."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun startForegroundCompat(title: String, text: String) {
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notify(title: String, text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(title, text))
        } catch (_: Throwable) {
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, IrKeepAliveService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openPending)
            .addAction(0, "Stop", stopPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun acquireWakeLock() {
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = wakeLock
                ?: power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "irblaster:ir_test")
                    .also { wakeLock = it }
            if (!lock.isHeld) {
                lock.acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (_: Throwable) {
        }
    }

    private fun releaseWakeLock() {
        try {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
        } catch (_: Throwable) {
        }
        wakeLock = null
    }
}
