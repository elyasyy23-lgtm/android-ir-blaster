package org.nslabs.ir_blaster

import android.app.job.JobParameters
import android.app.job.JobService
import android.util.Log

/**
 * Door #2 of the survival ladder: a persisted periodic job. JobScheduler is
 * part of the OS (not of the killed app process), so it still fires when the
 * vendor task killer stopped us, and it re-registers itself across reboots.
 *
 * The job runs in a freshly started process, so it can always emit one NEC code
 * on its own - that path needs no foreground service and therefore cannot be
 * refused by the Android 12+ background-start rules.
 */
class IrGuardJobService : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        val app = applicationContext
        try {
            if (IrGuard.isActive(app)) {
                Log.i(TAG, "job: reviving test (beat age ${IrGuard.ageMs(app)} ms)")
                if (IrGuard.mode(app) == IrGuard.MODE_NEC &&
                    IrKeepAliveService.internalEmitterReady(app)
                ) {
                    // Even if the service start below is refused, the sweep moves.
                    IrKeepAliveService.sendOneNec(app)
                }
                IrKeepAliveService.revive(app)
                IrGuardScheduler.arm(app)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "job revive failed: ${t.message}")
        }
        jobFinished(params, false)
        return false
    }

    /** true = ask JobScheduler to reschedule the periodic job. */
    override fun onStopJob(params: JobParameters?): Boolean = true

    private companion object {
        const val TAG = "IrGuardJobService"
    }
}
