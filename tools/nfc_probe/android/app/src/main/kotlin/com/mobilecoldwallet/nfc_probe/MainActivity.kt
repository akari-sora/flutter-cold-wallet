package com.mobilecoldwallet.nfc_probe

import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity(), NfcAdapter.ReaderCallback {

    enum class Role {
        READER,
        HCE
    }

    /**
     * Abstraction over Android IsoDep to allow both physical NFC Tag IsoDep
     * and direct JVM unit tests (`./gradlew testDebugUnitTest`) to exercise
     * the exact production Reader state machine, token checks, and APDU framing.
     */
    interface IsoDepTransport {
        val maxTransceiveLength: Int
        var timeout: Int
        fun connect()
        fun close()
        fun transceive(commandApdu: ByteArray): ByteArray
    }

    private class AndroidIsoDepTransport(private val isoDep: IsoDep) : IsoDepTransport {
        override val maxTransceiveLength: Int
            get() = isoDep.maxTransceiveLength

        override var timeout: Int
            get() = isoDep.timeout
            set(value) {
                isoDep.timeout = value
            }

        override fun connect() = isoDep.connect()
        override fun close() = isoDep.close()
        override fun transceive(commandApdu: ByteArray): ByteArray = isoDep.transceive(commandApdu)
    }

    private class StaleSessionAbortedException(val abortReason: String) : Exception(abortReason)

    data class Rapdu(val data: ByteArray, val sw: Int) {
        val swHex: String get() = "%04x".format(sw)
        val isSuccess: Boolean get() = sw == 0x9000

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Rapdu) return false
            if (!data.contentEquals(other.data)) return false
            if (sw != other.sw) return false
            return true
        }

        override fun hashCode(): Int {
            var result = data.contentHashCode()
            result = 31 * result + sw
            return result
        }
    }

    enum class ReaderMode {
        PROBE,
        RUST_TX
    }

    companion object {
        private const val CHANNEL_NAME = "com.mobilecoldwallet.nfc_probe/control"
        // Legacy automation action string; MainActivity rejects it (and any role/run_id/phase extras).
        const val ACTION_TEST_SET_ROLE = "com.mobilecoldwallet.nfc_probe.ACTION_TEST_SET_ROLE"

        val AID_BYTES = byteArrayOf(0xF0.toByte(), 0x46, 0x43, 0x57, 0x01)
        val UNKNOWN_AID_BYTES = byteArrayOf(0xF0.toByte(), 0x00, 0x00, 0x00, 0x00)

        const val EXPECTED_VERSION = 0x0100 // 1.0
        const val EXPECTED_MAX_CHUNK = 128

        // Public test vector only (BIP-39 "abandon ... about" account 0, Sepolia EIP-155 legacy transfer).
        const val PUBLIC_TEST_TX_RLP_HEX =
            "ef808504a817c800825208949858effd232b4033e47d90003d41ec34ecaeda9487038d7ea4c68000808401546d718080"
        const val PUBLIC_TEST_CHAIN_ID = 11155111L
        const val PUBLIC_TEST_SIGNER = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

        const val DEFAULT_APPROVAL_TIMEOUT_MS = 120_000L
        const val DEFAULT_STATUS_POLL_INTERVAL_MS = 250L

        @Volatile
        private var liveRef: WeakReference<MainActivity>? = null

        @Volatile
        var liveActivityWaitTimeoutMs: Long = 3_000L

        fun liveInstanceSummary(): JSONObject {
            val act = liveRef?.get() ?: return JSONObject().put("present", false)
            return JSONObject().apply {
                put("present", true)
                put("resumed", act.isActivityResumed)
                put("role", act.currentRole.name)
                put("reader_mode_active", act.isReaderModeActive)
                put("reader_mode", act.readerMode.name)
                put("run_id", act.currentRunId)
                put("generation", act.currentGeneration)
            }
        }

        /**
         * Called by [TestControlProvider] (binder thread) after an authorized activate_run.
         * Waits briefly if cold-start `onCreate`/`onResume` is still in flight on the main thread,
         * then applies the snapshot on the UI thread and reports whether a resumed activity adopted it.
         */
        fun applyAuthenticatedControlToLiveInstance(snap: ProbeSessionState.SessionSnapshot): JSONObject {
            val deadline = System.currentTimeMillis() + liveActivityWaitTimeoutMs
            var act = liveRef?.get()
            while (act == null && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(25)
                } catch (_: InterruptedException) {
                    break
                }
                act = liveRef?.get()
            }
            if (act == null) {
                return JSONObject().put("applied", false).put("reason", "NO_LIVE_ACTIVITY")
            }
            if (act.uiThreadPoster == null) {
                while (!act.isActivityResumed && System.currentTimeMillis() < deadline) {
                    try {
                        Thread.sleep(25)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            val targetAct = act
            val latch = CountDownLatch(1)
            val out = AtomicReference<JSONObject>()
            targetAct.postToMainThread {
                try {
                    out.set(targetAct.applyAuthenticatedControl(snap))
                } finally {
                    latch.countDown()
                }
            }
            if (!latch.await(5, TimeUnit.SECONDS)) {
                return JSONObject().put("applied", false).put("reason", "UI_THREAD_TIMEOUT")
            }
            return out.get() ?: JSONObject().put("applied", false).put("reason", "NO_RESULT")
        }
    }

    private var nfcAdapter: NfcAdapter? = null
    @Volatile var isReaderModeActive = false
        private set
    @Volatile var currentRole: Role = Role.HCE
        private set
    @Volatile var currentGeneration: Long = 1L
        private set
    @Volatile var currentRunId: String = UUID.randomUUID().toString()
        private set
    @Volatile var currentPhase: String = "local_ui"
        private set
    private var methodChannel: MethodChannel? = null

    // Concurrency, single-flight I/O ownership & token isolation (A2)
    private val activeToken = AtomicLong(1L)
    private val activeIsoDep = AtomicReference<IsoDepTransport?>(null)
    private val ioInFlight = AtomicBoolean(false)
    private val ioOwnerSeq = AtomicLong(0L)
    private val activeIoOwnerId = AtomicLong(0L)
    @Volatile var isActivityResumed = false
    private val secureRandom = SecureRandom()

    // Injectable UI thread dispatcher so JVM unit tests can assert UI dispatch deterministically
    var uiThreadPoster: ((Runnable) -> Unit)? = null

    data class PendingWalletTxState(
        val runId: String,
        val generation: Long,
        val sessionId: String,
        val requestId: String,
        val rawRlpHex: String,
        val chainId: Long,
        val expectedAddress: String,
        val payloadSha256Hex: String,
        val signingDigestHex: String,
        var touchCount: Int = 0,
        var requestDeliveredOnTouch1: Boolean = false,
        var sentApduFrames: Int = 0,
        var maxCapduWireLen: Int = 0,
        var maxLc: Int = 0,
        var completed: Boolean = false
    )

    // Cached probe results for UI query
    @Volatile var lastRunSummary: JSONObject? = null
        private set

    // Reader dispatch mode for the active run, pending 2-tap/3-tap tx state, and last NFC tx outcome
    @Volatile var readerMode: ReaderMode = ReaderMode.PROBE
        private set
    @Volatile var activePendingWalletTx: PendingWalletTxState? = null
        private set
    @Volatile var lastTxResult: JSONObject? = null
        private set

    private fun postToMainThread(block: () -> Unit) {
        val customPoster = uiThreadPoster
        if (customPoster != null) {
            customPoster.invoke(Runnable { block() })
            return
        }
        try {
            runOnUiThread { block() }
        } catch (_: Throwable) {
            block()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getNfcStatus" -> {
                    val status = JSONObject().apply {
                        put("adapter_present", nfcAdapter != null)
                        put("nfc_enabled", nfcAdapter?.isEnabled == true)
                        put("reader_active", isReaderModeActive)
                        put("current_role", currentRole.name)
                        put("current_run_id", currentRunId)
                        put("current_phase", currentPhase)
                        put("current_generation", currentGeneration)
                        put("active_token", activeToken.get())
                        put("evidence_dir", ProbeSessionState.getEvidenceDirectory()?.absolutePath ?: "")
                    }
                    result.success(status.toString())
                }
                "setRole" -> {
                    val roleStr = call.argument<String>("role")
                    val phaseStr = call.argument<String>("phase") ?: "local_ui"
                    val parsed = parseRole(roleStr)
                    if (parsed != null) {
                        startNewRoleSession(parsed, requestedRunId = null, requestedPhase = phaseStr, triggerSource = "FLUTTER_UI")
                        result.success(true)
                    } else {
                        result.error("INVALID_ROLE", "Role must be READER or HCE, got: $roleStr", null)
                    }
                }
                "startProbe" -> {
                    val requestedPhase = call.argument<String>("phase") ?: "local_ui_start"
                    startProbeSession(requestedPhase = requestedPhase, triggerSource = "FLUTTER_UI_START")
                    result.success(true)
                }
                "cancelProbe" -> {
                    cancelProbeSession("USER_CANCEL")
                    result.success(true)
                }
                "getLastRunSummary" -> {
                    result.success(lastRunSummary?.toString() ?: "{}")
                }
                "exportPersistentEvidence" -> {
                    val requestedRunId = call.argument<String>("run_id")?.takeIf { it.isNotEmpty() }
                    val exported = buildPersistentEvidenceBundle(requestedRunId)
                    result.success(exported.toString())
                }
                "listPersistedRuns" -> {
                    result.success(ProbeSessionState.listPersistedRuns().toString())
                }
                "resetRunSession" -> {
                    resetRunSessionInternal("RESET_RUN_SESSION")
                    result.success(true)
                }
                "startTxSession" -> {
                    startTxSession(requestedPhase = call.argument<String>("phase") ?: "local_ui_tx", triggerSource = "FLUTTER_UI_TX")
                    result.success(true)
                }
                "getLastTxResult" -> {
                    result.success(lastTxResult?.toString() ?: "{}")
                }
                "getVaultReview" -> {
                    result.success(VaultApprovalGate.currentReviewJson().toString())
                }
                "approvePendingVaultTx" -> {
                    // Local Vault UI is the only caller of approveLocally; the HCE APDU path cannot approve.
                    val handleId = call.argument<String>("handle_id")
                    if (handleId.isNullOrEmpty() || currentRole != Role.HCE) {
                        result.error("NOT_VAULT_OR_NO_HANDLE", "Approval requires HCE Vault mode and the displayed handle_id", null)
                    } else {
                        val approveRes = VaultApprovalGate.approveLocally(
                            handleId = handleId,
                            uiSource = "FLUTTER_VAULT_UI",
                            expectedRequestId = call.argument<String>("request_id")?.takeIf { it.isNotEmpty() },
                            expectedPayloadSha256 = call.argument<String>("payload_sha256")?.takeIf { it.isNotEmpty() },
                            expectedSigningDigestHex = call.argument<String>("signing_digest")?.takeIf { it.isNotEmpty() },
                            expectedChainId = call.argument<Number>("chain_id")?.toLong(),
                            expectedSigner = call.argument<String>("expected_signer")?.takeIf { it.isNotEmpty() },
                            expectedRunId = call.argument<String>("run_id")?.takeIf { it.isNotEmpty() },
                            expectedGeneration = call.argument<Number>("generation")?.toLong(),
                            expectedReviewSeq = call.argument<Number>("review_seq")?.toLong()
                        )
                        result.success(approveRes.toString())
                    }
                }
                "rejectPendingVaultTx" -> {
                    val handleId = call.argument<String>("handle_id")
                    result.success(!handleId.isNullOrEmpty() && VaultApprovalGate.rejectLocally(handleId, "FLUTTER_VAULT_UI"))
                }
                "discardSignedVaultResponse" -> {
                    val handleId = call.argument<String>("handle_id") ?: ""
                    result.success(VaultApprovalGate.discardSignedResponseByUser(handleId, "FLUTTER_VAULT_UI_DISCARD"))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        liveRef = WeakReference(this)
        try {
            val isDebuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
            if (isDebuggable) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(true)
                    setTurnScreenOn(true)
                }
                @Suppress("DEPRECATION")
                window?.addFlags(
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                            android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                            android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                )
            }
        } catch (_: Throwable) {
        }
        super.onCreate(savedInstanceState)
        liveRef = WeakReference(this)
        try {
            ProbeSessionState.configureEvidenceDirectory(filesDir)
        } catch (_: Throwable) {
        }
        nfcAdapter = try {
            NfcAdapter.getDefaultAdapter(this)
        } catch (_: Throwable) {
            null
        }

        syncFromSharedSessionState()
        VaultApprovalGate.reviewListener = { review -> notifyVaultReviewToFlutter(review) }

        logJson("PROBE_APP_STARTED", JSONObject().apply {
            put("device_model", Build.MODEL ?: "JVM")
            put("android_version", Build.VERSION.SDK_INT)
            put("nfc_supported", nfcAdapter != null)
            put("nfc_enabled", nfcAdapter?.isEnabled == true)
            put("initial_run_id", currentRunId)
            put("initial_phase", currentPhase)
            put("initial_generation", currentGeneration)
            put("initial_token", activeToken.get())
        })

        handleIntentRole(intent, "ON_CREATE")
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
        if (currentRole == Role.READER && isReaderModeActive) {
            enableReaderMode()
        }
    }

    override fun onPause() {
        isActivityResumed = false
        invalidateActiveSession("ON_PAUSE", startFreshRunId = false)
        super.onPause()
    }

    override fun onDestroy() {
        isActivityResumed = false
        invalidateActiveSession("ON_DESTROY", startFreshRunId = false)
        disableReaderMode()
        VaultApprovalGate.setArmed(false, "ON_DESTROY")
        if (liveRef?.get() === this) {
            liveRef = null
            VaultApprovalGate.reviewListener = null
        }
        super.onDestroy()
    }

    private fun syncFromSharedSessionState() {
        val snap = ProbeSessionState.snapshot()
        currentRunId = snap.runId
        currentPhase = snap.phase
        currentRole = snap.role
        currentGeneration = snap.generation
        activeToken.set(snap.activeToken)
    }

    fun invalidateActiveSession(reason: String, startFreshRunId: Boolean = false) {
        val snap = ProbeSessionState.invalidate(reason, startFreshRunId = startFreshRunId)
        currentRunId = snap.runId
        currentPhase = snap.phase
        currentGeneration = snap.generation
        activeToken.set(snap.activeToken)
        VaultApprovalGate.cancelPending("SESSION_INVALIDATED_$reason")

        val oldIsoDep = activeIsoDep.getAndSet(null)
        if (oldIsoDep != null) {
            try {
                oldIsoDep.close()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntentRole(intent, "ON_NEW_INTENT")
    }

    /**
     * Applies an already-authorized controller snapshot (see [TestControlProvider] / [TestControlGate]).
     * Refuses if the shared session moved on since the controller activated it.
     */
    fun applyAuthenticatedControl(snap: ProbeSessionState.SessionSnapshot): JSONObject {
        val now = ProbeSessionState.snapshot()
        if (now.generation != snap.generation || now.activeToken != snap.activeToken || now.runId != snap.runId) {
            return JSONObject().put("applied", false).put("reason", "SUPERSEDED_BEFORE_APPLY")
        }
        val oldIsoDep = activeIsoDep.getAndSet(null)
        if (oldIsoDep != null) {
            try {
                oldIsoDep.close()
            } catch (_: Throwable) {
            }
        }
        currentRunId = snap.runId
        currentPhase = snap.phase
        currentRole = snap.role
        currentGeneration = snap.generation
        activeToken.set(snap.activeToken)
        lastRunSummary = null
        lastTxResult = null
        activePendingWalletTx = null
        readerMode = ReaderMode.PROBE
        if (snap.role == Role.READER) enableReaderMode() else disableReaderMode()
        VaultApprovalGate.setArmed(snap.role == Role.HCE, "TEST_CONTROL_PROVIDER")
        logJson("ROLE_CHANGED", JSONObject().apply {
            put("role", currentRole.name)
            put("status", "ACTIVE")
            put("source", "TEST_CONTROL_PROVIDER")
            put("generation", currentGeneration)
            put("run_id", currentRunId)
            put("phase", currentPhase)
            put("token", activeToken.get())
        })
        notifyRoleChangedToFlutter()
        return JSONObject().apply {
            put("applied", true)
            put("resumed", isActivityResumed)
            put("reader_mode_active", isReaderModeActive)
        }
    }

    /**
     * A1 & A3 Security Gate:
     * `MainActivity` is the user-facing offline launcher Activity and NEVER accepts external
     * `role`, `run_id`, or `phase` extras or `ACTION_TEST_SET_ROLE` from any caller.
     * Automation (debug builds only) goes through [TestControlProvider], which authenticates the
     * real Binder caller; there is no intent-based control path.
     */
    fun handleIntentRole(intent: Intent?, source: String): Boolean {
        if (intent == null) return false

        val hasExternalControlExtras = intent.hasExtra("role") ||
                intent.hasExtra("run_id") ||
                intent.hasExtra("phase") ||
                intent.hasExtra("internal_sync") ||
                intent.action == ACTION_TEST_SET_ROLE

        if (hasExternalControlExtras) {
            logJson("EXTERNAL_CONTROL_REJECTED_ON_MAIN_ACTIVITY", JSONObject().apply {
                put("accepted", false)
                put("source", source)
                put("action", intent.action ?: "DEFAULT")
                put("ignored_role", intent.getStringExtra("role") ?: "")
                put("ignored_run_id", intent.getStringExtra("run_id") ?: "")
                put("reason", "MainActivity strictly forbids external role/run_id injection in offline cold wallet mode")
            })
            return false
        }
        return false
    }

    fun parseRole(roleStr: String?): Role? {
        if (roleStr == null) return null
        return when (roleStr.trim().uppercase(Locale.ROOT)) {
            "READER" -> Role.READER
            "HCE" -> Role.HCE
            else -> null
        }
    }

    /**
     * Starts a fresh probe run in READER mode (A2).
     * Even if already in `Role.READER`, always creates a new `run_id`, increments `generation`,
     * and rotates `activeToken` so prior in-flight or completed runs are strictly isolated.
     */
    fun startProbeSession(
        requestedRunId: String? = null,
        requestedPhase: String = "local_ui_start",
        triggerSource: String = "FLUTTER_UI_START"
    ): ProbeSessionState.SessionSnapshot {
        return startNewRoleSession(
            newRole = Role.READER,
            requestedRunId = requestedRunId,
            requestedPhase = requestedPhase,
            triggerSource = triggerSource
        )
    }

    fun cancelProbeSession(reason: String = "USER_CANCEL") {
        val cancelledRunId = currentRunId
        val cancelledPhase = currentPhase
        val cancelledGen = currentGeneration
        activePendingWalletTx = null
        invalidateActiveSession(reason, startFreshRunId = false)
        disableReaderMode()
        val cancelSummary = JSONObject().apply {
            put("event", "PROBE_CANCELLED")
            put("status", "CANCELLED")
            put("reason", reason)
            put("run_id", cancelledRunId)
            put("phase", cancelledPhase)
            put("generation", cancelledGen)
            put("all_passed", false)
        }
        logJson("PROBE_CANCELLED", cancelSummary)
        ProbeSessionState.writePersistentReport(
            role = "READER",
            runId = cancelledRunId,
            phase = cancelledPhase,
            generation = cancelledGen,
            summaryPayload = cancelSummary
        )
    }

    fun resetRunSessionInternal(reason: String = "RESET_RUN_SESSION") {
        activePendingWalletTx = null
        invalidateActiveSession(reason, startFreshRunId = true)
        lastRunSummary = null
        lastTxResult = null
        logJson("RUN_SESSION_RESET", JSONObject().apply {
            put("new_run_id", currentRunId)
            put("new_phase", currentPhase)
            put("new_generation", currentGeneration)
            put("new_token", activeToken.get())
        })
    }

    fun startNewRoleSession(
        newRole: Role,
        requestedRunId: String? = null,
        requestedPhase: String = "local_ui",
        triggerSource: String = "FLUTTER_UI",
        newReaderMode: ReaderMode = ReaderMode.PROBE
    ): ProbeSessionState.SessionSnapshot {
        val oldIsoDep = activeIsoDep.getAndSet(null)
        if (oldIsoDep != null) {
            try {
                oldIsoDep.close()
            } catch (_: Throwable) {
            }
        }

        val snap = ProbeSessionState.activateRun(
            role = newRole,
            requestedRunId = requestedRunId,
            requestedPhase = requestedPhase,
            triggerSource = triggerSource
        )
        currentRunId = snap.runId
        currentPhase = snap.phase
        currentRole = snap.role
        currentGeneration = snap.generation
        activeToken.set(snap.activeToken)
        lastRunSummary = null
        lastTxResult = null
        activePendingWalletTx = null
        readerMode = if (newRole == Role.READER) newReaderMode else ReaderMode.PROBE
        VaultApprovalGate.setArmed(newRole == Role.HCE, triggerSource)

        if (newRole == Role.READER) {
            enableReaderMode()
        } else {
            disableReaderMode()
        }

        logJson("ROLE_CHANGED", JSONObject().apply {
            put("role", newRole.name)
            put("status", "ACTIVE")
            put("source", triggerSource)
            put("generation", currentGeneration)
            put("run_id", currentRunId)
            put("phase", currentPhase)
            put("token", activeToken.get())
            put("reader_mode", readerMode.name)
        })

        notifyRoleChangedToFlutter()
        return snap
    }

    /**
     * Starts a fresh READER run whose next IsoDep tag is used for the NFC transaction flow
     * (request -> Vault local review -> signed response -> watch-only verification).
     */
    fun startTxSession(
        requestedRunId: String? = null,
        requestedPhase: String = "local_ui_tx",
        triggerSource: String = "FLUTTER_UI_TX"
    ): ProbeSessionState.SessionSnapshot {
        return startNewRoleSession(
            newRole = Role.READER,
            requestedRunId = requestedRunId,
            requestedPhase = requestedPhase,
            triggerSource = triggerSource,
            newReaderMode = ReaderMode.RUST_TX
        )
    }

    private fun notifyVaultReviewToFlutter(review: JSONObject) {
        val payload = review.toString()
        postToMainThread {
            methodChannel?.invokeMethod("onVaultReviewChanged", payload)
        }
    }

    private fun notifyRoleChangedToFlutter() {
        val tokenAtSwitch = activeToken.get()
        val roleAtSwitch = currentRole.name
        val runIdAtSwitch = currentRunId
        val phaseAtSwitch = currentPhase
        val genAtSwitch = currentGeneration
        postToMainThread {
            if (activeToken.get() == tokenAtSwitch && currentGeneration == genAtSwitch && currentRunId == runIdAtSwitch) {
                methodChannel?.invokeMethod("onRoleChanged", JSONObject().apply {
                    put("role", roleAtSwitch)
                    put("run_id", runIdAtSwitch)
                    put("phase", phaseAtSwitch)
                    put("generation", genAtSwitch)
                }.toString())
            }
        }
    }

    private fun enableReaderMode() {
        isReaderModeActive = true
        if (nfcAdapter != null) {
            try {
                val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
                nfcAdapter?.enableReaderMode(this, this, flags, null)
            } catch (_: Throwable) {
            }
        }
    }

    private fun disableReaderMode() {
        isReaderModeActive = false
        if (nfcAdapter != null) {
            try {
                nfcAdapter?.disableReaderMode(this)
            } catch (_: Throwable) {
            }
        }
    }

    override fun onTagDiscovered(tag: Tag?) {
        if (tag == null) return
        val techArray = JSONArray()
        for (tech in tag.techList) {
            techArray.put(tech)
        }
        val isoDep = IsoDep.get(tag)
        if (isoDep == null) {
            logJson("TAG_ERROR", JSONObject().apply {
                put("run_id", currentRunId)
                put("phase", currentPhase)
                put("generation", currentGeneration)
                put("token", activeToken.get())
                put("error", "IsoDep not supported on discovered tag")
            })
            return
        }
        val transport = AndroidIsoDepTransport(isoDep)
        if (readerMode == ReaderMode.RUST_TX) {
            executeRustTxReaderSession(transport)
        } else {
            executeReaderSession(transport, techArray)
        }
    }

    private fun isSessionStillActive(
        ownerId: Long,
        callToken: Long,
        expectedRunId: String,
        expectedGeneration: Long
    ): Boolean {
        return activeIoOwnerId.get() == ownerId &&
                activeToken.get() == callToken &&
                currentRunId == expectedRunId &&
                currentGeneration == expectedGeneration &&
                isActivityResumed &&
                currentRole == Role.READER &&
                isReaderModeActive
    }

    @Throws(StaleSessionAbortedException::class, IOException::class)
    private fun guardedTransceive(
        transport: IsoDepTransport,
        apdu: ByteArray,
        stepName: String,
        ownerId: Long,
        callToken: Long,
        expectedRunId: String,
        expectedGeneration: Long
    ): ByteArray {
        if (!isSessionStillActive(ownerId, callToken, expectedRunId, expectedGeneration)) {
            throw StaleSessionAbortedException("Session invalidated before $stepName")
        }
        val rawResp = transport.transceive(apdu)
        if (!isSessionStillActive(ownerId, callToken, expectedRunId, expectedGeneration)) {
            throw StaleSessionAbortedException("Session invalidated after $stepName")
        }
        return rawResp
    }

    /**
     * Executes the Reader probe session with single-flight I/O ownership (`ioInFlight` / `activeIoOwnerId`),
     * `guardedTransceive` around every single APDU exchange, and persistent local report recording
     * on all exit paths (`A2` & `A7`).
     */
    fun executeReaderSession(
        transport: IsoDepTransport,
        techList: JSONArray = JSONArray().put("android.nfc.tech.IsoDep")
    ) {
        val callToken = activeToken.get()
        val tagGeneration = currentGeneration
        val tagRunId = currentRunId
        val tagPhase = currentPhase

        // Check if reader session is active and activity resumed (A2)
        if (!isActivityResumed || currentRole != Role.READER || !isReaderModeActive) {
            logJson("TAG_DISCOVERED_IGNORED", JSONObject().apply {
                put("reason", "Activity not resumed or reader not active")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("active_token", activeToken.get())
            })
            return
        }

        // Single-flight I/O lock (A2): prevent concurrent tag callbacks from clobbering activeIsoDep
        if (!ioInFlight.compareAndSet(false, true)) {
            logJson("TAG_CALLBACK_REJECTED_SINGLE_FLIGHT_BUSY", JSONObject().apply {
                put("reason", "Another IsoDep session is currently in flight")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("active_owner_id", activeIoOwnerId.get())
            })
            try {
                transport.close()
            } catch (_: Throwable) {
            }
            return
        }

        val myOwnerId = ioOwnerSeq.incrementAndGet()
        activeIoOwnerId.set(myOwnerId)
        activeIsoDep.set(transport)
        val tagStartTime = ProbeSessionState.elapsedRealtimeSafe()

        try {
            logJson("TAG_DISCOVERED", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("io_owner_id", myOwnerId)
                put("tech_list", techList)
            })

            if (!isSessionStillActive(myOwnerId, callToken, tagRunId, tagGeneration)) {
                throw StaleSessionAbortedException("Invalidated before IsoDep.connect")
            }

            transport.connect()
            transport.timeout = 5000 // 5 seconds bounded timeout
            val maxTransceive = transport.maxTransceiveLength

            logJson("ISODEP_CONNECTED", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("io_owner_id", myOwnerId)
                put("maxTransceiveLength", maxTransceive)
            })

            // 1. SELECT AID (F046435701)
            val selectApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + AID_BYTES + byteArrayOf(0x00)
            val rawSelectResp = guardedTransceive(
                transport, selectApdu, "SELECT_AID", myOwnerId, callToken, tagRunId, tagGeneration
            )

            val selectRapdu = parseRapdu(rawSelectResp)
            val selectPassed: Boolean
            if (selectRapdu != null && selectRapdu.isSuccess && selectRapdu.data.size == 4) {
                val versionMajor = selectRapdu.data[0].toInt() and 0xFF
                val versionMinor = selectRapdu.data[1].toInt() and 0xFF
                val version = (versionMajor shl 8) or versionMinor

                val maxChunkHi = selectRapdu.data[2].toInt() and 0xFF
                val maxChunkLo = selectRapdu.data[3].toInt() and 0xFF
                val maxChunk = (maxChunkHi shl 8) or maxChunkLo

                val versionOk = (version == EXPECTED_VERSION)
                val maxChunkOk = (maxChunk == EXPECTED_MAX_CHUNK)
                selectPassed = versionOk && maxChunkOk

                logJson("SELECT_AID_RESULT", JSONObject().apply {
                    put("run_id", tagRunId)
                    put("phase", tagPhase)
                    put("generation", tagGeneration)
                    put("token", callToken)
                    put("sw", selectRapdu.swHex)
                    put("version_major", versionMajor)
                    put("version_minor", versionMinor)
                    put("version_ok", versionOk)
                    put("max_chunk", maxChunk)
                    put("max_chunk_ok", maxChunkOk)
                    put("pass", selectPassed)
                })
            } else {
                selectPassed = false
                logJson("SELECT_AID_FAILED", JSONObject().apply {
                    put("run_id", tagRunId)
                    put("phase", tagPhase)
                    put("generation", tagGeneration)
                    put("token", callToken)
                    put("sw", selectRapdu?.swHex ?: "NO_RESPONSE")
                    put("data_len", selectRapdu?.data?.size ?: 0)
                    put("pass", false)
                })
            }

            if (!selectPassed) {
                publishTerminalOutcome(
                    myOwnerId = myOwnerId,
                    callToken = callToken,
                    tagRunId = tagRunId,
                    tagPhase = tagPhase,
                    tagGeneration = tagGeneration,
                    summaryObj = JSONObject().apply {
                        put("event", "PROBE_RUN_COMPLETE")
                        put("status", "FAILED_SELECT_AID")
                        put("run_id", tagRunId)
                        put("phase", tagPhase)
                        put("generation", tagGeneration)
                        put("token", callToken)
                        put("select_passed", false)
                        put("all_passed", false)
                    }
                )
                return
            }

            // 2. 32B CSPRNG Challenge Fixture
            val fixture32 = ByteArray(32).apply { secureRandom.nextBytes(this) }
            val sha32Local = computeSha256(fixture32)
            val t0 = ProbeSessionState.elapsedRealtimeSafe()

            val chunk32Apdu = byteArrayOf(0x80.toByte(), 0x10, 0x00, 0x00, 32) + fixture32 + byteArrayOf(0x00)
            val rawChunk32Resp = guardedTransceive(
                transport, chunk32Apdu, "TEST_32B_WRITE", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val chunk32Rapdu = parseRapdu(rawChunk32Resp)
            val rtt32 = (ProbeSessionState.elapsedRealtimeSafe() - t0).coerceAtLeast(0L)

            val chunk32EchoOk = chunk32Rapdu != null &&
                    chunk32Rapdu.isSuccess &&
                    chunk32Rapdu.data.size == 32 &&
                    chunk32Rapdu.data.contentEquals(fixture32)

            val digestApdu = byteArrayOf(0x80.toByte(), 0x20, 0x00, 0x00, 0x00)
            val rawDigest32Resp = guardedTransceive(
                transport, digestApdu, "TEST_32B_DIGEST", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val digest32Rapdu = parseRapdu(rawDigest32Resp)
            val digest32Ok = digest32Rapdu != null &&
                    digest32Rapdu.isSuccess &&
                    digest32Rapdu.data.size == 32 &&
                    digest32Rapdu.data.contentEquals(computeSha256Bytes(fixture32))

            val test32Passed = chunk32EchoOk && digest32Ok
            logJson("TEST_32B", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("bytes", 32)
                put("chunks", 1)
                put("chunk_sw", chunk32Rapdu?.swHex ?: "NONE")
                put("chunk_echo_ok", chunk32EchoOk)
                put("digest_sw", digest32Rapdu?.swHex ?: "NONE")
                put("digest_match", digest32Ok)
                put("sha256", sha32Local)
                put("rtt_ms", rtt32)
                put("pass", test32Passed)
            })

            // 3. Transceive 512B chunked test (4 x 128B, each echo strictly verified)
            val fixture512 = ByteArray(512).apply { secureRandom.nextBytes(this) }
            val sha512Local = computeSha256(fixture512)
            val t1 = ProbeSessionState.elapsedRealtimeSafe()
            var chunk512EchoesOk = true

            for (i in 0 until 4) {
                val offset = i * 128
                val chunk = fixture512.copyOfRange(offset, offset + 128)
                val apdu = byteArrayOf(0x80.toByte(), 0x10, 0x00, 0x00, 128.toByte()) + chunk + byteArrayOf(0x00)
                val rawResp = guardedTransceive(
                    transport, apdu, "TEST_512B_CHUNK_$i", myOwnerId, callToken, tagRunId, tagGeneration
                )
                val rapdu = parseRapdu(rawResp)
                if (rapdu == null || !rapdu.isSuccess || rapdu.data.size != 128 || !rapdu.data.contentEquals(chunk)) {
                    chunk512EchoesOk = false
                    break
                }
            }
            val rtt512 = (ProbeSessionState.elapsedRealtimeSafe() - t1).coerceAtLeast(0L)

            val rawDigest512Resp = guardedTransceive(
                transport, digestApdu, "TEST_512B_DIGEST", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val digest512Rapdu = parseRapdu(rawDigest512Resp)
            val digest512Ok = digest512Rapdu != null &&
                    digest512Rapdu.isSuccess &&
                    digest512Rapdu.data.size == 32 &&
                    digest512Rapdu.data.contentEquals(computeSha256Bytes(fixture512))

            val test512Passed = chunk512EchoesOk && digest512Ok
            logJson("TEST_512B", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("bytes", 512)
                put("chunks", 4)
                put("chunk_echoes_ok", chunk512EchoesOk)
                put("digest_sw", digest512Rapdu?.swHex ?: "NONE")
                put("digest_match", digest512Ok)
                put("sha256", sha512Local)
                put("rtt_ms", rtt512)
                put("pass", test512Passed)
            })

            // 4. Transceive 4096B (4KiB) chunked test (32 x 128B, each echo strictly verified)
            val fixture4k = ByteArray(4096).apply { secureRandom.nextBytes(this) }
            val sha4kLocal = computeSha256(fixture4k)
            val t2 = ProbeSessionState.elapsedRealtimeSafe()
            var chunk4kEchoesOk = true

            for (i in 0 until 32) {
                val offset = i * 128
                val chunk = fixture4k.copyOfRange(offset, offset + 128)
                val apdu = byteArrayOf(0x80.toByte(), 0x10, 0x00, 0x00, 128.toByte()) + chunk + byteArrayOf(0x00)
                val rawResp = guardedTransceive(
                    transport, apdu, "TEST_4KIB_CHUNK_$i", myOwnerId, callToken, tagRunId, tagGeneration
                )
                val rapdu = parseRapdu(rawResp)
                if (rapdu == null || !rapdu.isSuccess || rapdu.data.size != 128 || !rapdu.data.contentEquals(chunk)) {
                    chunk4kEchoesOk = false
                    break
                }
            }
            val rtt4k = (ProbeSessionState.elapsedRealtimeSafe() - t2).coerceAtLeast(0L)

            val rawDigest4kResp = guardedTransceive(
                transport, digestApdu, "TEST_4KIB_DIGEST", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val digest4kRapdu = parseRapdu(rawDigest4kResp)
            val digest4kOk = digest4kRapdu != null &&
                    digest4kRapdu.isSuccess &&
                    digest4kRapdu.data.size == 32 &&
                    digest4kRapdu.data.contentEquals(computeSha256Bytes(fixture4k))

            val test4kPassed = chunk4kEchoesOk && digest4kOk
            logJson("TEST_4KIB", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("bytes", 4096)
                put("chunks", 32)
                put("chunk_echoes_ok", chunk4kEchoesOk)
                put("digest_sw", digest4kRapdu?.swHex ?: "NONE")
                put("digest_match", digest4kOk)
                put("sha256", sha4kLocal)
                put("rtt_ms", rtt4k)
                put("pass", test4kPassed)
            })

            // 5. Negative Test A: Routing negative - SELECT UNKNOWN AID (Expect 6A82)
            val unknownApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + UNKNOWN_AID_BYTES + byteArrayOf(0x00)
            val rawUnknownResp = guardedTransceive(
                transport, unknownApdu, "NEG_UNKNOWN_AID", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val unknownRapdu = parseRapdu(rawUnknownResp)
            val negRoutingPassed = (unknownRapdu?.sw == 0x6A82)
            logJson("TEST_NEGATIVE_ROUTING_UNKNOWN_AID", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("expected_sw", "6a82")
                put("actual_sw", unknownRapdu?.swHex ?: "TRANSMIT_EXCEPTION")
                put("pass", negRoutingPassed)
            })

            // Re-select our AID to run service-parser negative tests on active session
            val reselectResp = guardedTransceive(
                transport, selectApdu, "RESELECT_AID", myOwnerId, callToken, tagRunId, tagGeneration
            )
            val reselectRapdu = parseRapdu(reselectResp)
            val reselected = reselectRapdu != null && reselectRapdu.isSuccess

            // 6. Negative Test B: Service-parser negative - Invalid INS (CLA=80, INS=99 -> 6D00)
            val invalidInsApdu = byteArrayOf(0x80.toByte(), 0x99.toByte(), 0x00, 0x00, 0x00)
            val rawInsResp = if (reselected) {
                guardedTransceive(transport, invalidInsApdu, "NEG_INVALID_INS", myOwnerId, callToken, tagRunId, tagGeneration)
            } else null
            val insRapdu = parseRapdu(rawInsResp)
            val negInsPassed = (insRapdu?.sw == 0x6D00)
            logJson("TEST_NEGATIVE_SERVICE_INVALID_INS", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("expected_sw", "6d00")
                put("actual_sw", insRapdu?.swHex ?: "NONE")
                put("pass", negInsPassed)
            })

            // 7. Negative Test C: Service-parser negative - Invalid P1 (CLA=80, INS=10, P1=01 -> 6A86)
            val invalidP1Apdu = byteArrayOf(0x80.toByte(), 0x10, 0x01, 0x00, 0x04, 0x01, 0x02, 0x03, 0x04, 0x00)
            val rawP1Resp = if (reselected) {
                guardedTransceive(transport, invalidP1Apdu, "NEG_INVALID_P1", myOwnerId, callToken, tagRunId, tagGeneration)
            } else null
            val p1Rapdu = parseRapdu(rawP1Resp)
            val negP1Passed = (p1Rapdu?.sw == 0x6A86)
            logJson("TEST_NEGATIVE_SERVICE_INVALID_P1", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("expected_sw", "6a86")
                put("actual_sw", p1Rapdu?.swHex ?: "NONE")
                put("pass", negP1Passed)
            })

            // 8. Negative Test D: Service-parser negative - Oversized chunk Lc=129 (>128 -> 6700)
            val oversizedChunk = ByteArray(129) { 0x55.toByte() }
            val oversizedApdu = byteArrayOf(0x80.toByte(), 0x10, 0x00, 0x00, 129.toByte()) + oversizedChunk + byteArrayOf(0x00)
            val rawOversizedResp = if (reselected) {
                guardedTransceive(transport, oversizedApdu, "NEG_OVERSIZED_CHUNK", myOwnerId, callToken, tagRunId, tagGeneration)
            } else null
            val oversizedRapdu = parseRapdu(rawOversizedResp)
            val negOversizedPassed = (oversizedRapdu?.sw == 0x6700)
            logJson("TEST_NEGATIVE_SERVICE_OVERSIZED_CHUNK", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("expected_sw", "6700")
                put("actual_sw", oversizedRapdu?.swHex ?: "NONE")
                put("pass", negOversizedPassed)
            })

            val allPassed = selectPassed &&
                    test32Passed &&
                    test512Passed &&
                    test4kPassed &&
                    negRoutingPassed &&
                    negInsPassed &&
                    negP1Passed &&
                    negOversizedPassed

            val totalDuration = (ProbeSessionState.elapsedRealtimeSafe() - tagStartTime).coerceAtLeast(0L)

            val summaryObj = JSONObject().apply {
                put("event", "PROBE_RUN_COMPLETE")
                put("status", if (allPassed) "PASSED" else "FAILED")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("total_duration_ms", totalDuration)
                put("select_passed", selectPassed)
                put("test_32b_passed", test32Passed)
                put("test_512b_passed", test512Passed)
                put("test_4kib_passed", test4kPassed)
                put("neg_routing_passed", negRoutingPassed)
                put("neg_ins_passed", negInsPassed)
                put("neg_p1_passed", negP1Passed)
                put("neg_oversized_passed", negOversizedPassed)
                put("all_passed", allPassed)
            }

            publishTerminalOutcome(
                myOwnerId = myOwnerId,
                callToken = callToken,
                tagRunId = tagRunId,
                tagPhase = tagPhase,
                tagGeneration = tagGeneration,
                summaryObj = summaryObj
            )
        } catch (aborted: StaleSessionAbortedException) {
            val abortObj = JSONObject().apply {
                put("event", "STALE_SESSION_ABORTED")
                put("status", "ABORTED_STALE")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("call_token", callToken)
                put("current_token", activeToken.get())
                put("reason", aborted.abortReason)
                put("all_passed", false)
            }
            logJson("STALE_SESSION_ABORTED", abortObj)
            ProbeSessionState.writePersistentReport(
                role = "READER",
                runId = tagRunId,
                phase = tagPhase,
                generation = tagGeneration,
                summaryPayload = abortObj
            )
        } catch (e: Exception) {
            val errObj = JSONObject().apply {
                put("event", "ISODEP_EXCEPTION")
                put("status", "FAILED_EXCEPTION")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("message", e.message ?: e.javaClass.simpleName)
                put("all_passed", false)
            }
            logJson("ISODEP_EXCEPTION", errObj)
            publishTerminalOutcome(
                myOwnerId = myOwnerId,
                callToken = callToken,
                tagRunId = tagRunId,
                tagPhase = tagPhase,
                tagGeneration = tagGeneration,
                summaryObj = errObj
            )
        } finally {
            try {
                transport.close()
            } catch (_: Throwable) {
            }
            activeIsoDep.compareAndSet(transport, null)
            activeIoOwnerId.compareAndSet(myOwnerId, 0L)
            ioInFlight.set(false)
        }
    }

    /**
     * Product Reader path for the NFC transaction flow (dispatched from [onTagDiscovered] when the
     * run was started with [startTxSession]).
     *
     * Supports genuine Two-Tap and Three-Tap physical NFC interactions:
     *  - Touch 1: Registers `PendingWalletRequest`, sends `SELECT AID` + `INS=0x40` frames, confirms
     *    receipt (`STATE_PENDING`), and disconnects cleanly (`status = "AWAITING_VAULT_APPROVAL_TOUCH_2"`,
     *    `touch_count = 1`, `request_delivered = true`) when `twoTapDisconnectOnPending` is true
     *    (default when `approvalTimeoutMs <= 0L`) or if RF link loss occurs during polling.
     *  - Touch 2: Reconnects with a second [IsoDepTransport], resets only the transport assembler
     *    (`nativeResetTransportAssembler`) WITHOUT calling `nativeInit`, creating a new `requestId`,
     *    or re-sending `INS=0x40`; binds & verifies peer/session/request/digest/account context via
     *    `INS=0x41 P1=0x00`; fetches cached signed response frames (`INS=0x50`); and verifies via
     *    `WalletCoreBridge.nativeVerifyNfcResponse`.
     *  - Touch 3: If Touch 2 is interrupted mid-fetch of `INS=0x50`, retains `activePendingWalletTx`
     *    (`status = "TOUCH_2_INTERRUPTED_RETRY_READY"`), resets only the transport assembler, and
     *    completes response collection on Touch 3 without re-signing.
     */
    fun executeRustTxReaderSession(
        transport: IsoDepTransport,
        approvalTimeoutMs: Long = 0L,
        pollIntervalMs: Long = DEFAULT_STATUS_POLL_INTERVAL_MS,
        twoTapDisconnectOnPending: Boolean = (approvalTimeoutMs <= 0L),
        peerContextOverride: JSONObject? = null,
        rawRlpHex: String = PUBLIC_TEST_TX_RLP_HEX,
        chainId: Long = PUBLIC_TEST_CHAIN_ID,
        expectedAddress: String = PUBLIC_TEST_SIGNER,
        sleeper: (Long) -> Unit = { Thread.sleep(it) }
    ): JSONObject? {
        val callToken = activeToken.get()
        val tagGeneration = currentGeneration
        val tagRunId = currentRunId
        val tagPhase = currentPhase

        if (!isActivityResumed || currentRole != Role.READER || !isReaderModeActive || readerMode != ReaderMode.RUST_TX) {
            logJson("TX_TAG_IGNORED", JSONObject().apply {
                put("reason", "Activity not resumed, reader not active, or not in RUST_TX mode")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
            })
            return null
        }
        if (!ioInFlight.compareAndSet(false, true)) {
            logJson("TAG_CALLBACK_REJECTED_SINGLE_FLIGHT_BUSY", JSONObject().apply {
                put("reason", "Another IsoDep session is currently in flight")
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("active_owner_id", activeIoOwnerId.get())
            })
            try {
                transport.close()
            } catch (_: Throwable) {
            }
            return null
        }

        val myOwnerId = ioOwnerSeq.incrementAndGet()
        activeIoOwnerId.set(myOwnerId)
        activeIsoDep.set(transport)

        val existing = activePendingWalletTx?.takeIf {
            it.runId == tagRunId &&
                    it.generation == tagGeneration &&
                    it.requestDeliveredOnTouch1 &&
                    !it.completed
        }

        val isFollowUpTouch = existing != null
        val sessionId = existing?.sessionId ?: "nfc-$tagRunId-$tagGeneration"
        val requestId = existing?.requestId ?: ("req-" + UUID.randomUUID().toString())
        val touchNumber = if (existing != null) existing.touchCount + 1 else 1

        val result: JSONObject = try {
            logJson("TX_TAG_DISCOVERED", JSONObject().apply {
                put("run_id", tagRunId)
                put("phase", tagPhase)
                put("generation", tagGeneration)
                put("token", callToken)
                put("io_owner_id", myOwnerId)
                put("session_id", sessionId)
                put("request_id", requestId)
                put("touch_number", touchNumber)
                put("touch_phase", if (isFollowUpTouch) "TOUCH_${touchNumber}_COLLECT_RESPONSE" else "TOUCH_1_SEND_REQUEST")
            })
            if (existing != null) {
                existing.touchCount = touchNumber
                executeRustTransactionTouch2Collect(
                    transport = transport,
                    pendingState = existing,
                    approvalTimeoutMs = approvalTimeoutMs,
                    pollIntervalMs = pollIntervalMs,
                    peerContextOverride = peerContextOverride,
                    transceiver = { apdu, step ->
                        guardedTransceive(transport, apdu, step, myOwnerId, callToken, tagRunId, tagGeneration)
                    },
                    sleeper = sleeper
                )
            } else {
                executeRustTransactionSession(
                    transport = transport,
                    sessionId = sessionId,
                    requestId = requestId,
                    rawRlpHex = rawRlpHex,
                    chainId = chainId,
                    expectedAddress = expectedAddress,
                    approvalTimeoutMs = approvalTimeoutMs,
                    pollIntervalMs = pollIntervalMs,
                    twoTapDisconnectOnPending = twoTapDisconnectOnPending,
                    runIdForState = tagRunId,
                    generationForState = tagGeneration,
                    transceiver = { apdu, step ->
                        guardedTransceive(transport, apdu, step, myOwnerId, callToken, tagRunId, tagGeneration)
                    },
                    sleeper = sleeper
                )
            }
        } catch (aborted: StaleSessionAbortedException) {
            JSONObject().put("verified", false).put("status", "ABORTED_STALE").put("error", aborted.abortReason)
        } catch (e: Exception) {
            JSONObject().put("verified", false).put("status", "FAILED_EXCEPTION")
                .put("error", e.message ?: e.javaClass.simpleName)
        } finally {
            try {
                transport.close()
            } catch (_: Throwable) {
            }
            activeIsoDep.compareAndSet(transport, null)
            activeIoOwnerId.compareAndSet(myOwnerId, 0L)
            ioInFlight.set(false)
        }

        val statusStr = result.optString("status", if (result.optBoolean("verified")) "VERIFIED" else "FAILED")
        val isIntermediateTouch = statusStr in setOf(
            "AWAITING_VAULT_APPROVAL_TOUCH_2",
            "STILL_PENDING_LOCAL_REVIEW",
            "TOUCH_2_INTERRUPTED_RETRY_READY"
        )
        val eventName = if (isIntermediateTouch) "TX_TOUCH_INTERMEDIATE" else "RUST_TX_COMPLETE"

        result.put("event", eventName)
        result.put("run_id", tagRunId)
        result.put("phase", tagPhase)
        result.put("generation", tagGeneration)
        result.put("token", callToken)
        result.put("session_id", sessionId)
        result.put("request_id", requestId)
        result.put("transport", "NFC_ISODEP_HCE")
        if (!result.has("touch_count")) result.put("touch_count", touchNumber)
        result.put("status", statusStr)

        val writeRes = ProbeSessionState.writePersistentReportDetailed(
            role = "READER",
            runId = tagRunId,
            phase = tagPhase,
            generation = tagGeneration,
            summaryPayload = result
        )
        if (!writeRes.ok) {
            result.put("evidence_status", "EVIDENCE_WRITE_FAILED")
            result.put("evidence_error", writeRes.errorMessage ?: "Failed writing persistent report")
        } else {
            result.put("evidence_status", "OK")
            result.put("evidence_file_path", writeRes.file?.absolutePath ?: "")
        }
        logJson(eventName, result)
        val stillActive = activeToken.get() == callToken && currentRunId == tagRunId && currentGeneration == tagGeneration
        if (stillActive) {
            lastTxResult = result
            val payload = result.toString()
            postToMainThread {
                if (activeToken.get() == callToken && currentRunId == tagRunId && currentGeneration == tagGeneration) {
                    methodChannel?.invokeMethod("onTxComplete", payload)
                }
            }
        }
        return result
    }

    private fun sendChunkedPeerContextPoll(
        bindingJson: JSONObject,
        xfer: (ByteArray, String) -> ByteArray
    ): Rapdu? {
        val ctxBytes = bindingJson.toString().toByteArray(Charsets.UTF_8)
        val sliceSize = 112
        val totalSlices = (ctxBytes.size + sliceSize - 1) / sliceSize
        for (idx in 0 until totalSlices) {
            val start = idx * sliceSize
            val end = minOf(ctxBytes.size, start + sliceSize)
            val slice = ctxBytes.copyOfRange(start, end)
            val isLast = (idx == totalSlices - 1)
            val p2 = if (isLast) 0x00.toByte() else (idx + 1).toByte()
            val apdu = byteArrayOf(0x80.toByte(), 0x41, 0x00, p2, slice.size.toByte()) + slice + byteArrayOf(0x00)
            val rapdu = parseRapdu(xfer(apdu, if (isLast) "TX_STATUS_POLL_CONTEXT" else "TX_STATUS_BIND_${idx + 1}"))
            if (!isLast) {
                if (rapdu == null || !rapdu.isSuccess) return rapdu
            } else {
                return rapdu
            }
        }
        return null
    }

    /**
     * Touch 2 / Touch 3 response collection over a fresh [IsoDepTransport]:
     * - Does NOT call `WalletCoreBridge.nativeInit()`, does NOT create a new `requestId`, and does
     *   NOT re-send `INS=0x40` request frames.
     * - Calls `WalletCoreBridge.nativeResetTransportAssembler(sessionId)` to clear any partial
     *   response frames from an interrupted Touch 2 while keeping `PendingWalletRequest` intact.
     * - Sends `SELECT AID`, binds & verifies peer/session/request/digest/account context via
     *   `INS=0x41 P1=0x00`, fetches `INS=0x50` response frames, and verifies against the retained
     *   `PendingWalletRequest`.
     */
    fun executeRustTransactionTouch2Collect(
        transport: IsoDepTransport,
        pendingState: PendingWalletTxState,
        approvalTimeoutMs: Long = 0L,
        pollIntervalMs: Long = DEFAULT_STATUS_POLL_INTERVAL_MS,
        peerContextOverride: JSONObject? = null,
        transceiver: ((ByteArray, String) -> ByteArray)? = null,
        sleeper: (Long) -> Unit = { Thread.sleep(it) }
    ): JSONObject {
        if (!WalletCoreBridge.isAvailable) {
            return JSONObject().put("verified", false).put("status", "WALLET_NATIVE_UNAVAILABLE")
        }
        WalletCoreBridge.nativeResetTransportAssembler(pendingState.sessionId)

        fun xfer(apdu: ByteArray, step: String): ByteArray =
            transceiver?.invoke(apdu, step) ?: transport.transceive(apdu)

        fun baseTouch2Result(): JSONObject = JSONObject().apply {
            put("touch_count", pendingState.touchCount)
            put("sent_apdu_frames", pendingState.sentApduFrames)
            put("max_capdu_wire_len", pendingState.maxCapduWireLen)
            put("max_lc", pendingState.maxLc)
            put("signing_digest", pendingState.signingDigestHex)
            put("payload_sha256", pendingState.payloadSha256Hex)
        }

        transport.connect()
        transport.timeout = 5000
        try {
            val selectApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + AID_BYTES + byteArrayOf(0x00)
            val selectRapdu = parseRapdu(xfer(selectApdu, "TX_TOUCH2_SELECT_AID"))
            if (selectRapdu == null || !selectRapdu.isSuccess) {
                return baseTouch2Result().put("verified", false).put("status", "SELECT_FAILED")
                    .put("error", "Touch ${pendingState.touchCount} SELECT AID failed SW=${selectRapdu?.swHex}")
            }

            val bindingJson = peerContextOverride ?: JSONObject().apply {
                put("session_id", pendingState.sessionId)
                put("request_id", pendingState.requestId)
                put("payload_sha256", pendingState.payloadSha256Hex)
                put("signing_digest", pendingState.signingDigestHex)
                put("chain_id", pendingState.chainId)
                put("expected_signer", pendingState.expectedAddress)
            }

            var st = sendChunkedPeerContextPoll(bindingJson, ::xfer)
            var polls = 1
            if (st == null) {
                return baseTouch2Result().put("verified", false).put("status", "STATUS_POLL_FAILED")
            }
            if (st.sw == 0x6982) {
                return baseTouch2Result().put("verified", false)
                    .put("status", "PEER_CONTEXT_MISMATCH_REJECTED")
                    .put("error_sw", st.swHex)
                    .put("status_polls", polls)
            }
            if (!st.isSuccess || st.data.size != 3) {
                return baseTouch2Result().put("verified", false)
                    .put("status", "STATUS_POLL_FAILED")
                    .put("error", "Touch ${pendingState.touchCount} status poll SW=${st.swHex} len=${st.data.size}")
                    .put("status_polls", polls)
            }

            val statusApdu = byteArrayOf(0x80.toByte(), 0x41, 0x00, 0x00, 0x00)
            val deadline = ProbeSessionState.elapsedRealtimeSafe() + approvalTimeoutMs
            var finalState = st.data[0].toInt() and 0xFF
            var totalRespFrames = ((st.data[1].toInt() and 0xFF) shl 8) or (st.data[2].toInt() and 0xFF)

            while (finalState == VaultApprovalGate.STATE_PENDING) {
                if (approvalTimeoutMs <= 0L || ProbeSessionState.elapsedRealtimeSafe() >= deadline) {
                    return baseTouch2Result().put("verified", false)
                        .put("status", "STILL_PENDING_LOCAL_REVIEW")
                        .put("status_polls", polls)
                }
                sleeper(pollIntervalMs)
                val nextSt = parseRapdu(xfer(statusApdu, "TX_STATUS_POLL"))
                polls++
                if (nextSt == null || !nextSt.isSuccess || nextSt.data.size != 3) {
                    return baseTouch2Result().put("verified", false).put("status", "STATUS_POLL_FAILED")
                        .put("status_polls", polls)
                }
                finalState = nextSt.data[0].toInt() and 0xFF
                totalRespFrames = ((nextSt.data[1].toInt() and 0xFF) shl 8) or (nextSt.data[2].toInt() and 0xFF)
            }

            when (finalState) {
                VaultApprovalGate.STATE_APPROVED -> Unit
                VaultApprovalGate.STATE_REJECTED -> {
                    pendingState.completed = true
                    return baseTouch2Result().put("verified", false)
                        .put("status", "REJECTED_BY_VAULT_USER").put("status_polls", polls)
                }
                VaultApprovalGate.STATE_CANCELLED -> {
                    pendingState.completed = true
                    return baseTouch2Result().put("verified", false)
                        .put("status", "VAULT_CANCELLED").put("status_polls", polls)
                }
                VaultApprovalGate.STATE_SIGNED_DISCARDED -> {
                    pendingState.completed = true
                    return baseTouch2Result().put("verified", false)
                        .put("status", "SIGNED_DISCARDED_BY_USER").put("status_polls", polls)
                }
                VaultApprovalGate.STATE_OUTCOME_UNKNOWN -> {
                    pendingState.completed = true
                    return baseTouch2Result().put("verified", false)
                        .put("status", "EXTERNAL_SIGN_OUTCOME_UNKNOWN").put("status_polls", polls)
                }
                else -> {
                    return baseTouch2Result().put("verified", false)
                        .put("status", "VAULT_STATE_$finalState").put("status_polls", polls)
                }
            }

            if (totalRespFrames <= 0 || totalRespFrames > 255) {
                return baseTouch2Result().put("verified", false).put("status", "INVALID_RESPONSE_FRAME_COUNT")
                    .put("received_apdu_frames", totalRespFrames)
            }

            var reassembledResponseHex: String? = null
            var fetchedFramesCount = 0
            try {
                for (idx in 0 until totalRespFrames) {
                    val fetchApdu = byteArrayOf(0x80.toByte(), 0x50, idx.toByte(), 0x00, 0x00)
                    val fetchRapdu = parseRapdu(xfer(fetchApdu, "TX_RESPONSE_FRAME_$idx"))
                    if (fetchRapdu == null || !fetchRapdu.isSuccess || fetchRapdu.data.size < 6) {
                        WalletCoreBridge.nativeResetTransportAssembler(pendingState.sessionId)
                        return baseTouch2Result().put("verified", false)
                            .put("status", "TOUCH_2_INTERRUPTED_RETRY_READY")
                            .put("fetched_frames_before_interrupt", fetchedFramesCount)
                            .put("error", "Failed fetching response frame $idx SW=${fetchRapdu?.swHex}")
                    }
                    fetchedFramesCount++
                    val respFrameBytes = fetchRapdu.data
                    val respLc = respFrameBytes[4].toInt() and 0xFF
                    if (respLc > 128 || respFrameBytes.size > 134 || respFrameBytes.size != 6 + respLc) {
                        return baseTouch2Result().put("verified", false).put("status", "RESPONSE_FRAME_BOUND_VIOLATION")
                            .put("error", "Response APDU frame $idx len=${respFrameBytes.size} lc=$respLc")
                    }
                    val respFrameHex = respFrameBytes.joinToString("") { "%02x".format(it) }
                    val procJson = JSONObject(WalletCoreBridge.nativeProcessApduFrame(respFrameHex))
                    if (procJson.has("error")) {
                        WalletCoreBridge.nativeResetTransportAssembler(pendingState.sessionId)
                        return baseTouch2Result().put("verified", false)
                            .put("status", "RESPONSE_REASSEMBLY_ERROR")
                            .put("error", procJson.optString("error"))
                    }
                    if (procJson.optString("status") == "COMPLETE") {
                        reassembledResponseHex = procJson.optString("payload_hex")
                    }
                }
            } catch (ioe: IOException) {
                WalletCoreBridge.nativeResetTransportAssembler(pendingState.sessionId)
                logJson("TX_TOUCH_2_INTERRUPTED", JSONObject().apply {
                    put("session_id", pendingState.sessionId)
                    put("request_id", pendingState.requestId)
                    put("touch_count", pendingState.touchCount)
                    put("fetched_frames_before_interrupt", fetchedFramesCount)
                    put("error", ioe.message ?: "IOException during response fetch")
                })
                return baseTouch2Result().put("verified", false)
                    .put("status", "TOUCH_2_INTERRUPTED_RETRY_READY")
                    .put("fetched_frames_before_interrupt", fetchedFramesCount)
                    .put("error", ioe.message ?: "IOException during response fetch")
            }

            if (reassembledResponseHex == null) {
                WalletCoreBridge.nativeResetTransportAssembler(pendingState.sessionId)
                return baseTouch2Result().put("verified", false)
                    .put("status", "TOUCH_2_INTERRUPTED_RETRY_READY")
                    .put("fetched_frames_before_interrupt", fetchedFramesCount)
            }

            val verifyStr = WalletCoreBridge.nativeVerifyNfcResponse(
                pendingState.sessionId,
                pendingState.requestId,
                reassembledResponseHex
            )
            val verifyJson = JSONObject(verifyStr)
            if (verifyJson.optBoolean("verified")) {
                pendingState.completed = true
            }
            return verifyJson.apply {
                put("touch_count", pendingState.touchCount)
                put("sent_apdu_frames", pendingState.sentApduFrames)
                put("received_apdu_frames", totalRespFrames)
                put("max_capdu_wire_len", pendingState.maxCapduWireLen)
                put("max_lc", pendingState.maxLc)
                put("status_polls", polls)
                put("payload_sha256", pendingState.payloadSha256Hex)
            }
        } finally {
            try {
                transport.close()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * End-to-end NFC transaction exchange over [IsoDepTransport]:
     * watch-only `WalletCoreBridge` registers the local pending tx -> Tier-2 short APDU frames
     * (`INS=0x40`, `Lc<=128`) -> HCE Vault prepares a `PreparedRequest` with `Transport::Nfc` and
     * holds it for LOCAL review -> Reader either disconnects cleanly after Touch 1 (`twoTapDisconnectOnPending = true`)
     * or polls (`INS=0x41 P1=00`) until the Vault user approves or rejects on the Vault device ->
     * signed response frames (`INS=0x50`) -> watch-only verification against the locally retained pending tx.
     */
    fun executeRustTransactionSession(
        transport: IsoDepTransport,
        sessionId: String,
        requestId: String,
        rawRlpHex: String,
        chainId: Long,
        expectedAddress: String,
        approvalTimeoutMs: Long = DEFAULT_APPROVAL_TIMEOUT_MS,
        pollIntervalMs: Long = DEFAULT_STATUS_POLL_INTERVAL_MS,
        cancelInsteadOfWaiting: Boolean = false,
        twoTapDisconnectOnPending: Boolean = false,
        runIdForState: String = currentRunId,
        generationForState: Long = currentGeneration,
        transceiver: ((ByteArray, String) -> ByteArray)? = null,
        sleeper: (Long) -> Unit = { Thread.sleep(it) }
    ): JSONObject {
        if (!WalletCoreBridge.isAvailable) {
            return JSONObject().put("verified", false).put("status", "WALLET_NATIVE_UNAVAILABLE")
                .put("error", "WalletCoreBridge JNI library unavailable")
        }
        WalletCoreBridge.nativeInit()

        fun xfer(apdu: ByteArray, step: String): ByteArray =
            transceiver?.invoke(apdu, step) ?: transport.transceive(apdu)

        val regStr = WalletCoreBridge.nativeRegisterPendingTx(
            sessionId,
            requestId,
            rawRlpHex,
            chainId,
            expectedAddress
        )
        val regJson = JSONObject(regStr)
        if (regJson.has("error")) {
            return JSONObject().put("verified", false).put("status", "WALLET_REGISTER_FAILED")
                .put("error", regJson.optString("error"))
        }
        val signingDigestHex = regJson.optString("signing_digest").ifEmpty { regJson.optString("expected_digest") }

        val reqPayloadJson = JSONObject().apply {
            put("rlp_hex", rawRlpHex)
            put("chain_id", chainId)
            put("expected_signer", expectedAddress)
        }
        val reqPayloadBytes = reqPayloadJson.toString().toByteArray(Charsets.UTF_8)
        val payloadSha256Hex = computeSha256(reqPayloadBytes)
        val reqPayloadHex = reqPayloadBytes.joinToString("") { "%02x".format(it) }

        val pendingState = PendingWalletTxState(
            runId = runIdForState,
            generation = generationForState,
            sessionId = sessionId,
            requestId = requestId,
            rawRlpHex = rawRlpHex,
            chainId = chainId,
            expectedAddress = expectedAddress,
            payloadSha256Hex = payloadSha256Hex,
            signingDigestHex = signingDigestHex,
            touchCount = 1
        )
        activePendingWalletTx = pendingState

        val chunksStr = WalletCoreBridge.nativeChunkPayload(
            sessionId,
            requestId,
            4, // MessageKind::SignRequest
            reqPayloadHex,
            120
        )
        val chunksArr = JSONArray(chunksStr)

        transport.connect()
        transport.timeout = 5000
        try {
            // 1. SELECT AID
            val selectApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + AID_BYTES + byteArrayOf(0x00)
            val selectRapdu = parseRapdu(xfer(selectApdu, "TX_SELECT_AID"))
            if (selectRapdu == null || !selectRapdu.isSuccess) {
                return JSONObject().put("verified", false).put("status", "SELECT_FAILED")
                    .put("error", "SELECT AID failed SW=${selectRapdu?.swHex}")
            }

            var totalSentApduFrames = 0
            var maxObservedCapduLen = 0
            var maxObservedLc = 0

            // 2. Transmit all Tier-2 short APDU frames (`INS = 0x40`)
            for (i in 0 until chunksArr.length()) {
                val framesArr = chunksArr.getJSONObject(i).getJSONArray("apdu_frames_hex")
                for (j in 0 until framesArr.length()) {
                    val frameBytes = hexToBytes(framesArr.getString(j))
                    val lc = frameBytes[4].toInt() and 0xFF
                    if (lc > 128 || frameBytes.size > 134 || frameBytes.size > transport.maxTransceiveLength) {
                        return JSONObject().put("verified", false).put("status", "APDU_BOUND_VIOLATION")
                            .put("error", "APDU wire bound violated: len=${frameBytes.size}, lc=$lc")
                    }
                    if (frameBytes.size > maxObservedCapduLen) maxObservedCapduLen = frameBytes.size
                    if (lc > maxObservedLc) maxObservedLc = lc

                    val rapdu = parseRapdu(xfer(frameBytes, "TX_REQUEST_FRAME_${i}_$j"))
                    totalSentApduFrames++
                    if (rapdu == null || !rapdu.isSuccess) {
                        return JSONObject().put("verified", false).put("status", "REQUEST_FRAME_REJECTED")
                            .put("error", "Request APDU frame $j rejected with SW=${rapdu?.swHex}")
                            .put("sent_apdu_frames", totalSentApduFrames)
                    }
                }
            }

            pendingState.requestDeliveredOnTouch1 = true
            pendingState.sentApduFrames = totalSentApduFrames
            pendingState.maxCapduWireLen = maxObservedCapduLen
            pendingState.maxLc = maxObservedLc

            fun baseResult(): JSONObject = JSONObject().apply {
                put("touch_count", 1)
                put("sent_apdu_frames", totalSentApduFrames)
                put("max_capdu_wire_len", maxObservedCapduLen)
                put("max_lc", maxObservedLc)
                put("signing_digest", signingDigestHex)
                put("payload_sha256", payloadSha256Hex)
            }

            val cancelApdu = byteArrayOf(0x80.toByte(), 0x41, 0x02, 0x00, 0x00)
            if (cancelInsteadOfWaiting) {
                pendingState.completed = true
                val cancelRapdu = parseRapdu(xfer(cancelApdu, "TX_READER_CANCEL"))
                return baseResult().put("verified", false).put("status", "CANCELLED")
                    .put("cancel_sw", cancelRapdu?.swHex ?: "NONE")
            }

            // 3. Poll status or disconnect cleanly after Touch 1 delivery
            val statusApdu = byteArrayOf(0x80.toByte(), 0x41, 0x00, 0x00, 0x00)
            val deadline = ProbeSessionState.elapsedRealtimeSafe() + approvalTimeoutMs
            var polls = 0
            var finalState: Int
            var totalRespFrames: Int
            while (true) {
                val st = try {
                    parseRapdu(xfer(statusApdu, "TX_STATUS_POLL"))
                } catch (ioe: IOException) {
                    logJson("TX_TOUCH_1_DISCONNECTED_AWAITING_TOUCH_2", JSONObject().apply {
                        put("session_id", sessionId)
                        put("request_id", requestId)
                        put("sent_apdu_frames", totalSentApduFrames)
                        put("signing_digest", signingDigestHex)
                    })
                    return baseResult()
                        .put("verified", false)
                        .put("status", "AWAITING_VAULT_APPROVAL_TOUCH_2")
                        .put("request_delivered", true)
                        .put("status_polls", polls)
                }
                polls++
                if (st == null || !st.isSuccess || st.data.size != 3) {
                    return baseResult().put("verified", false).put("status", "STATUS_POLL_FAILED")
                        .put("error", "Status poll SW=${st?.swHex} len=${st?.data?.size}").put("status_polls", polls)
                }
                val code = st.data[0].toInt() and 0xFF
                if (code == VaultApprovalGate.STATE_PENDING) {
                    if (twoTapDisconnectOnPending) {
                        logJson("TX_TOUCH_1_COMPLETE_AWAITING_TOUCH_2", JSONObject().apply {
                            put("session_id", sessionId)
                            put("request_id", requestId)
                            put("sent_apdu_frames", totalSentApduFrames)
                            put("signing_digest", signingDigestHex)
                            put("payload_sha256", payloadSha256Hex)
                        })
                        return baseResult()
                            .put("verified", false)
                            .put("status", "AWAITING_VAULT_APPROVAL_TOUCH_2")
                            .put("request_delivered", true)
                            .put("status_polls", polls)
                    }
                    if (ProbeSessionState.elapsedRealtimeSafe() >= deadline) {
                        pendingState.completed = true
                        val cancelRapdu = parseRapdu(xfer(cancelApdu, "TX_TIMEOUT_CANCEL"))
                        return baseResult().put("verified", false).put("status", "APPROVAL_TIMEOUT_CANCELLED")
                            .put("cancel_sw", cancelRapdu?.swHex ?: "NONE").put("status_polls", polls)
                    }
                    sleeper(pollIntervalMs)
                    continue
                }
                finalState = code
                totalRespFrames = ((st.data[1].toInt() and 0xFF) shl 8) or (st.data[2].toInt() and 0xFF)
                break
            }

            when (finalState) {
                VaultApprovalGate.STATE_APPROVED -> Unit
                VaultApprovalGate.STATE_REJECTED -> {
                    pendingState.completed = true
                    return baseResult().put("verified", false)
                        .put("status", "REJECTED_BY_VAULT_USER").put("status_polls", polls)
                }
                VaultApprovalGate.STATE_CANCELLED -> {
                    pendingState.completed = true
                    return baseResult().put("verified", false)
                        .put("status", "VAULT_CANCELLED").put("status_polls", polls)
                }
                else -> {
                    pendingState.completed = true
                    return baseResult().put("verified", false)
                        .put("status", "VAULT_STATE_$finalState").put("status_polls", polls)
                }
            }
            if (totalRespFrames <= 0 || totalRespFrames > 255) {
                return baseResult().put("verified", false).put("status", "INVALID_RESPONSE_FRAME_COUNT")
                    .put("received_apdu_frames", totalRespFrames)
            }

            // 4. Fetch signed response frames (`INS = 0x50`)
            var reassembledResponseHex: String? = null
            for (idx in 0 until totalRespFrames) {
                val fetchApdu = byteArrayOf(0x80.toByte(), 0x50, idx.toByte(), 0x00, 0x00)
                val fetchRapdu = parseRapdu(xfer(fetchApdu, "TX_RESPONSE_FRAME_$idx"))
                if (fetchRapdu == null || !fetchRapdu.isSuccess || fetchRapdu.data.size < 6) {
                    return baseResult().put("verified", false).put("status", "RESPONSE_FETCH_FAILED")
                        .put("error", "Failed fetching response frame $idx SW=${fetchRapdu?.swHex}")
                }
                val respFrameBytes = fetchRapdu.data
                val respLc = respFrameBytes[4].toInt() and 0xFF
                if (respLc > 128 || respFrameBytes.size > 134 || respFrameBytes.size != 6 + respLc) {
                    return baseResult().put("verified", false).put("status", "RESPONSE_FRAME_BOUND_VIOLATION")
                        .put("error", "Response APDU frame $idx len=${respFrameBytes.size} lc=$respLc")
                }
                val respFrameHex = respFrameBytes.joinToString("") { "%02x".format(it) }
                val procJson = JSONObject(WalletCoreBridge.nativeProcessApduFrame(respFrameHex))
                if (procJson.has("error")) {
                    return baseResult().put("verified", false).put("status", "RESPONSE_REASSEMBLY_ERROR")
                        .put("error", procJson.optString("error"))
                }
                if (procJson.optString("status") == "COMPLETE") {
                    reassembledResponseHex = procJson.optString("payload_hex")
                }
            }

            if (reassembledResponseHex == null) {
                return baseResult().put("verified", false).put("status", "RESPONSE_INCOMPLETE")
            }

            // 5. Independent watch-only verification against the local PendingWalletRequest
            val verifyStr = WalletCoreBridge.nativeVerifyNfcResponse(
                sessionId,
                requestId,
                reassembledResponseHex
            )
            val verifyJson = JSONObject(verifyStr)
            if (verifyJson.optBoolean("verified")) {
                pendingState.completed = true
            }
            return verifyJson.apply {
                put("touch_count", 1)
                put("sent_apdu_frames", totalSentApduFrames)
                put("received_apdu_frames", totalRespFrames)
                put("max_capdu_wire_len", maxObservedCapduLen)
                put("max_lc", maxObservedLc)
                put("status_polls", polls)
                put("payload_sha256", payloadSha256Hex)
            }
        } finally {
            try {
                transport.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun publishTerminalOutcome(
        myOwnerId: Long,
        callToken: Long,
        tagRunId: String,
        tagPhase: String,
        tagGeneration: Long,
        summaryObj: JSONObject
    ) {
        val writeRes = ProbeSessionState.writePersistentReportDetailed(
            role = "READER",
            runId = tagRunId,
            phase = tagPhase,
            generation = tagGeneration,
            summaryPayload = summaryObj
        )
        if (writeRes.ok && writeRes.file != null) {
            summaryObj.put("evidence_status", "OK")
            summaryObj.put("evidence_file_path", writeRes.file.absolutePath)
        } else {
            summaryObj.put("all_passed", false)
            summaryObj.put("status", "EVIDENCE_WRITE_FAILED")
            summaryObj.put("evidence_status", "EVIDENCE_WRITE_FAILED")
            summaryObj.put("evidence_error", writeRes.errorMessage ?: "Persistent evidence write failed")
        }

        postToMainThread {
            if (activeToken.get() == callToken &&
                currentRunId == tagRunId &&
                currentGeneration == tagGeneration &&
                isActivityResumed &&
                currentRole == Role.READER
            ) {
                lastRunSummary = summaryObj
                logJson(summaryObj.optString("event", "PROBE_RUN_COMPLETE"), summaryObj)
                methodChannel?.invokeMethod("onProbeComplete", summaryObj.toString())
            } else {
                logJson("PROBE_RUN_DISCARDED_STALE", JSONObject().apply {
                    put("run_id", tagRunId)
                    put("phase", tagPhase)
                    put("generation", tagGeneration)
                    put("call_token", callToken)
                    put("active_token", activeToken.get())
                    put("active_owner_id", activeIoOwnerId.get())
                    put("my_owner_id", myOwnerId)
                    put("is_resumed", isActivityResumed)
                    put("current_role", currentRole.name)
                })
            }
        }
    }

    @JvmOverloads
    fun buildPersistentEvidenceBundle(requestedRunId: String? = null): JSONObject {
        val snap = ProbeSessionState.snapshot()
        val targetRunId = requestedRunId?.takeIf { it.isNotEmpty() } ?: snap.runId
        val bundle = ProbeSessionState.loadPersistedRunBundle(targetRunId)
        if (targetRunId == snap.runId) {
            if (!bundle.has("phase") || bundle.optString("phase").isEmpty()) bundle.put("phase", snap.phase)
            if (!bundle.has("role") || bundle.optString("role").isEmpty()) bundle.put("role", snap.role.name)
            if (bundle.optLong("generation", 0L) <= 0L) bundle.put("generation", snap.generation)
            bundle.put("token", snap.activeToken)
            val existingSummary = bundle.optJSONObject("summary")
            if ((existingSummary == null || existingSummary.length() == 0) && lastRunSummary != null) {
                bundle.put("summary", lastRunSummary)
            }
        }
        return bundle
    }

    private fun parseRapdu(apduResponse: ByteArray?): Rapdu? {
        if (apduResponse == null || apduResponse.size < 2) return null
        val sw1 = apduResponse[apduResponse.size - 2].toInt() and 0xFF
        val sw2 = apduResponse[apduResponse.size - 1].toInt() and 0xFF
        val sw = (sw1 shl 8) or sw2
        val data = apduResponse.copyOfRange(0, apduResponse.size - 2)
        return Rapdu(data, sw)
    }

    private fun computeSha256(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun computeSha256Bytes(data: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(data)
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim().removePrefix("0x")
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < clean.length) {
            out[i / 2] = clean.substring(i, i + 2).toInt(16).toByte()
            i += 2
        }
        return out
    }

    private fun logJson(eventName: String, payload: JSONObject) {
        ProbeSessionState.recordAndLogEvent(
            eventName = eventName,
            source = "READER",
            payload = payload
        )
    }
}
