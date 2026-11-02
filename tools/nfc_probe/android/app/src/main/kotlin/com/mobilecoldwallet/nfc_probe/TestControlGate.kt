package com.mobilecoldwallet.nfc_probe

import org.json.JSONObject

/**
 * Pure authorization + request validation for the debug-only automation controller
 * ([TestControlProvider]). Kept free of Android framework types so the exact production
 * decision logic is exercised by JVM unit tests.
 *
 * Security boundary (all must hold):
 *  1. The build is debuggable (release/offline APK also has the provider removed from the merged manifest).
 *  2. The caller holds `android.permission.DUMP` as reported by the framework for the *calling* Binder identity.
 *  3. The caller's real Binder UID is ADB shell (2000) or root (0).
 *
 * Unlike the previous `TestControlActivity`, the caller UID is taken from the Binder transaction of
 * `ContentProvider.call()`, which the framework fills in and the caller cannot spoof. There is no
 * fallback that assumes UID 2000 when the identity is unknown.
 */
object TestControlGate {
    const val AUTHORITY = "com.mobilecoldwallet.nfc_probe.testcontrol"
    const val METHOD_ACTIVATE_RUN = "activate_run"
    const val METHOD_STATUS = "status"

    const val SHELL_UID = 2000
    const val ROOT_UID = 0

    private val SAFE_ID = Regex("^[A-Za-z0-9._-]{1,96}$")

    data class Request(
        val method: String?,
        val role: String?,
        val runId: String?,
        val phase: String?
    )

    data class Decision(
        val accepted: Boolean,
        val reason: String,
        val role: MainActivity.Role? = null,
        val runId: String? = null,
        val phase: String? = null
    )

    fun isCallerAuthorized(isDebuggableBuild: Boolean, callingUid: Int, callerHoldsDump: Boolean): Boolean {
        if (!isDebuggableBuild) return false
        if (!callerHoldsDump) return false
        return callingUid == SHELL_UID || callingUid == ROOT_UID
    }

    fun parseRoleStrict(roleStr: String?): MainActivity.Role? = when (roleStr) {
        "READER" -> MainActivity.Role.READER
        "HCE" -> MainActivity.Role.HCE
        else -> null
    }

    /**
     * Decides whether a controller request may be applied. Does not mutate session state.
     */
    fun decide(req: Request, isDebuggableBuild: Boolean, callingUid: Int, callerHoldsDump: Boolean): Decision {
        if (!isDebuggableBuild) {
            return Decision(false, "CONTROLLER_DISABLED_NON_DEBUGGABLE_BUILD")
        }
        if (!isCallerAuthorized(isDebuggableBuild, callingUid, callerHoldsDump)) {
            return Decision(false, "UNAUTHORIZED_CALLER_UID_${callingUid}_DUMP_${callerHoldsDump}")
        }
        return when (req.method) {
            METHOD_STATUS -> Decision(true, "STATUS_OK")
            METHOD_ACTIVATE_RUN -> {
                val role = parseRoleStrict(req.role)
                    ?: return Decision(false, "INVALID_ROLE")
                val runId = req.runId
                if (runId == null || !SAFE_ID.matches(runId)) {
                    return Decision(false, "INVALID_RUN_ID")
                }
                val phase = req.phase
                if (phase == null || !SAFE_ID.matches(phase)) {
                    return Decision(false, "INVALID_PHASE")
                }
                Decision(true, "ACTIVATE_OK", role, runId, phase)
            }
            else -> Decision(false, "UNKNOWN_METHOD")
        }
    }

    /**
     * Applies an accepted activate_run decision to the shared session and builds the ACK
     * returned to the runner. `applyToActivity` pushes the new snapshot into the live UI and
     * reports whether a resumed MainActivity actually adopted it.
     */
    fun activate(
        decision: Decision,
        callingUid: Int,
        applyToActivity: (ProbeSessionState.SessionSnapshot) -> JSONObject
    ): JSONObject {
        require(decision.accepted && decision.role != null)
        val snap = ProbeSessionState.activateRun(
            role = decision.role,
            requestedRunId = decision.runId,
            requestedPhase = decision.phase,
            triggerSource = "TEST_CONTROL_PROVIDER_UID_$callingUid"
        )
        val applied = applyToActivity(snap)
        val after = ProbeSessionState.snapshot()
        return JSONObject().apply {
            put("ack", true)
            put("method", METHOD_ACTIVATE_RUN)
            put("run_id", snap.runId)
            put("phase", snap.phase)
            put("role", snap.role.name)
            put("generation", snap.generation)
            put("token", snap.activeToken)
            put("calling_uid", callingUid)
            put("applied_to_activity", applied.optBoolean("applied", false))
            put("activity_resumed", applied.optBoolean("resumed", false))
            put("reader_mode_active", applied.optBoolean("reader_mode_active", false))
            put("vault_armed", VaultApprovalGate.isArmed())
            // The session must not have moved between activation and ACK emission.
            put("session_stable", after.generation == snap.generation && after.activeToken == snap.activeToken)
        }
    }

    fun rejection(decision: Decision, callingUid: Int, method: String?): JSONObject = JSONObject().apply {
        put("ack", false)
        put("method", method ?: "")
        put("reason", decision.reason)
        put("calling_uid", callingUid)
    }
}
