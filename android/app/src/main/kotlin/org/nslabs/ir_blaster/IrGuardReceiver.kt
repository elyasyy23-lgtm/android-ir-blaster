package org.nslabs.ir_blaster

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Door #1 and #3 of the survival ladder: the exact alarm, the reboot broadcast
 * and the "app was just updated" broadcast all land here.
 *
 * The receiver runs in whatever process the system starts for it. If a test was
 * supposed to be running it starts the foreground service again and re-arms the
 * next alarm, so the chain never breaks.
 */
class IrGuardReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        when (action) {
            IrGuardScheduler.ACTION_GUARD_ALARM,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> Unit
            else -> return
        }

        val app = context.applicationContext
        if (action == IrGuardScheduler.ACTION_GUARD_ALARM) {
            IrGuard.markAlarm(app)
        }

        if (!IrGuard.isActive(app)) {
            Log.i(TAG, "$action: no test active, nothing to revive")
            IrGuardScheduler.cancel(app)
            return
        }

        Log.i(
            TAG,
            "$action: reviving test (beat age ${IrGuard.ageMs(app)} ms, " +
                "revives ${IrGuard.revives(app)})",
        )
        IrGuard.noteRevive(app)
        IrKeepAliveService.revive(app)
        // Keep the chain alive even if the service start is refused right now.
        IrGuardScheduler.arm(app)
        IrGuardScheduler.schedulePeriodicJob(app)
    }

    private companion object {
        const val TAG = "IrGuardReceiver"
    }
}
