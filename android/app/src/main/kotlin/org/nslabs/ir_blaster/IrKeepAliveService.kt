package org.nslabs.ir_blaster

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.ConsumerIrManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process (and therefore the Flutter isolate) alive while a long IR
 * test is running, and — because MIUI/HyperOS powerkeeper kills even a
 * foreground service — carries the test on when the isolate is gone.
 *
 * Three layers:
 *  1. a `specialUse` foreground service with an ongoing progress notification
 *     and a Stop action (the normal, foreground case);
 *  2. a watchdog tick that notices a dead Dart isolate (no heartbeat for
 *     [IrGuard.TAKEOVER_AFTER_MS]) and continues a signal-tester NEC sweep
 *     natively, logging every send into the IR Log;
 *  3. the alarm + job chain in [IrGuardScheduler], so a killed process is
 *     restarted within a minute and picks the sweep up where it stopped.
 */
class IrKeepAliveService : Service() {

    companion object {
        private const val TAG = "IrKeepAliveService"
        private const val CHANNEL_ID = "ir_keep_alive"
        private const val NOTIFICATION_ID = 4711
        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val TICK_MS = 1_000L
        private const val SWEEP_INTERVAL_MS = 1_000L
        private const val NEC_FREQUENCY_HZ = 38_000
        private const val ALARM_RECOVER_MS = 3L * 60L * 1000L
        private const val TX_PREFS = "ir_blaster_prefs"

        const val ACTION_START = "org.nslabs.irblaster.KEEP_ALIVE_START"
        const val ACTION_UPDATE = "org.nslabs.irblaster.KEEP_ALIVE_UPDATE"
        const val ACTION_REVIVE = "org.nslabs.irblaster.KEEP_ALIVE_REVIVE"
        const val ACTION_STOP = "org.nslabs.irblaster.KEEP_ALIVE_STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_MODE = "mode"
        const val EXTRA_DEVICE = "device"
        const val EXTRA_COMMAND = "command"
        const val EXTRA_SENT = "sent"

        /** True while the foreground service is up (the process is protected). */
        @Volatile
        var running: Boolean = false
            private set

        /** Set when the user taps Stop in the notification. */
        @Volatile
        var stopRequested: Boolean = false
            private set

        private const val REVIVE_THROTTLE_MS = 5_000L

        @Volatile
        private var lastReviveAt = 0L

        fun start(
            context: Context,
            title: String,
            text: String,
            mode: String = IrGuard.MODE_PLAIN,
            device: Int = 0,
            command: Int = 0,
            sent: Int = 0,
        ) {
            stopRequested = false
            IrGuard.begin(context, title, mode, device, command, sent)
            val intent = Intent(context, IrKeepAliveService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_MODE, mode)
                putExtra(EXTRA_DEVICE, device)
                putExtra(EXTRA_COMMAND, command)
                putExtra(EXTRA_SENT, sent)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Throwable) {
                // Background start restrictions (Android 12+) or a dead process:
                // the run itself keeps working, only the protection is missing.
                Log.w(TAG, "start failed: ${e.message}")
            }
            IrGuardScheduler.arm(context)
            IrGuardScheduler.schedulePeriodicJob(context)
        }

        /**
         * Called by the alarm / boot / job doors. The caller holds a temporary
         * allow-list (alarm broadcast, boot broadcast, job), which is exactly
         * what Android 12+ requires to start a foreground service from the
         * background.
         */
        fun revive(context: Context) {
            if (!IrGuard.isActive(context)) return
            // Heartbeats arrive every second; do not storm the system with
            // start requests while the service is still coming up.
            val now = SystemClock.elapsedRealtime()
            if (now - lastReviveAt < REVIVE_THROTTLE_MS) return
            lastReviveAt = now
            val intent = Intent(context, IrKeepAliveService::class.java).apply {
                action = ACTION_REVIVE
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Throwable) {
                Log.w(TAG, "revive failed: ${e.message}")
            }
        }

        /** Dart heartbeat: the isolate is alive and stands on this sweep position. */
        fun beat(context: Context, mode: String, device: Int, command: Int, sent: Int) {
            IrGuard.setMode(context, mode)
            IrGuard.beat(context, device, command, sent)
            if (!running) revive(context)
        }

        /**
         * Sends the code the sweep stopped on and rolls to the next one, exactly
         * like `bruteforce(1, true)` does in the app: "dev ~dev cmd ~cmd".
         *
         * Reachable without a service instance on purpose: the persisted job
         * must be able to emit a code even when starting a foreground service is
         * refused (Android 12+ background-start rules).
         */
        fun sendOneNec(context: Context): Boolean {
            val app = context.applicationContext
            val ir = app.getSystemService(Context.CONSUMER_IR_SERVICE) as? ConsumerIrManager
                ?: return false
            val device = IrGuard.sweepDevice(app)
            if (device > 0xFF) return false
            val command = IrGuard.sweepCommand(app)
            val code = necCode(device, command)
            val pattern = necPattern(code)
            try {
                if (!ir.hasIrEmitter()) return false
                ir.transmit(NEC_FREQUENCY_HZ, pattern)
            } catch (t: Throwable) {
                IrGuard.setLastError(app, t.message ?: "transmit failed")
                Log.w(TAG, "native transmit failed: ${t.message}")
                return false
            }
            IrGuard.setLastError(app, null)
            IrGuard.logNativeSend(
                app,
                necLabel(device, command),
                "NEC",
                code.toUInt().toString(16).uppercase(),
                NEC_FREQUENCY_HZ,
                pattern.size,
                "Signal Tester",
            )

            var nextCommand = command + 1
            var nextDevice = device
            if (nextCommand > 0xFF) {
                nextCommand = 0
                nextDevice += 1
            }
            val sent = IrGuard.sweepSent(app) + 1
            if (nextDevice > 0xFF) {
                IrGuard.setSweepState(app, device, command, sent)
                Log.i(TAG, "NEC sweep reached the end of the range")
            } else {
                IrGuard.setSweepState(app, nextDevice, nextCommand, sent)
            }
            return true
        }

        /** True when the built-in emitter exists (USB/audio paths need Dart). */
        fun internalEmitterReady(context: Context): Boolean {
            val app = context.applicationContext
            val type = try {
                app.getSharedPreferences(TX_PREFS, Context.MODE_PRIVATE).getString("tx_type", "INTERNAL")
            } catch (_: Throwable) {
                "INTERNAL"
            }
            if (type != null && type != "INTERNAL") return false
            val ir = app.getSystemService(Context.CONSUMER_IR_SERVICE) as? ConsumerIrManager
                ?: return false
            return try {
                ir.hasIrEmitter()
            } catch (_: Throwable) {
                false
            }
        }

        private fun necCode(device: Int, command: Int): Int {
            val d = device and 0xFF
            val c = command and 0xFF
            return (d shl 24) or ((d.inv() and 0xFF) shl 16) or (c shl 8) or (c.inv() and 0xFF)
        }

        private fun necLabel(device: Int, command: Int): String {
            val d = device and 0xFF
            val c = command and 0xFF
            return "NEC ${hex2(d)} ${hex2(d.inv() and 0xFF)} ${hex2(c)} ${hex2(c.inv() and 0xFF)}"
        }

        private fun hex2(value: Int): String = value.toString(16).padStart(2, '0').uppercase()

        /** Same header / bit / trailer timings and bit order as the Dart encoder. */
        private fun necPattern(code: Int): IntArray {
            val pattern = ArrayList<Int>(67)
            pattern.add(9000)
            pattern.add(4500)
            for (i in 31 downTo 0) {
                pattern.add(560)
                pattern.add(if (((code ushr i) and 0x1) == 1) 1690 else 560)
            }
            pattern.add(560)
            return pattern.toIntArray()
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
            IrGuard.end(context)
            IrGuardScheduler.cancel(context)
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
    private val handler = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null
    private var lastNativeSendAt = 0L
    private var nativeSendsSinceNotify = 0
    private var takeover = false
    private var interruptedNotified = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        IrGuard.noteProcessStart(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRequested = true
                endRun()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                stopRequested = false
                takeover = false
                interruptedNotified = false
                val title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { "IR test running" }
                val text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                enterForeground(title, text)
                IrGuardScheduler.arm(this)
                IrGuardScheduler.schedulePeriodicJob(this)
            }

            ACTION_REVIVE -> {
                stopRequested = false
                takeover = false
                interruptedNotified = false
                enterForeground(IrGuard.title(this), revivingText())
                IrGuardScheduler.arm(this)
                IrGuardScheduler.schedulePeriodicJob(this)
            }

            ACTION_UPDATE -> {
                if (!running) {
                    enterForeground(IrGuard.title(this), revivingText())
                } else {
                    val title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { IrGuard.title(this) }
                    val text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                    notify(title, text)
                }
            }

            else -> {
                // START_STICKY restart (null intent) or an unknown action.
                if (!IrGuard.isActive(this)) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                enterForeground(IrGuard.title(this), revivingText())
                IrGuardScheduler.arm(this)
                IrGuardScheduler.schedulePeriodicJob(this)
            }
        }
        startTicker()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        stopTicker()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun enterForeground(title: String, text: String) {
        try {
            acquireWakeLock()
            startForegroundCompat(title, text)
            running = true
        } catch (t: Throwable) {
            Log.w(TAG, "startForeground failed: ${t.message}")
            running = false
            stopSelf()
        }
    }

    private fun endRun() {
        running = false
        stopTicker()
        releaseWakeLock()
        IrGuard.end(this)
        IrGuardScheduler.cancel(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    // ---------------------------------------------------------------- watchdog

    private fun startTicker() {
        stopTicker()
        val runnable = object : Runnable {
            override fun run() {
                try {
                    onTick()
                } catch (t: Throwable) {
                    Log.w(TAG, "tick failed: ${t.message}")
                }
                handler.postDelayed(this, TICK_MS)
            }
        }
        ticker = runnable
        handler.postDelayed(runnable, TICK_MS)
    }

    private fun stopTicker() {
        ticker?.let { handler.removeCallbacks(it) }
        ticker = null
    }

    private fun onTick() {
        if (!running) return
        renewWakeLock()

        if (!IrGuard.isActive(this)) {
            endRun()
            return
        }
        if (stopRequested) {
            endRun()
            return
        }

        // Belt and braces: if the alarm chain was wiped (force-stop), restore it.
        val sinceAlarm = System.currentTimeMillis() - IrGuard.lastAlarmWall(this)
        if (sinceAlarm > ALARM_RECOVER_MS) {
            IrGuardScheduler.arm(this)
        }

        if (IrGuard.mode(this) != IrGuard.MODE_NEC) {
            // Finder runs need the Dart side; the guard can only keep the
            // process pinned and report the interruption honestly.
            if (IrGuard.isStale(this) && !interruptedNotified) {
                interruptedNotified = true
                notify("IR test interrupted", "The phone stopped the app. Open it to continue the run.")
            }
            return
        }

        val stale = IrGuard.ageMs(this) > IrGuard.TAKEOVER_AFTER_MS
        if (!stale) {
            if (takeover) {
                takeover = false
                nativeSendsSinceNotify = 0
                notify(IrGuard.title(this), "The app is back — sweep continued by the app.")
            }
            return
        }

        if (!takeover) {
            takeover = true
            interruptedNotified = false
            Log.i(TAG, "Dart isolate is gone (age ${IrGuard.ageMs(this)} ms): native takeover")
            if (!internalTransmitterReady()) {
                notify("IR test interrupted", "The phone stopped the app. Open it to continue the sweep.")
                return
            }
        }
        if (!internalTransmitterReady()) return

        val now = SystemClock.elapsedRealtime()
        if (now - lastNativeSendAt < SWEEP_INTERVAL_MS) return
        lastNativeSendAt = now
        sendNextNec()
        nativeSendsSinceNotify++
        if (nativeSendsSinceNotify >= 3) {
            nativeSendsSinceNotify = 0
            notify(IrGuard.title(this), sweepText())
        }
    }

    /** Only the built-in emitter can be driven without the Flutter isolate. */
    private fun internalTransmitterReady(): Boolean = internalEmitterReady(this)

    private fun sendNextNec() {
        sendOneNec(this)
    }

    private fun sweepText(): String {
        val device = IrGuard.sweepDevice(this)
        val command = IrGuard.sweepCommand(this)
        val sent = IrGuard.sweepSent(this)
        return "${necLabel(device, command)} · $sent sent · running without the app"
    }

    private fun revivingText(): String {
        if (IrGuard.mode(this) != IrGuard.MODE_NEC) {
            return "Restarted by the system — open the app to continue the run."
        }
        val sent = IrGuard.sweepSent(this)
        return "${necLabel(IrGuard.sweepDevice(this), IrGuard.sweepCommand(this))} · $sent sent · restarted by the system"
    }

    // ------------------------------------------------------------ notification

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

        val batteryIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val batteryPending = PendingIntent.getActivity(
            this,
            2,
            batteryIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openPending)
            .addAction(0, "Stop", stopPending)
            .addAction(0, "Battery", batteryPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    // -------------------------------------------------------------- wake lock

    private fun acquireWakeLock() {
        val lock = ensureWakeLock() ?: return
        try {
            if (!lock.isHeld) lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        } catch (_: Throwable) {
        }
    }

    /** The 30-minute lock expires: renew it while the test still runs. */
    private fun renewWakeLock() {
        val lock = ensureWakeLock() ?: return
        try {
            if (!lock.isHeld) lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        } catch (_: Throwable) {
        }
    }

    private fun ensureWakeLock(): PowerManager.WakeLock? {
        wakeLock?.let { return it }
        return try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "irblaster:ir_test")
                .also { wakeLock = it }
        } catch (_: Throwable) {
            null
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
