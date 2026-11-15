package org.nslabs.ir_blaster

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * The "survive the vendor task killer" schedule.
 *
 * MIUI/HyperOS powerkeeper force-stops a foreground service after a while; a
 * foreground service by itself is not enough. Three independent doors bring the
 * process back, in this order of speed:
 *
 *  1. [arm] - an exact alarm that fires every [WAKE_INTERVAL_MS]. The broadcast
 *     itself grants a short allow-list, so the receiver may start the foreground
 *     service again from the background (Android 12+ restriction).
 *  2. [schedulePeriodicJob] - a persisted 15-minute JobScheduler job, the
 *     OS-sanctioned backstop that also survives a reboot.
 *  3. `IrGuardReceiver` on BOOT_COMPLETED / MY_PACKAGE_REPLACED.
 *
 * `setAlarmClock` is used when exact alarms are permitted: unlike
 * `setExactAndAllowWhileIdle` it is not batched by Doze, which is the case that
 * silently ate the earlier 45-second chain.
 */
object IrGuardScheduler {

    private const val TAG = "IrGuardScheduler"

    const val ACTION_GUARD_ALARM = "org.nslabs.irblaster.GUARD_ALARM"

    private const val ALARM_REQUEST = 4712
    private const val JOB_ID = 4713

    /** How often the alarm door fires. Short on purpose: MIUI kills in minutes. */
    const val WAKE_INTERVAL_MS = 45_000L

    private const val PERIODIC_JOB_MS = 15L * 60L * 1000L

    private fun alarmPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, IrGuardReceiver::class.java).apply {
            action = ACTION_GUARD_ALARM
        }
        return PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** (Re)arms the next wake-up. Safe to call many times: it replaces itself. */
    fun arm(context: Context, delayMs: Long = WAKE_INTERVAL_MS) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pending = alarmPendingIntent(app)
        val wait = delayMs.coerceAtLeast(5_000L)
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()

        try {
            if (exact) {
                // RTC based, exempt from Doze batching.
                val at = System.currentTimeMillis() + wait
                manager.setAlarmClock(AlarmManager.AlarmClockInfo(at, null), pending)
            } else {
                manager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    android.os.SystemClock.elapsedRealtime() + wait,
                    pending,
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "exact alarm refused (${t.javaClass.simpleName}: ${t.message}), falling back")
            try {
                manager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    android.os.SystemClock.elapsedRealtime() + wait,
                    pending,
                )
            } catch (t2: Throwable) {
                Log.w(TAG, "alarm scheduling failed: ${t2.message}")
            }
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        try {
            manager?.cancel(alarmPendingIntent(app))
        } catch (_: Throwable) {
        }
        cancelJobs(app)
    }

    fun schedulePeriodicJob(context: Context) {
        val app = context.applicationContext
        val scheduler = app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
        try {
            if (scheduler.getPendingJob(JOB_ID) != null) return
            val info = JobInfo.Builder(
                JOB_ID,
                ComponentName(app, IrGuardJobService::class.java),
            )
                .setPeriodic(PERIODIC_JOB_MS)
                .setPersisted(true)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
                .setBackoffCriteria(30_000L, JobInfo.BACKOFF_POLICY_LINEAR)
                .build()
            scheduler.schedule(info)
        } catch (t: Throwable) {
            Log.w(TAG, "periodic job refused: ${t.message}")
        }
    }

    fun cancelJobs(context: Context) {
        val app = context.applicationContext
        val scheduler = app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
        try {
            scheduler.cancel(JOB_ID)
        } catch (_: Throwable) {
        }
    }
}
