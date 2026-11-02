package com.mobilecoldwallet.nfc_probe

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import org.json.JSONObject

/**
 * Debug-only automation controller for `run_nfc_probe.py`.
 *
 * Invoked by the runner as:
 *   adb shell content call --uri content://com.mobilecoldwallet.nfc_probe.testcontrol \
 *       --method activate_run --extra role:s:HCE --extra run_id:s:<id> --extra phase:s:phase1
 *
 * The ACK JSON is returned synchronously in the result Bundle (`ack_json`) so the runner reads back
 * the generation/token the App actually adopted instead of trusting its own input.
 *
 * - Declared with `android:permission="android.permission.DUMP"` (framework check at provider acquisition).
 * - `call()` is NOT covered by the framework's read/write permission enforcement, so the provider checks
 *   the real Binder caller itself (debuggable + DUMP + UID 2000/0) via [TestControlGate].
 * - Removed from the release merged manifest (`src/release/AndroidManifest.xml`, `tools:node="remove"`).
 */
class TestControlProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: return Bundle().apply {
            putString("ack_json", JSONObject().put("ack", false).put("reason", "NO_CONTEXT").toString())
        }
        try {
            ProbeSessionState.configureEvidenceDirectory(ctx.filesDir)
        } catch (_: Throwable) {
        }

        // Binder identity of the actual remote caller of this transaction.
        val callingUid = Binder.getCallingUid()
        val callerHoldsDump = ctx.checkCallingPermission(Manifest.permission.DUMP) == PackageManager.PERMISSION_GRANTED
        val isDebuggable = (ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

        val req = TestControlGate.Request(
            method = method,
            role = extras?.getString("role"),
            runId = extras?.getString("run_id"),
            phase = extras?.getString("phase")
        )
        val decision = TestControlGate.decide(req, isDebuggable, callingUid, callerHoldsDump)

        val ack: JSONObject = if (!decision.accepted) {
            ProbeSessionState.recordAndLogEvent(
                eventName = "TEST_CONTROL_REJECTED",
                source = "TEST_CONTROL_PROVIDER",
                payload = JSONObject().apply {
                    put("accepted", false)
                    put("method", method)
                    put("reason", decision.reason)
                    put("calling_uid", callingUid)
                    put("caller_holds_dump", callerHoldsDump)
                }
            )
            TestControlGate.rejection(decision, callingUid, method)
        } else if (method == TestControlGate.METHOD_STATUS) {
            val snap = ProbeSessionState.snapshot()
            JSONObject().apply {
                put("ack", true)
                put("method", method)
                put("run_id", snap.runId)
                put("phase", snap.phase)
                put("role", snap.role.name)
                put("generation", snap.generation)
                put("token", snap.activeToken)
                put("calling_uid", callingUid)
                put("vault_native_loaded", VaultCoreBridge.isAvailable)
                put("wallet_native_loaded", WalletCoreBridge.isAvailable)
                put("vault_armed", VaultApprovalGate.isArmed())
                put("live_activity", MainActivity.liveInstanceSummary())
            }
        } else {
            // Binder identity is not needed while applying the change in-process.
            val token = Binder.clearCallingIdentity()
            try {
                TestControlGate.activate(decision, callingUid) { snap ->
                    MainActivity.applyAuthenticatedControlToLiveInstance(snap)
                }
            } finally {
                Binder.restoreCallingIdentity(token)
            }
        }
        return Bundle().apply { putString("ack_json", ack.toString()) }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
