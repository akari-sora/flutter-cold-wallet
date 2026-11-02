package com.mobilecoldwallet.nfc_probe

import org.json.JSONArray
import org.json.JSONObject

/**
 * Vault-side local review/approval gate for NFC transaction signing.
 *
 * The NFC peer (Reader / Wallet) can only:
 *   - deliver a sign request (INS=0x40 frames) which becomes a PENDING review here,
 *   - poll the review state with peer/context binding (INS=0x41 P1=0x00),
 *   - cancel a pre-sign pending review (INS=0x41 P1=0x02),
 *   - fetch cached response frames after a *local* approval (INS=0x50).
 *
 * Approval can only be issued by [approveLocally] / [approveLocallyWithReviewSnapshot], reachable
 * from the Vault's own UI, never from an APDU handler. A remote "approve" APDU (INS=0x41 P1=0x01)
 * is rejected with SW 6982 and never reaches the signing primitive.
 *
 * Lifecycle states explicitly distinguish pre-sign cancellation from post-sign states so that
 * backgrounding, RF field loss, or cancellation after signing never overwrites a signed fact
 * into an unsigned CANCELLED state or allows re-signing the same request.
 */
object VaultApprovalGate {
    const val STATE_PENDING = 0x00
    const val STATE_APPROVED = 0x01
    const val STATE_REJECTED = 0x02
    const val STATE_CANCELLED = 0x03
    const val STATE_FAILED = 0x04
    const val STATE_SIGNED_DISCARDED = 0x05
    const val STATE_OUTCOME_UNKNOWN = 0x06
    const val STATE_NONE = 0x0F

    const val PENDING_TTL_MS = 120_000L
    const val SIGNED_RESPONSE_CACHE_TTL_MS = 180_000L

    private const val DEFAULT_TEST_MNEMONIC =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    enum class SigningFactState {
        NONE,
        PRE_SIGN_PENDING,
        PRE_SIGN_CANCELLED,
        APPROVED_NOT_DISPATCHED,
        SIGN_COMMAND_DISPATCHED,
        SIGNED_KNOWN_SUCCESS,
        SIGNED_AWAITING_DELIVERY,
        SIGNED_DELIVERED,
        SIGNED_DISCARDED_BY_USER,
        EXTERNAL_SIGN_OUTCOME_UNKNOWN
    }

    data class PendingReview(
        val handleId: String,
        val sessionId: String,
        val requestId: String,
        val payloadSha256: String,
        val chainId: Long,
        val expectedSigner: String,
        val txType: String,
        val runId: String,
        val phase: String,
        val generation: Long,
        val token: Long,
        val reviewSeq: Long,
        val createdAtMs: Long,
        val summary: JSONObject,
        val signingDigestHex: String
    )

    data class SignedFactRecord(
        val handleId: String,
        val sessionId: String,
        val requestId: String,
        val payloadSha256: String,
        val signingDigestHex: String,
        val chainId: Long,
        val signerAddress: String,
        val signatureHex: String,
        val signedAtMs: Long,
        var factState: SigningFactState,
        var deliveryCount: Int = 0
    )

    data class PeerStatusCheckResult(
        val contextOk: Boolean,
        val stateCode: Int,
        val frameCount: Int,
        val rejectReason: String? = null
    )

    private val lock = Any()

    @Volatile
    private var armed = false
    private var vaultInitialized = false
    private var pending: PendingReview? = null
    private var state = STATE_NONE
    private var stateReason = ""
    private var signingFactState = SigningFactState.NONE
    private var signedFactRecorded = false
    private var signedAtMs = 0L
    private var lastSignedFact: SignedFactRecord? = null
    private var reviewSeqCounter = 0L
    private val frames = ArrayList<ByteArray>()
    private val deliveredFrameIndices = HashSet<Int>()
    private val nonResignableRequestIds = LinkedHashSet<String>()
    private val nonResignableHandleIds = LinkedHashSet<String>()

    /** Invoked (outside the lock) whenever the review state changes; MainActivity forwards it to Flutter. */
    @Volatile
    var reviewListener: ((JSONObject) -> Unit)? = null

    /** Injectable clock for deterministic expiry tests. */
    @Volatile
    var clock: () -> Long = { ProbeSessionState.elapsedRealtimeSafe() }

    /** Optional hook for testing disconnection/interruption after sign dispatch. */
    @Volatile
    var afterSignDispatchTestHook: ((String) -> String?)? = null

    fun isArmed(): Boolean = armed

    fun setArmed(value: Boolean, reason: String) {
        val changed: JSONObject?
        synchronized(lock) {
            armed = value
            changed = if (!value) handleCancelOrDisarmLocked("DISARMED_$reason", explicitDiscardIfSigned = true) else null
            log("VAULT_ARMED_STATE", JSONObject().put("armed", value).put("reason", reason))
        }
        changed?.let { notifyListener(it) }
    }

    fun ensureVaultInitialized(): Boolean {
        synchronized(lock) {
            if (vaultInitialized) return true
            if (!VaultCoreBridge.isAvailable) return false
            val initRc = VaultCoreBridge.nativeInit()
            val loadRc = VaultCoreBridge.nativeLoadTestMnemonic(DEFAULT_TEST_MNEMONIC, "")
            vaultInitialized = (initRc == 0 && loadRc == 0)
            return vaultInitialized
        }
    }

    /**
     * Registers a freshly prepared request for local review. Returns false (and cancels the
     * native handle) if the Vault is not armed or if the requestId/handleId has already been signed/dispatched.
     */
    fun registerPrepared(
        handleId: String,
        sessionId: String,
        requestId: String,
        summary: JSONObject,
        signingDigestHex: String,
        payloadSha256: String = "",
        chainId: Long = summary.optLong("chain_id", MainActivity.PUBLIC_TEST_CHAIN_ID),
        expectedSigner: String = "",
        txType: String = summary.optString("tx_type", "LEGACY_EIP155")
    ): Boolean {
        val notify: JSONObject
        synchronized(lock) {
            if (!armed) {
                nativeCancelQuiet(handleId)
                log("VAULT_REVIEW_REFUSED_NOT_ARMED", JSONObject().put("handle_id", handleId).put("request_id", requestId))
                return false
            }
            if (nonResignableRequestIds.contains(requestId) || nonResignableHandleIds.contains(handleId)) {
                nativeCancelQuiet(handleId)
                log(
                    "VAULT_REVIEW_REFUSED_ALREADY_SIGNED_OR_RETIRED",
                    JSONObject().put("handle_id", handleId).put("request_id", requestId)
                )
                return false
            }
            val old = pending
            if (old != null && state == STATE_PENDING) {
                nativeCancelQuiet(old.handleId)
                log(
                    "VAULT_REVIEW_SUPERSEDED",
                    JSONObject()
                        .put("old_handle_id", old.handleId)
                        .put("old_request_id", old.requestId)
                        .put("old_review_seq", old.reviewSeq)
                        .put("new_handle_id", handleId)
                        .put("new_request_id", requestId)
                )
            }
            val snap = ProbeSessionState.snapshot()
            val nextSeq = ++reviewSeqCounter
            val resolvedExpectedSigner = expectedSigner.ifEmpty {
                summary.optString("expected_signer", MainActivity.PUBLIC_TEST_SIGNER)
            }
            val resolvedPayloadSha256 = payloadSha256.ifEmpty {
                summary.optString("payload_sha256", signingDigestHex)
            }
            pending = PendingReview(
                handleId = handleId,
                sessionId = sessionId,
                requestId = requestId,
                payloadSha256 = resolvedPayloadSha256,
                chainId = chainId,
                expectedSigner = resolvedExpectedSigner,
                txType = txType,
                runId = snap.runId,
                phase = snap.phase,
                generation = snap.generation,
                token = snap.activeToken,
                reviewSeq = nextSeq,
                createdAtMs = clock(),
                summary = JSONObject(summary.toString()),
                signingDigestHex = signingDigestHex
            )
            state = STATE_PENDING
            stateReason = "AWAITING_LOCAL_REVIEW"
            signingFactState = SigningFactState.PRE_SIGN_PENDING
            signedFactRecorded = false
            signedAtMs = 0L
            frames.clear()
            deliveredFrameIndices.clear()
            notify = reviewJsonLocked()
            log("VAULT_REVIEW_PENDING", JSONObject(notify.toString()))
        }
        notifyListener(notify)
        return true
    }

    /** Reader poll: returns [state, frameCount]. Applies expiry/session-binding before answering. */
    fun readerStatus(): IntArray {
        val notify: JSONObject?
        val result: IntArray
        synchronized(lock) {
            notify = expireIfNeededLocked()
            result = if (pending == null) intArrayOf(STATE_NONE, 0) else intArrayOf(state, if (state == STATE_APPROVED) frames.size else 0)
        }
        notify?.let { notifyListener(it) }
        return result
    }

    /**
     * Context-bound status poll for Touch 2 / Touch 3 (`INS=0x41 P1=0x00` with binding JSON).
     * Verifies `session_id`, `request_id`, `payload_sha256`, `chain_id`, `expected_signer`, and `signing_digest`.
     */
    fun verifyPeerContextAndPollStatus(bindingJson: JSONObject?): PeerStatusCheckResult {
        val notify: JSONObject?
        val out: PeerStatusCheckResult
        synchronized(lock) {
            notify = expireIfNeededLocked()
            val p = pending
            if (p == null) {
                out = PeerStatusCheckResult(false, STATE_NONE, 0, "NO_ACTIVE_VAULT_REVIEW")
            } else if (bindingJson != null) {
                val peerSess = bindingJson.optString("session_id", "")
                val peerReq = bindingJson.optString("request_id", "")
                val peerPayloadSha = bindingJson.optString("payload_sha256", "")
                val peerDigest = bindingJson.optString("signing_digest", "")
                val peerChainId = bindingJson.optLong("chain_id", -1L)
                val peerSigner = bindingJson.optString("expected_signer", "")

                val mismatchReason = when {
                    peerSess.isEmpty() || peerSess != p.sessionId ->
                        "SESSION_ID_MISMATCH(expected=${p.sessionId}, got=$peerSess)"
                    peerReq.isEmpty() || peerReq != p.requestId ->
                        "REQUEST_ID_MISMATCH(expected=${p.requestId}, got=$peerReq)"
                    peerPayloadSha.isNotEmpty() && !peerPayloadSha.equals(p.payloadSha256, ignoreCase = true) ->
                        "PAYLOAD_SHA256_MISMATCH(expected=${p.payloadSha256}, got=$peerPayloadSha)"
                    peerDigest.isNotEmpty() && !peerDigest.equals(p.signingDigestHex, ignoreCase = true) ->
                        "SIGNING_DIGEST_MISMATCH(expected=${p.signingDigestHex}, got=$peerDigest)"
                    peerChainId <= 0L || peerChainId != p.chainId ->
                        "CHAIN_ID_MISMATCH(expected=${p.chainId}, got=$peerChainId)"
                    peerSigner.isEmpty() || !peerSigner.equals(p.expectedSigner, ignoreCase = true) ->
                        "EXPECTED_SIGNER_MISMATCH(expected=${p.expectedSigner}, got=$peerSigner)"
                    else -> null
                }
                if (mismatchReason != null) {
                    out = PeerStatusCheckResult(false, state, 0, mismatchReason)
                } else {
                    out = PeerStatusCheckResult(
                        contextOk = true,
                        stateCode = state,
                        frameCount = if (state == STATE_APPROVED) frames.size else 0
                    )
                }
            } else {
                out = PeerStatusCheckResult(
                    contextOk = true,
                    stateCode = state,
                    frameCount = if (state == STATE_APPROVED) frames.size else 0
                )
            }
        }
        notify?.let { notifyListener(it) }
        return out
    }

    /**
     * Local approval using the full review snapshot displayed on the Vault UI.
     * Enforces complete review identity binding (`handle_id`, `request_id`, `payload_sha256`,
     * `signing_digest`, `chain_id`, `expected_signer`, `run_id`, `generation`, `review_seq`).
     */
    fun approveLocallyWithReviewSnapshot(displayedReview: JSONObject, uiSource: String): JSONObject {
        return approveLocally(
            handleId = displayedReview.optString("handle_id", ""),
            uiSource = uiSource,
            expectedRequestId = displayedReview.optString("request_id").takeIf { it.isNotEmpty() },
            expectedPayloadSha256 = displayedReview.optString("payload_sha256").takeIf { it.isNotEmpty() },
            expectedSigningDigestHex = displayedReview.optString("signing_digest").takeIf { it.isNotEmpty() },
            expectedChainId = if (displayedReview.has("chain_id")) displayedReview.optLong("chain_id", -1L) else null,
            expectedSigner = displayedReview.optString("expected_signer").takeIf { it.isNotEmpty() },
            expectedRunId = displayedReview.optString("run_id").takeIf { it.isNotEmpty() },
            expectedGeneration = if (displayedReview.has("generation")) displayedReview.optLong("generation", -1L) else null,
            expectedReviewSeq = if (displayedReview.has("review_seq")) displayedReview.optLong("review_seq", -1L) else null
        )
    }

    /**
     * Local approval from the Vault UI. `handleId` and all provided identity fields must equal
     * the currently active pending review; never signs a superseded or mismatched request.
     */
    @JvmOverloads
    fun approveLocally(
        handleId: String,
        uiSource: String,
        expectedRequestId: String? = null,
        expectedPayloadSha256: String? = null,
        expectedSigningDigestHex: String? = null,
        expectedChainId: Long? = null,
        expectedSigner: String? = null,
        expectedRunId: String? = null,
        expectedGeneration: Long? = null,
        expectedReviewSeq: Long? = null
    ): JSONObject {
        val notify: JSONObject?
        val out: JSONObject
        synchronized(lock) {
            val expired = expireIfNeededLocked()
            val p = pending
            if (p == null || handleId.isEmpty() || p.handleId != handleId) {
                out = JSONObject()
                    .put("approved", false)
                    .put("reason", "NO_MATCHING_PENDING_REVIEW")
                    .put("signing_fact_state", signingFactState.name)
                notify = expired
            } else if (
                (expectedRequestId != null && expectedRequestId != p.requestId) ||
                (expectedPayloadSha256 != null && !expectedPayloadSha256.equals(p.payloadSha256, ignoreCase = true)) ||
                (expectedSigningDigestHex != null && !expectedSigningDigestHex.equals(p.signingDigestHex, ignoreCase = true)) ||
                (expectedChainId != null && expectedChainId != p.chainId) ||
                (expectedSigner != null && !expectedSigner.equals(p.expectedSigner, ignoreCase = true)) ||
                (expectedRunId != null && expectedRunId != p.runId) ||
                (expectedGeneration != null && expectedGeneration != p.generation) ||
                (expectedReviewSeq != null && expectedReviewSeq != p.reviewSeq)
            ) {
                out = JSONObject()
                    .put("approved", false)
                    .put("reason", "REVIEW_IDENTITY_MISMATCH_OR_SUPERSEDED")
                    .put("signing_fact_state", signingFactState.name)
                log(
                    "VAULT_APPROVAL_REJECTED_IDENTITY_MISMATCH",
                    JSONObject()
                        .put("active_handle_id", p.handleId)
                        .put("active_request_id", p.requestId)
                        .put("active_review_seq", p.reviewSeq)
                        .put("expected_request_id", expectedRequestId ?: "")
                        .put("expected_review_seq", expectedReviewSeq ?: -1L)
                )
                notify = expired
            } else if (state != STATE_PENDING || signingFactState != SigningFactState.PRE_SIGN_PENDING) {
                out = JSONObject()
                    .put("approved", false)
                    .put("reason", "REVIEW_NOT_PENDING_STATE_$state")
                    .put("state_reason", stateReason)
                    .put("signing_fact_state", signingFactState.name)
                notify = expired
            } else if (nonResignableRequestIds.contains(p.requestId) || nonResignableHandleIds.contains(p.handleId)) {
                out = JSONObject()
                    .put("approved", false)
                    .put("reason", "REQUEST_ALREADY_SIGNED_OR_DISPATCHED")
                    .put("signing_fact_state", signingFactState.name)
                notify = expired
            } else if (!ensureVaultInitialized()) {
                state = STATE_FAILED
                stateReason = "VAULT_NATIVE_UNAVAILABLE"
                out = JSONObject().put("approved", false).put("reason", stateReason)
                notify = reviewJsonLocked()
            } else {
                // Step 1: Transition to APPROVED_NOT_DISPATCHED and lock out re-signing
                signingFactState = SigningFactState.APPROVED_NOT_DISPATCHED
                nonResignableRequestIds.add(p.requestId)
                nonResignableHandleIds.add(p.handleId)

                // Step 2: Dispatch sign command to Rust primitive
                signingFactState = SigningFactState.SIGN_COMMAND_DISPATCHED
                signedFactRecorded = true
                val hookOverride = afterSignDispatchTestHook?.invoke(p.handleId)
                val signStr = hookOverride ?: VaultCoreBridge.nativeApproveAndSign(p.handleId)
                val signJson = try {
                    JSONObject(signStr)
                } catch (_: Throwable) {
                    JSONObject().put("status", "OUTCOME_UNKNOWN").put("error", "Malformed native response")
                }
                val signStatus = signJson.optString("status")
                val sigHex = signJson.optString("signature").removePrefix("0x")

                if (signStatus == "OUTCOME_UNKNOWN" || signJson.optString("error").contains("SigningOutcomeUnknown")) {
                    state = STATE_OUTCOME_UNKNOWN
                    stateReason = "EXTERNAL_SIGN_OUTCOME_UNKNOWN"
                    signingFactState = SigningFactState.EXTERNAL_SIGN_OUTCOME_UNKNOWN
                    signedFactRecorded = true
                    signedAtMs = clock()
                    lastSignedFact = SignedFactRecord(
                        handleId = p.handleId,
                        sessionId = p.sessionId,
                        requestId = p.requestId,
                        payloadSha256 = p.payloadSha256,
                        signingDigestHex = p.signingDigestHex,
                        chainId = p.chainId,
                        signerAddress = p.expectedSigner,
                        signatureHex = "",
                        signedAtMs = signedAtMs,
                        factState = SigningFactState.EXTERNAL_SIGN_OUTCOME_UNKNOWN
                    )
                    out = JSONObject()
                        .put("approved", false)
                        .put("reason", stateReason)
                        .put("signing_fact_state", signingFactState.name)
                        .put("signed_fact_recorded", true)
                    log(
                        "VAULT_SIGN_OUTCOME_UNKNOWN",
                        JSONObject()
                            .put("handle_id", p.handleId)
                            .put("request_id", p.requestId)
                            .put("signing_fact_state", signingFactState.name)
                    )
                } else if (signStatus != "SUCCESS" || sigHex.length != 130) {
                    state = STATE_FAILED
                    stateReason = "SIGN_FAILED_${signJson.optString("error")}"
                    out = JSONObject()
                        .put("approved", false)
                        .put("reason", stateReason)
                        .put("signing_fact_state", signingFactState.name)
                } else {
                    val signerAddr = signJson.optString("address")
                    if (p.expectedSigner.isNotEmpty() && !signerAddr.equals(p.expectedSigner, ignoreCase = true)) {
                        state = STATE_FAILED
                        stateReason = "SIGNER_ADDRESS_MISMATCH(expected=${p.expectedSigner}, got=$signerAddr)"
                        out = JSONObject().put("approved", false).put("reason", stateReason)
                    } else {
                        signingFactState = SigningFactState.SIGNED_KNOWN_SUCCESS
                        val responseObj = JSONObject().apply {
                            put("request_id", p.requestId)
                            put("digest", p.signingDigestHex)
                            put("r", sigHex.substring(0, 64))
                            put("s", sigHex.substring(64, 128))
                            put("v", sigHex.substring(128, 130).toInt(16))
                            put("signer_address", signerAddr)
                            put("signature_ur", signJson.optString("signature_ur"))
                        }
                        val respHex = responseObj.toString().toByteArray(Charsets.UTF_8)
                            .joinToString("") { "%02x".format(it) }
                        val chunksArr = JSONArray(
                            VaultCoreBridge.nativeChunkPayload(p.sessionId, p.requestId, 6, respHex, 120)
                        )
                        frames.clear()
                        deliveredFrameIndices.clear()
                        for (i in 0 until chunksArr.length()) {
                            val framesArr = chunksArr.getJSONObject(i).getJSONArray("apdu_frames_hex")
                            for (j in 0 until framesArr.length()) {
                                frames.add(hexToBytes(framesArr.getString(j)))
                            }
                        }
                        state = STATE_APPROVED
                        stateReason = "LOCAL_APPROVAL_$uiSource"
                        signingFactState = SigningFactState.SIGNED_AWAITING_DELIVERY
                        signedFactRecorded = true
                        signedAtMs = clock()
                        lastSignedFact = SignedFactRecord(
                            handleId = p.handleId,
                            sessionId = p.sessionId,
                            requestId = p.requestId,
                            payloadSha256 = p.payloadSha256,
                            signingDigestHex = p.signingDigestHex,
                            chainId = p.chainId,
                            signerAddress = signerAddr,
                            signatureHex = sigHex,
                            signedAtMs = signedAtMs,
                            factState = SigningFactState.SIGNED_AWAITING_DELIVERY
                        )
                        out = JSONObject().apply {
                            put("approved", true)
                            put("handle_id", p.handleId)
                            put("request_id", p.requestId)
                            put("signer_address", signerAddr)
                            put("response_apdu_frames", frames.size)
                            put("signing_fact_state", signingFactState.name)
                            put("signed_fact_recorded", true)
                        }
                        log("VAULT_LOCAL_APPROVED_AND_SIGNED", JSONObject().apply {
                            put("handle_id", p.handleId)
                            put("session_id", p.sessionId)
                            put("request_id", p.requestId)
                            put("review_seq", p.reviewSeq)
                            put("ui_source", uiSource)
                            put("signer_address", signerAddr)
                            put("response_apdu_frames", frames.size)
                            put("signing_fact_state", signingFactState.name)
                            put("primitive_sign_invocations", VaultCoreBridge.nativeGetPrimitiveSignCount())
                        })
                        ProbeSessionState.writePersistentReport(
                            role = "HCE",
                            runId = p.runId,
                            phase = p.phase,
                            generation = p.generation,
                            summaryPayload = JSONObject().apply {
                                put("event", "VAULT_TX_SIGNED_REPORT")
                                put("handle_id", p.handleId)
                                put("request_id", p.requestId)
                                put("signer_address", signerAddr)
                                put("response_apdu_frames", frames.size)
                                put("signing_fact_state", signingFactState.name)
                                put("signed_fact_recorded", true)
                                put("approval_source", uiSource)
                            }
                        )
                    }
                }
                notify = reviewJsonLocked()
            }
        }
        notify?.let { notifyListener(it) }
        return out
    }

    fun rejectLocally(handleId: String, uiSource: String): Boolean {
        val notify: JSONObject?
        synchronized(lock) {
            val p = pending
            if (p == null || p.handleId != handleId || state != STATE_PENDING) return false
            nativeCancelQuiet(p.handleId)
            nonResignableRequestIds.add(p.requestId)
            nonResignableHandleIds.add(p.handleId)
            state = STATE_REJECTED
            stateReason = "LOCAL_REJECT_$uiSource"
            signingFactState = SigningFactState.PRE_SIGN_CANCELLED
            log(
                "VAULT_LOCAL_REJECTED",
                JSONObject()
                    .put("handle_id", p.handleId)
                    .put("request_id", p.requestId)
                    .put("ui_source", uiSource)
                    .put("signing_fact_state", signingFactState.name)
                    .put("primitive_sign_invocations", signCountQuiet())
            )
            notify = reviewJsonLocked()
        }
        notify?.let { notifyListener(it) }
        return true
    }

    /**
     * Explicit user action to discard the cached signed response frames without erasing the
     * historical fact that the request was already signed (`SIGNED_DISCARDED_BY_USER`).
     */
    fun discardSignedResponseByUser(handleId: String, reason: String = "USER_DISCARD_SIGNED_RESPONSE"): Boolean {
        val notify: JSONObject?
        synchronized(lock) {
            val p = pending
            if (p == null || p.handleId != handleId || !isPostSignOrDispatchLocked()) return false
            frames.clear()
            state = STATE_SIGNED_DISCARDED
            stateReason = reason
            signingFactState = SigningFactState.SIGNED_DISCARDED_BY_USER
            signedFactRecorded = true
            lastSignedFact?.factState = SigningFactState.SIGNED_DISCARDED_BY_USER
            log(
                "VAULT_SIGNED_RESPONSE_DISCARDED_PRESERVING_FACT",
                JSONObject()
                    .put("handle_id", p.handleId)
                    .put("request_id", p.requestId)
                    .put("reason", reason)
                    .put("signing_fact_state", signingFactState.name)
                    .put("signed_fact_recorded", true)
                    .put("primitive_sign_invocations", signCountQuiet())
            )
            notify = reviewJsonLocked()
        }
        notify?.let { notifyListener(it) }
        return true
    }

    /** Reader-initiated cancel (allowed only while pre-sign pending; never overwrites a signed request). */
    fun cancelFromReader(): Boolean {
        val notify: JSONObject?
        synchronized(lock) {
            if (pending == null) return false
            if (state != STATE_PENDING || isPostSignOrDispatchLocked()) {
                log(
                    "VAULT_CANCEL_REJECTED_ALREADY_SIGNED",
                    JSONObject()
                        .put("handle_id", pending?.handleId ?: "")
                        .put("state", stateName(state))
                        .put("signing_fact_state", signingFactState.name)
                        .put("signed_fact_recorded", signedFactRecorded)
                )
                return false
            }
            notify = handleCancelOrDisarmLocked("READER_CANCEL", explicitDiscardIfSigned = false)
        }
        notify?.let { notifyListener(it) }
        return true
    }

    fun cancelPending(reason: String) {
        val notify: JSONObject?
        synchronized(lock) {
            val explicitDiscard = reason.contains("RESET_RUN_SESSION") ||
                    reason.contains("DISARMED") ||
                    reason.contains("USER_DISCARD")
            notify = handleCancelOrDisarmLocked(reason, explicitDiscardIfSigned = explicitDiscard)
        }
        notify?.let { notifyListener(it) }
    }

    /** Returns the idx-th signed response frame only while an approved review is still valid. */
    fun responseFrame(idx: Int): ByteArray? {
        val notify: JSONObject?
        val frame: ByteArray?
        synchronized(lock) {
            notify = expireIfNeededLocked()
            if (state == STATE_APPROVED && idx >= 0 && idx < frames.size) {
                frame = frames[idx]
                deliveredFrameIndices.add(idx)
                if (deliveredFrameIndices.size == frames.size) {
                    signingFactState = SigningFactState.SIGNED_DELIVERED
                    lastSignedFact?.let {
                        it.factState = SigningFactState.SIGNED_DELIVERED
                        it.deliveryCount += 1
                    }
                }
            } else {
                frame = null
            }
        }
        notify?.let { notifyListener(it) }
        return frame
    }

    fun responseFrameCount(): Int = synchronized(lock) { if (state == STATE_APPROVED) frames.size else 0 }

    fun currentReviewJson(): JSONObject = synchronized(lock) { reviewJsonLocked() }

    fun getLastSignedFactJson(): JSONObject = synchronized(lock) {
        val fact = lastSignedFact ?: return@synchronized JSONObject().put("present", false)
        JSONObject().apply {
            put("present", true)
            put("handle_id", fact.handleId)
            put("session_id", fact.sessionId)
            put("request_id", fact.requestId)
            put("payload_sha256", fact.payloadSha256)
            put("signing_digest", fact.signingDigestHex)
            put("chain_id", fact.chainId)
            put("signer_address", fact.signerAddress)
            put("signature_hex", fact.signatureHex)
            put("signed_at_ms", fact.signedAtMs)
            put("signing_fact_state", fact.factState.name)
            put("delivery_count", fact.deliveryCount)
        }
    }

    fun resetForTesting() {
        synchronized(lock) {
            armed = false
            pending = null
            state = STATE_NONE
            stateReason = ""
            signingFactState = SigningFactState.NONE
            signedFactRecorded = false
            signedAtMs = 0L
            lastSignedFact = null
            reviewSeqCounter = 0L
            frames.clear()
            deliveredFrameIndices.clear()
            nonResignableRequestIds.clear()
            nonResignableHandleIds.clear()
            reviewListener = null
            afterSignDispatchTestHook = null
            clock = { ProbeSessionState.elapsedRealtimeSafe() }
        }
    }

    // --- internals (call with lock held) ---

    private fun isPostSignOrDispatchLocked(): Boolean {
        return signedFactRecorded || signingFactState in setOf(
            SigningFactState.APPROVED_NOT_DISPATCHED,
            SigningFactState.SIGN_COMMAND_DISPATCHED,
            SigningFactState.SIGNED_KNOWN_SUCCESS,
            SigningFactState.SIGNED_AWAITING_DELIVERY,
            SigningFactState.SIGNED_DELIVERED,
            SigningFactState.SIGNED_DISCARDED_BY_USER,
            SigningFactState.EXTERNAL_SIGN_OUTCOME_UNKNOWN
        )
    }

    private fun boundForPendingApprovalLocked(p: PendingReview): Boolean {
        val s = ProbeSessionState.snapshot()
        return armed && s.runId == p.runId && s.generation == p.generation && s.activeToken == p.token
    }

    private fun boundForSignedDeliveryLocked(p: PendingReview): Boolean {
        val s = ProbeSessionState.snapshot()
        // Signed response delivery across Touch 2 / Touch 3 requires the Vault to remain armed
        // on the same runId; ambient pause/resume token bumps must NOT erase the signed fact or response cache.
        return armed && s.runId == p.runId
    }

    private fun expireIfNeededLocked(): JSONObject? {
        val p = pending ?: return null
        val now = clock()
        if (state == STATE_PENDING) {
            if (now - p.createdAtMs > PENDING_TTL_MS) {
                return handleCancelOrDisarmLocked("EXPIRED", explicitDiscardIfSigned = false)
            }
            if (!boundForPendingApprovalLocked(p)) {
                return handleCancelOrDisarmLocked("SESSION_CHANGED", explicitDiscardIfSigned = false)
            }
            return null
        }
        if (state == STATE_APPROVED) {
            if (signedAtMs > 0L && now - signedAtMs > SIGNED_RESPONSE_CACHE_TTL_MS) {
                frames.clear()
                state = STATE_SIGNED_DISCARDED
                stateReason = "SIGNED_RESPONSE_CACHE_EXPIRED"
                signingFactState = SigningFactState.SIGNED_DISCARDED_BY_USER
                lastSignedFact?.factState = SigningFactState.SIGNED_DISCARDED_BY_USER
                log(
                    "VAULT_SIGNED_RESPONSE_CACHE_EXPIRED",
                    JSONObject()
                        .put("handle_id", p.handleId)
                        .put("request_id", p.requestId)
                        .put("signing_fact_state", signingFactState.name)
                        .put("signed_fact_recorded", true)
                )
                return reviewJsonLocked()
            }
            if (!boundForSignedDeliveryLocked(p)) {
                return handleCancelOrDisarmLocked("SIGNED_RUN_CHANGED_OR_DISARMED", explicitDiscardIfSigned = true)
            }
        }
        return null
    }

    private fun handleCancelOrDisarmLocked(reason: String, explicitDiscardIfSigned: Boolean): JSONObject? {
        val p = pending ?: return null
        if (state == STATE_PENDING && !isPostSignOrDispatchLocked()) {
            nativeCancelQuiet(p.handleId)
            nonResignableRequestIds.add(p.requestId)
            nonResignableHandleIds.add(p.handleId)
            val prev = state
            state = STATE_CANCELLED
            stateReason = reason
            signingFactState = SigningFactState.PRE_SIGN_CANCELLED
            frames.clear()
            log("VAULT_REVIEW_CANCELLED", JSONObject().apply {
                put("handle_id", p.handleId)
                put("request_id", p.requestId)
                put("reason", reason)
                put("previous_state", prev)
                put("signing_fact_state", signingFactState.name)
                put("signed_fact_recorded", false)
                put("primitive_sign_invocations", signCountQuiet())
            })
            return reviewJsonLocked()
        }

        if (isPostSignOrDispatchLocked()) {
            // Never overwrite a signed or dispatched state into STATE_CANCELLED (PRE_SIGN_CANCELLED)!
            if (explicitDiscardIfSigned && state == STATE_APPROVED) {
                frames.clear()
                state = STATE_SIGNED_DISCARDED
                stateReason = reason
                signingFactState = SigningFactState.SIGNED_DISCARDED_BY_USER
                lastSignedFact?.factState = SigningFactState.SIGNED_DISCARDED_BY_USER
                log("VAULT_SIGNED_RESPONSE_DISCARDED_PRESERVING_FACT", JSONObject().apply {
                    put("handle_id", p.handleId)
                    put("request_id", p.requestId)
                    put("reason", reason)
                    put("signing_fact_state", signingFactState.name)
                    put("signed_fact_recorded", true)
                    put("primitive_sign_invocations", signCountQuiet())
                })
                return reviewJsonLocked()
            }
            // Ambient lifecycle event (e.g. ON_PAUSE / HCE_DEACTIVATED) while awaiting Touch 2 delivery:
            // preserve both the signed fact and the cached response frames!
            log("VAULT_SIGNED_STATE_PRESERVED_ON_EVENT", JSONObject().apply {
                put("handle_id", p.handleId)
                put("request_id", p.requestId)
                put("ignored_cancel_reason", reason)
                put("state", stateName(state))
                put("signing_fact_state", signingFactState.name)
                put("signed_fact_recorded", true)
                put("cached_response_frames", frames.size)
            })
            return null
        }
        return null
    }

    private fun reviewJsonLocked(): JSONObject {
        val p = pending
        return JSONObject().apply {
            put("state", stateName(state))
            put("state_code", state)
            put("state_reason", stateReason)
            put("signing_fact_state", signingFactState.name)
            put("signed_fact_recorded", signedFactRecorded)
            put("armed", armed)
            if (p != null) {
                put("handle_id", p.handleId)
                put("session_id", p.sessionId)
                put("request_id", p.requestId)
                put("payload_sha256", p.payloadSha256)
                put("chain_id", p.chainId)
                put("expected_signer", p.expectedSigner)
                put("tx_type", p.txType)
                put("run_id", p.runId)
                put("phase", p.phase)
                put("generation", p.generation)
                put("review_seq", p.reviewSeq)
                put("signing_digest", p.signingDigestHex)
                put("summary", p.summary)
            }
            put("response_apdu_frames", if (state == STATE_APPROVED) frames.size else 0)
        }
    }

    private fun stateName(s: Int): String = when (s) {
        STATE_PENDING -> "PENDING_LOCAL_REVIEW"
        STATE_APPROVED -> "APPROVED_SIGNED"
        STATE_REJECTED -> "REJECTED"
        STATE_CANCELLED -> "CANCELLED"
        STATE_FAILED -> "FAILED"
        STATE_SIGNED_DISCARDED -> "SIGNED_DISCARDED_BY_USER"
        STATE_OUTCOME_UNKNOWN -> "EXTERNAL_SIGN_OUTCOME_UNKNOWN"
        else -> "NONE"
    }

    private fun nativeCancelQuiet(handleId: String) {
        try {
            if (VaultCoreBridge.isAvailable) VaultCoreBridge.nativeCancel(handleId)
        } catch (_: Throwable) {
        }
    }

    private fun signCountQuiet(): Long = try {
        if (VaultCoreBridge.isAvailable) VaultCoreBridge.nativeGetPrimitiveSignCount() else -1L
    } catch (_: Throwable) {
        -1L
    }

    private fun notifyListener(review: JSONObject) {
        try {
            reviewListener?.invoke(review)
        } catch (_: Throwable) {
        }
    }

    private fun log(event: String, payload: JSONObject) {
        ProbeSessionState.recordAndLogEvent(eventName = event, source = "VAULT", payload = payload)
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
}

