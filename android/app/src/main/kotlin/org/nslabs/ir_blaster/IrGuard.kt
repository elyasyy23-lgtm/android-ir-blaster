package org.nslabs.ir_blaster

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

/**
 * Shared state for "an IR test is supposed to be running right now".
 *
 * It lives in SharedPreferences so it survives a process kill: the alarm / job /
 * boot receivers read it after the system restarted the app and know whether a
 * test was interrupted. Dart stamps a heartbeat (with the current sweep
 * position) on every tick, so a stale heartbeat is proof that the Flutter
 * isolate was killed - and the last known position lets the native fallback
 * carry the sweep on from the exact code Dart reached.
 */
object IrGuard {

    private const val PREFS = "ir_guard"

    private const val KEY_ACTIVE = "active"
    private const val KEY_TITLE = "title"
    private const val KEY_MODE = "mode"
    private const val KEY_DEVICE = "nec_device"
    private const val KEY_COMMAND = "nec_command"
    private const val KEY_SENT = "sent"
    private const val KEY_STARTED_WALL = "started_wall"
    private const val KEY_LAST_BEAT_WALL = "last_beat_wall"
    private const val KEY_LAST_BEAT_ELAPSED = "last_beat_elapsed"
    private const val KEY_LAST_ALARM_WALL = "last_alarm_wall"
    private const val KEY_PROCESS_STARTS = "process_starts"
    private const val KEY_REVIVES = "revives"
    private const val KEY_NATIVE_SENDS = "native_sends"
    private const val KEY_LAST_ERROR = "last_error"
    private const val KEY_BATTERY_PROMPT = "battery_prompt_done"

    /** Sweep modes: "nec" = signal-tester bruteforce (native fallback can send). */
    const val MODE_NEC = "nec"
    const val MODE_PLAIN = "plain"

    /** A heartbeat older than this means the sending loop is gone entirely. */
    const val STALE_AFTER_MS = 45_000L

    /** Dart beats every sweep tick (1 s); a gap this long means take over. */
    const val TAKEOVER_AFTER_MS = 8_000L

    /** shared_preferences plugin storage: native entries are merged by Dart. */
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val NATIVE_LOG_KEY = "flutter.native_ir_signal_log"
    private const val NATIVE_LOG_LIMIT = 800

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isActive(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ACTIVE, false)

    fun title(context: Context): String =
        prefs(context).getString(KEY_TITLE, null) ?: "IR test"

    fun mode(context: Context): String =
        prefs(context).getString(KEY_MODE, MODE_PLAIN) ?: MODE_PLAIN

    /** Dart tells us what the running loop can be resumed as (nec / plain). */
    fun setMode(context: Context, mode: String) {
        prefs(context).edit().putString(KEY_MODE, mode).apply()
    }

    /** Called by the foreground service when a run starts. */
    fun begin(context: Context, title: String, mode: String, device: Int, command: Int, sent: Int) {
        prefs(context).edit()
            .putBoolean(KEY_ACTIVE, true)
            .putString(KEY_TITLE, title)
            .putString(KEY_MODE, mode)
            .putInt(KEY_DEVICE, device and 0xFF)
            .putInt(KEY_COMMAND, command and 0xFF)
            .putInt(KEY_SENT, sent)
            .putInt(KEY_REVIVES, 0)
            .putInt(KEY_NATIVE_SENDS, 0)
            .putLong(KEY_STARTED_WALL, System.currentTimeMillis())
            .remove(KEY_LAST_ERROR)
            .apply()
        beat(context, device, command, sent)
    }

    /** Dart is alive: remember the position so a native takeover resumes there. */
    fun beat(context: Context, device: Int, command: Int, sent: Int) {
        prefs(context).edit()
            .putInt(KEY_DEVICE, device and 0xFF)
            .putInt(KEY_COMMAND, command and 0xFF)
            .putInt(KEY_SENT, sent)
            .putLong(KEY_LAST_BEAT_WALL, System.currentTimeMillis())
            .putLong(KEY_LAST_BEAT_ELAPSED, SystemClock.elapsedRealtime())
            .apply()
    }

    /** Called when the run stops normally, so nothing tries to revive it. */
    fun end(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_ACTIVE, false)
            .apply()
    }

    fun ageMs(context: Context): Long {
        val elapsed = prefs(context).getLong(KEY_LAST_BEAT_ELAPSED, 0L)
        if (elapsed <= 0L) return Long.MAX_VALUE
        return SystemClock.elapsedRealtime() - elapsed
    }

    fun isStale(context: Context): Boolean = ageMs(context) > STALE_AFTER_MS

    fun lastBeatWall(context: Context): Long =
        prefs(context).getLong(KEY_LAST_BEAT_WALL, 0L)

    fun sweepDevice(context: Context): Int = prefs(context).getInt(KEY_DEVICE, 0)
    fun sweepCommand(context: Context): Int = prefs(context).getInt(KEY_COMMAND, 0)
    fun sweepSent(context: Context): Int = prefs(context).getInt(KEY_SENT, 0)

    fun setSweepState(context: Context, device: Int, command: Int, sent: Int) {
        prefs(context).edit()
            .putInt(KEY_DEVICE, device and 0xFF)
            .putInt(KEY_COMMAND, command and 0xFF)
            .putInt(KEY_SENT, sent)
            .apply()
    }

    fun markAlarm(context: Context) {
        prefs(context).edit()
            .putLong(KEY_LAST_ALARM_WALL, System.currentTimeMillis())
            .apply()
    }

    fun lastAlarmWall(context: Context): Long =
        prefs(context).getLong(KEY_LAST_ALARM_WALL, 0L)

    /** Counts how many times the system started our process (diagnostics). */
    fun noteProcessStart(context: Context) {
        val p = prefs(context)
        p.edit().putInt(KEY_PROCESS_STARTS, p.getInt(KEY_PROCESS_STARTS, 0) + 1).apply()
    }

    fun processStarts(context: Context): Int =
        prefs(context).getInt(KEY_PROCESS_STARTS, 0)

    fun noteRevive(context: Context) {
        val p = prefs(context)
        p.edit().putInt(KEY_REVIVES, p.getInt(KEY_REVIVES, 0) + 1).apply()
    }

    fun revives(context: Context): Int = prefs(context).getInt(KEY_REVIVES, 0)

    fun nativeSends(context: Context): Int = prefs(context).getInt(KEY_NATIVE_SENDS, 0)

    fun lastError(context: Context): String? = prefs(context).getString(KEY_LAST_ERROR, null)

    fun setLastError(context: Context, message: String?) {
        prefs(context).edit().putString(KEY_LAST_ERROR, message).apply()
    }

    /** True once the one-time "allow background" system dialog was offered. */
    fun batteryPromptDone(context: Context): Boolean =
        prefs(context).getBoolean(KEY_BATTERY_PROMPT, false)

    fun markBatteryPromptDone(context: Context) {
        prefs(context).edit().putBoolean(KEY_BATTERY_PROMPT, true).apply()
    }

    /**
     * Appends one entry for a signal the NATIVE fallback sent (Dart was dead, so
     * it could not write its own IR Log row). Stored in the shared_preferences
     * file the Flutter plugin uses; the Dart IR Log merges and clears it on the
     * next load, so the log stays complete across a kill.
     */
    fun logNativeSend(
        context: Context,
        label: String,
        protocol: String,
        hex: String,
        frequencyHz: Int,
        patternLength: Int,
        source: String,
    ) {
        try {
            val p = context.applicationContext
                .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            val raw = p.getString(NATIVE_LOG_KEY, null)
            var list = JSONArray()
            if (!raw.isNullOrBlank()) {
                list = try {
                    JSONArray(raw)
                } catch (_: Throwable) {
                    JSONArray()
                }
            }
            while (list.length() >= NATIVE_LOG_LIMIT) {
                list.remove(0)
            }
            list.put(
                JSONObject()
                    .put("at", System.currentTimeMillis())
                    .put("label", label)
                    .put("protocol", protocol)
                    .put("hex", hex)
                    .put("freq", frequencyHz)
                    .put("marks", patternLength)
                    .put("source", source)
            )
            p.edit().putString(NATIVE_LOG_KEY, list.toString()).apply()
            val gp = prefs(context)
            gp.edit().putInt(KEY_NATIVE_SENDS, gp.getInt(KEY_NATIVE_SENDS, 0) + 1).apply()
        } catch (_: Throwable) {
            // Logging must never break the sweep.
        }
    }

    /**
     * Returns the sends the native fallback recorded and clears the buffer, so
     * the Dart IR Log can merge them exactly once (no duplicates when the app is
     * reopened twice).
     */
    fun drainNativeLog(context: Context): String {
        return try {
            val p = context.applicationContext
                .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            val raw = p.getString(NATIVE_LOG_KEY, null)
            if (raw.isNullOrBlank() || raw == "[]") return "[]"
            p.edit().putString(NATIVE_LOG_KEY, "[]").apply()
            raw
        } catch (_: Throwable) {
            "[]"
        }
    }

    fun clearNativeLog(context: Context) {
        try {
            context.applicationContext
                .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                .edit().putString(NATIVE_LOG_KEY, "[]").apply()
        } catch (_: Throwable) {
        }
    }
}
