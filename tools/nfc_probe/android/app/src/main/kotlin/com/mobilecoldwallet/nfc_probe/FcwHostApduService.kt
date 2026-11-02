package com.mobilecoldwallet.nfc_probe

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

class FcwHostApduService : HostApduService() {

    companion object {
        private const val TAG = "FCW_NFC_PROBE"
        val AID_BYTES = byteArrayOf(0xF0.toByte(), 0x46, 0x43, 0x57, 0x01)
        const val MAX_CHUNK_SIZE = 128
        const val MAX_SESSION_BYTES = 131072 // 128 KiB upper bound

        // ISO 7816-4 Status Words
        val SW_SUCCESS = byteArrayOf(0x90.toByte(), 0x00)
        val SW_WRONG_LENGTH = byteArrayOf(0x67.toByte(), 0x00)
        val SW_CONDITIONS_NOT_SATISFIED = byteArrayOf(0x69.toByte(), 0x85.toByte())
        val SW_FILE_NOT_FOUND = byteArrayOf(0x6A.toByte(), 0x82.toByte())
        val SW_NOT_ENOUGH_MEMORY = byteArrayOf(0x6A.toByte(), 0x84.toByte())
        val SW_INCORRECT_LC = byteArrayOf(0x6A.toByte(), 0x85.toByte())
        val SW_INCORRECT_P1P2 = byteArrayOf(0x6A.toByte(), 0x86.toByte())
        val SW_INS_NOT_SUPPORTED = byteArrayOf(0x6D.toByte(), 0x00)
        val SW_CLA_NOT_SUPPORTED = byteArrayOf(0x6E.toByte(), 0x00)
        val SW_SECURITY_STATUS_NOT_SATISFIED = byteArrayOf(0x69.toByte(), 0x82.toByte())
    }

    private var messageDigest: MessageDigest = MessageDigest.getInstance("SHA-256")
    private var totalBytesReceived = 0
    private var chunkCount = 0
    private var sessionSeq = 0
    private var preparedInSessionSeq = -1
    private var verifiedPeerSessionSeq = -1
    private val pendingPeerContextBuffer = java.io.ByteArrayOutputStream()

    override fun onCreate() {
        super.onCreate()
        try {
            ProbeSessionState.configureEvidenceDirectory(filesDir)
        } catch (_: Throwable) {
        }
    }

    private fun ensureRustVaultInitialized(): Boolean = VaultApprovalGate.ensureVaultInitialized()

    private fun logHceJson(event: String, buildPayload: JSONObject.() -> Unit = {}): JSONObject {
        val snap = ProbeSessionState.snapshot()
        val json = JSONObject().apply {
            put("event", event)
            put("source", "HCE")
            put("role", "HCE")
            put("run_id", snap.runId)
            put("phase", snap.phase)
            put("generation", snap.generation)
            put("token", snap.activeToken)
            put("session_seq", sessionSeq)
            buildPayload()
        }
        return ProbeSessionState.recordAndLogEvent(
            eventName = event,
            source = "HCE",
            payload = json,
            snapshotOverride = snap
        )
    }

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null || commandApdu.size < 4) {
            logHceJson("HCE_COMMAND_TRUNCATED") {
                put("size", commandApdu?.size ?: 0)
                put("status", "REJECTED_WRONG_LENGTH")
            }
            return SW_WRONG_LENGTH
        }

        val cla = commandApdu[0]
        val ins = commandApdu[1]
        val p1 = commandApdu[2]
        val p2 = commandApdu[3]

        // 1. SELECT AID (CLA=00, INS=A4, P1=04, P2=00)
        if (cla == 0x00.toByte()) {
            if (ins != 0xA4.toByte()) {
                logHceJson("HCE_SELECT_INVALID_INS") {
                    put("ins", "%02x".format(ins))
                }
                return SW_INS_NOT_SUPPORTED
            }
            if (p1 != 0x04.toByte() || p2 != 0x00.toByte()) {
                logHceJson("HCE_SELECT_INVALID_P1P2") {
                    put("p1", "%02x".format(p1))
                    put("p2", "%02x".format(p2))
                }
                return SW_INCORRECT_P1P2
            }
            if (commandApdu.size < 5) return SW_WRONG_LENGTH
            val lc = commandApdu[4].toInt() and 0xFF

            // Exact length check: must be either 5 + Lc (no Le) or 5 + Lc + 1 (with Le)
            if (commandApdu.size != 5 + lc && commandApdu.size != 5 + lc + 1) {
                return SW_WRONG_LENGTH
            }

            val receivedAid = commandApdu.copyOfRange(5, 5 + lc)
            if (receivedAid.contentEquals(AID_BYTES)) {
                sessionSeq++
                messageDigest.reset()
                totalBytesReceived = 0
                chunkCount = 0
                pendingPeerContextBuffer.reset()
                logHceJson("HCE_SELECT_AID") {
                    put("status", "OK")
                    put("aid", "F046435701")
                    put("version", "1.0")
                    put("max_chunk", MAX_CHUNK_SIZE)
                }
                // Return Capabilities: Version 1.0 (2 bytes), Max Chunk 128 (2 bytes) = [0x01, 0x00, 0x00, 0x80] + 9000
                return byteArrayOf(0x01, 0x00, 0x00, 0x80.toByte()) + SW_SUCCESS
            } else {
                logHceJson("HCE_SELECT_AID") {
                    put("status", "REJECTED_UNKNOWN_AID")
                    put("received_aid", receivedAid.joinToString("") { "%02x".format(it) })
                }
                return SW_FILE_NOT_FOUND
            }
        }

        // 2. Proprietary CLA = 0x80
        if (cla == 0x80.toByte()) {
            // INS = 0x40 (Rust Core Tier-2 NFC Envelope Frame) and INS = 0x41 / 0x50 use P1/P2 for framing/control
            when (ins) {
                0x40.toByte() -> return handleRustEnvelopeFrameApdu(commandApdu)
                0x41.toByte() -> return handleRustTxDecisionApdu(commandApdu, p1, p2)
                0x50.toByte() -> return handleRustGetResponseFrameApdu(commandApdu, p1, p2)
            }

            // Strict P1/P2 validation: probe commands (0x10, 0x20, 0x30) require P1=0x00, P2=0x00
            if (p1 != 0x00.toByte() || p2 != 0x00.toByte()) {
                logHceJson("HCE_INVALID_P1P2") {
                    put("ins", "%02x".format(ins))
                    put("p1", "%02x".format(p1))
                    put("p2", "%02x".format(p2))
                }
                return SW_INCORRECT_P1P2
            }

            when (ins) {
                // INS = 0x10: CHUNK_WRITE
                0x10.toByte() -> {
                    if (commandApdu.size < 5) return SW_WRONG_LENGTH
                    val lc = commandApdu[4].toInt() and 0xFF
                    if (lc <= 0 || lc > MAX_CHUNK_SIZE) {
                        logHceJson("HCE_CHUNK_OVERSIZED") {
                            put("lc", lc)
                            put("limit", MAX_CHUNK_SIZE)
                        }
                        return SW_WRONG_LENGTH
                    }
                    // Strict APDU length verification: command size must be 5 + Lc (no Le) or 5 + Lc + 1 (with Le)
                    if (commandApdu.size != 5 + lc && commandApdu.size != 5 + lc + 1) {
                        return SW_WRONG_LENGTH
                    }

                    // Session memory budget check (128 KiB)
                    if (totalBytesReceived + lc > MAX_SESSION_BYTES) {
                        logHceJson("HCE_SESSION_BUDGET_EXCEEDED") {
                            put("accumulated", totalBytesReceived)
                            put("requested", lc)
                            put("limit", MAX_SESSION_BYTES)
                        }
                        return SW_NOT_ENOUGH_MEMORY
                    }

                    val chunkData = commandApdu.copyOfRange(5, 5 + lc)
                    messageDigest.update(chunkData)
                    totalBytesReceived += chunkData.size
                    chunkCount++
                    logHceJson("HCE_CHUNK_RECEIVED") {
                        put("chunk_index", chunkCount)
                        put("bytes", chunkData.size)
                        put("total_accumulated", totalBytesReceived)
                    }
                    // Return exact echo of received chunk + 9000
                    return chunkData + SW_SUCCESS
                }

                // INS = 0x20: GET_DIGEST
                0x20.toByte() -> {
                    if (commandApdu.size > 5) {
                        return SW_WRONG_LENGTH
                    }
                    if (commandApdu.size == 5) {
                        val le = commandApdu[4].toInt() and 0xFF
                        if (le != 32 && le != 0) {
                            return SW_WRONG_LENGTH
                        }
                    }

                    val bytesCount = totalBytesReceived
                    val chunksCount = chunkCount
                    val digest = messageDigest.digest()
                    val hexDigest = digest.joinToString("") { "%02x".format(it) }
                    val evt = logHceJson("HCE_DIGEST_REQUESTED") {
                        put("total_bytes", bytesCount)
                        put("chunks", chunksCount)
                        put("sha256", hexDigest)
                    }
                    // Persist HCE evidence snapshot after digest computation (A7)
                    val snap = ProbeSessionState.snapshot()
                    ProbeSessionState.writePersistentReport(
                        role = "HCE",
                        runId = snap.runId,
                        phase = snap.phase,
                        generation = snap.generation,
                        summaryPayload = JSONObject().apply {
                            put("event", "HCE_DIGEST_REPORT")
                            put("last_digest_sha256", hexDigest)
                            put("last_total_bytes", bytesCount)
                            put("last_chunks", chunksCount)
                            put("session_seq", sessionSeq)
                            put("last_event_seq", evt.optLong("event_seq"))
                        }
                    )

                    // Reset session on digest consumption
                    messageDigest.reset()
                    totalBytesReceived = 0
                    chunkCount = 0
                    return digest + SW_SUCCESS
                }

                // INS = 0x30: RESET_SESSION
                0x30.toByte() -> {
                    if (commandApdu.size > 5) {
                        return SW_WRONG_LENGTH
                    }
                    messageDigest.reset()
                    totalBytesReceived = 0
                    chunkCount = 0
                    if (VaultCoreBridge.isAvailable && ensureRustVaultInitialized()) {
                        VaultCoreBridge.nativeResetNfcSessions()
                    }
                    VaultApprovalGate.cancelPending("READER_RESET_SESSION")
                    logHceJson("HCE_RESET_SESSION") {
                        put("status", "OK")
                    }
                    return SW_SUCCESS
                }

                else -> {
                    logHceJson("HCE_UNKNOWN_INS") {
                        put("ins", "%02x".format(ins))
                    }
                    return SW_INS_NOT_SUPPORTED
                }
            }
        }

        logHceJson("HCE_UNKNOWN_CLA") {
            put("cla", "%02x".format(cla))
        }
        return SW_CLA_NOT_SUPPORTED
    }

    /**
     * Handles Tier-2 short APDU frames (`INS = 0x40`, `Lc <= 128`, wire length `<= 134`)
     * carrying serialized `nfc_protocol::NfcEnvelope` CBOR slices into `VaultCoreBridge`.
     */
    private fun handleRustEnvelopeFrameApdu(commandApdu: ByteArray): ByteArray {
        if (commandApdu.size < 6 || commandApdu.size > 134) {
            logHceJson("HCE_RUST_FRAME_REJECTED_LENGTH") {
                put("wire_len", commandApdu.size)
            }
            return SW_WRONG_LENGTH
        }
        val lc = commandApdu[4].toInt() and 0xFF
        if (lc <= 0 || lc > MAX_CHUNK_SIZE) {
            logHceJson("HCE_RUST_FRAME_REJECTED_LC") {
                put("lc", lc)
            }
            return SW_WRONG_LENGTH
        }
        if (commandApdu.size != 5 + lc && commandApdu.size != 5 + lc + 1) {
            return SW_WRONG_LENGTH
        }
        // Only a device the user put into HCE Vault mode accepts signing requests.
        if (!VaultApprovalGate.isArmed()) {
            logHceJson("HCE_RUST_FRAME_REJECTED_VAULT_NOT_ARMED") {
                put("wire_len", commandApdu.size)
            }
            return SW_CONDITIONS_NOT_SATISFIED
        }
        if (!ensureRustVaultInitialized()) {
            return SW_CONDITIONS_NOT_SATISFIED
        }

        val apduHex = commandApdu.joinToString("") { "%02x".format(it) }
        val resStr = VaultCoreBridge.nativeProcessApduFrame(apduHex)
        val resJson = try {
            JSONObject(resStr)
        } catch (_: Throwable) {
            return SW_WRONG_LENGTH
        }

        if (resJson.has("error")) {
            logHceJson("HCE_RUST_FRAME_ERROR") {
                put("error", resJson.optString("error"))
            }
            return SW_WRONG_LENGTH
        }

        val status = resJson.optString("status")
        if (status == "FRAME_ACK" || status == "IN_PROGRESS") {
            logHceJson("HCE_RUST_FRAME_ACCEPTED") {
                put("status", status)
                put("wire_len", commandApdu.size)
                put("lc", lc)
            }
            return SW_SUCCESS
        }

        if (status == "COMPLETE") {
            val sessId = resJson.optString("session_id")
            val reqId = resJson.optString("request_id")
            val payloadHex = resJson.optString("payload_hex")
            val payloadBytes = hexToBytes(payloadHex)
            val payloadSha256 = MessageDigest.getInstance("SHA-256").digest(payloadBytes)
                .joinToString("") { "%02x".format(it) }
            val reqPayloadJson = try {
                JSONObject(String(payloadBytes, Charsets.UTF_8))
            } catch (_: Throwable) {
                logHceJson("HCE_RUST_TX_INVALID_JSON") {
                    put("request_id", reqId)
                }
                return SW_WRONG_LENGTH
            }

            // Fail closed: chain_id and rlp_hex are mandatory; no default network is assumed.
            val rlpHex = reqPayloadJson.optString("rlp_hex").trim()
            if (rlpHex.isEmpty() || !reqPayloadJson.has("chain_id") || reqPayloadJson.optLong("chain_id", -1L) <= 0L) {
                logHceJson("HCE_RUST_TX_REJECTED_MISSING_FIELDS") {
                    put("request_id", reqId)
                    put("has_rlp", rlpHex.isNotEmpty())
                    put("has_chain_id", reqPayloadJson.has("chain_id"))
                }
                return SW_CONDITIONS_NOT_SATISFIED
            }
            val chainId = reqPayloadJson.getLong("chain_id")
            val expectedSigner = reqPayloadJson.optString("expected_signer", MainActivity.PUBLIC_TEST_SIGNER)
            val isEip1559 = rlpHex.removePrefix("0x").startsWith("02", ignoreCase = true)
            val txType = if (isEip1559) "EIP1559" else "LEGACY_EIP155"
            val prepareSymbol = if (isEip1559) {
                "nativePrepareEip1559TxWithTransport"
            } else {
                "nativePrepareLegacyTxWithTransport"
            }
            val prepStr = if (isEip1559) {
                VaultCoreBridge.nativePrepareEip1559TxWithTransport(
                    sessId,
                    reqId,
                    rlpHex,
                    chainId,
                    1 // Transport::Nfc
                )
            } else {
                VaultCoreBridge.nativePrepareLegacyTxWithTransport(
                    sessId,
                    reqId,
                    rlpHex,
                    chainId,
                    1 // Transport::Nfc
                )
            }
            val prepJson = try {
                JSONObject(prepStr)
            } catch (_: Throwable) {
                return SW_CONDITIONS_NOT_SATISFIED
            }

            if (prepJson.has("error") || prepJson.optString("status") == "PolicyDenied") {
                logHceJson("HCE_RUST_TX_POLICY_DENIED") {
                    put("session_id", sessId)
                    put("request_id", reqId)
                    put("tx_type", txType)
                    put("prepare_symbol", prepareSymbol)
                    put("prep_result", prepJson)
                }
                return SW_CONDITIONS_NOT_SATISFIED
            }

            val handleId = prepJson.optString("handle_id")
            val digestHex = extractSigningDigestHex(prepJson)
            prepJson.put("tx_type", txType)
            prepJson.put("prepare_symbol", prepareSymbol)
            prepJson.put("payload_sha256", payloadSha256)
            prepJson.put("expected_signer", expectedSigner)
            prepJson.put("chain_id", chainId)

            val registered = VaultApprovalGate.registerPrepared(
                handleId = handleId,
                sessionId = sessId,
                requestId = reqId,
                summary = prepJson,
                signingDigestHex = digestHex,
                payloadSha256 = payloadSha256,
                chainId = chainId,
                expectedSigner = expectedSigner,
                txType = txType
            )
            if (!registered) {
                return SW_CONDITIONS_NOT_SATISFIED
            }

            preparedInSessionSeq = sessionSeq
            verifiedPeerSessionSeq = sessionSeq

            logHceJson("HCE_RUST_TX_PREPARED") {
                put("session_id", sessId)
                put("request_id", reqId)
                put("handle_id", handleId)
                put("tx_type", txType)
                put("prepare_symbol", prepareSymbol)
                put("payload_sha256", payloadSha256)
                put("expected_signer", expectedSigner)
                put("transport", prepJson.optString("transport"))
                put("digest", digestHex)
                put("awaiting", "LOCAL_VAULT_REVIEW")
            }
            return byteArrayOf(0x01) + SW_SUCCESS
        }

        return SW_WRONG_LENGTH
    }

    private fun extractSigningDigestHex(prepJson: JSONObject): String {
        val arr = prepJson.optJSONArray("raw_signing_digest")
        if (arr != null && arr.length() == 32) {
            val sb = StringBuilder(64)
            for (i in 0 until 32) {
                sb.append("%02x".format(arr.getInt(i) and 0xFF))
            }
            return sb.toString()
        }
        return prepJson.optString("signing_digest").ifEmpty { prepJson.optString("digest") }
    }

    /**
     * `INS = 0x41` review control from the NFC peer:
     *  - `P1 = 0x00` status poll (with mandatory peer/session/request/digest/account binding on Touch 2+)
     *    -> data `[state, frames_hi, frames_lo]` + 9000
     *  - `P1 = 0x01` remote approve -> always rejected with 6982 (approval is local-only)
     *  - `P1 = 0x02` cancel -> 9000 if a pre-sign pending review was cancelled
     */
    private fun handleRustTxDecisionApdu(commandApdu: ByteArray, p1: Byte, p2: Byte): ByteArray {
        val p1Int = p1.toInt() and 0xFF
        val p2Int = p2.toInt() and 0xFF
        return when (p1Int) {
            0x00 -> {
                if (p2Int in 1..15) {
                    if (commandApdu.size < 5) return SW_WRONG_LENGTH
                    val lc = commandApdu[4].toInt() and 0xFF
                    if (lc <= 0 || lc > MAX_CHUNK_SIZE || (commandApdu.size != 5 + lc && commandApdu.size != 5 + lc + 1)) {
                        pendingPeerContextBuffer.reset()
                        return SW_WRONG_LENGTH
                    }
                    if (p2Int == 1) {
                        pendingPeerContextBuffer.reset()
                    }
                    if (pendingPeerContextBuffer.size() + lc > 1024) {
                        pendingPeerContextBuffer.reset()
                        return SW_WRONG_LENGTH
                    }
                    pendingPeerContextBuffer.write(commandApdu, 5, lc)
                    return SW_SUCCESS
                }
                if (p2Int != 0) {
                    return SW_INCORRECT_P1P2
                }
                if (commandApdu.size <= 5 && pendingPeerContextBuffer.size() == 0) {
                    if (sessionSeq != preparedInSessionSeq && sessionSeq != verifiedPeerSessionSeq) {
                        logHceJson("HCE_TOUCH2_CONTEXT_MISMATCH_REJECTED") {
                            put("reason", "Touch 2 status poll requires peer/request/digest/account binding payload")
                            put("session_seq", sessionSeq)
                            put("prepared_session_seq", preparedInSessionSeq)
                        }
                        return SW_SECURITY_STATUS_NOT_SATISFIED
                    }
                    val st = VaultApprovalGate.readerStatus()
                    verifiedPeerSessionSeq = sessionSeq
                    logHceJson("HCE_RUST_TX_STATUS_POLLED") {
                        put("state_code", st[0])
                        put("response_apdu_frames", st[1])
                        put("context_verified", true)
                    }
                    return byteArrayOf(
                        st[0].toByte(),
                        ((st[1] shr 8) and 0xFF).toByte(),
                        (st[1] and 0xFF).toByte()
                    ) + SW_SUCCESS
                }

                if (commandApdu.size > 5) {
                    val lc = commandApdu[4].toInt() and 0xFF
                    val maxAllowedLc = if (pendingPeerContextBuffer.size() > 0) MAX_CHUNK_SIZE else 250
                    if (lc <= 0 || lc > maxAllowedLc || (commandApdu.size != 5 + lc && commandApdu.size != 5 + lc + 1)) {
                        pendingPeerContextBuffer.reset()
                        return SW_WRONG_LENGTH
                    }
                    if (pendingPeerContextBuffer.size() + lc > 1024) {
                        pendingPeerContextBuffer.reset()
                        return SW_WRONG_LENGTH
                    }
                    pendingPeerContextBuffer.write(commandApdu, 5, lc)
                }

                val ctxBytes = pendingPeerContextBuffer.toByteArray()
                pendingPeerContextBuffer.reset()
                val bindingJson = try {
                    JSONObject(String(ctxBytes, Charsets.UTF_8))
                } catch (_: Throwable) {
                    verifiedPeerSessionSeq = -1
                    logHceJson("HCE_TOUCH2_CONTEXT_MISMATCH_REJECTED") {
                        put("reason", "Malformed Touch 2 context binding JSON")
                    }
                    return SW_SECURITY_STATUS_NOT_SATISFIED
                }
                val check = VaultApprovalGate.verifyPeerContextAndPollStatus(bindingJson)
                if (!check.contextOk) {
                    verifiedPeerSessionSeq = -1
                    logHceJson("HCE_TOUCH2_CONTEXT_MISMATCH_REJECTED") {
                        put("reason", check.rejectReason ?: "CONTEXT_MISMATCH")
                        put("session_seq", sessionSeq)
                    }
                    return SW_SECURITY_STATUS_NOT_SATISFIED
                }
                verifiedPeerSessionSeq = sessionSeq
                logHceJson("HCE_RUST_TX_STATUS_POLLED") {
                    put("state_code", check.stateCode)
                    put("response_apdu_frames", check.frameCount)
                    put("context_verified", true)
                    put("session_seq", sessionSeq)
                }
                byteArrayOf(
                    check.stateCode.toByte(),
                    ((check.frameCount shr 8) and 0xFF).toByte(),
                    (check.frameCount and 0xFF).toByte()
                ) + SW_SUCCESS
            }

            0x01 -> {
                if (p2Int != 0 || commandApdu.size > 5) return SW_INCORRECT_P1P2
                logHceJson("HCE_REMOTE_APPROVAL_REJECTED") {
                    put("reason", "Approval must be given on the Vault device UI; NFC peer cannot approve")
                    put("primitive_sign_invocations", safeSignCount())
                }
                SW_SECURITY_STATUS_NOT_SATISFIED
            }

            0x02 -> {
                if (p2Int != 0 || commandApdu.size > 5) return SW_INCORRECT_P1P2
                if (sessionSeq != preparedInSessionSeq && sessionSeq != verifiedPeerSessionSeq) {
                    return SW_SECURITY_STATUS_NOT_SATISFIED
                }
                val cancelled = VaultApprovalGate.cancelFromReader()
                logHceJson("HCE_RUST_TX_READER_CANCEL") {
                    put("cancelled", cancelled)
                    put("primitive_sign_invocations", safeSignCount())
                }
                if (cancelled) SW_SUCCESS else SW_CONDITIONS_NOT_SATISFIED
            }

            else -> SW_INCORRECT_P1P2
        }
    }

    private fun safeSignCount(): Long = try {
        if (VaultCoreBridge.isAvailable) VaultCoreBridge.nativeGetPrimitiveSignCount() else -1L
    } catch (_: Throwable) {
        -1L
    }

    /**
     * Returns the `P1`-th Tier-2 APDU frame of a locally approved signed response (`INS = 0x50`).
     * Requires the current RF `sessionSeq` to have passed peer context verification (`verifiedPeerSessionSeq`).
     */
    private fun handleRustGetResponseFrameApdu(commandApdu: ByteArray, p1: Byte, p2: Byte): ByteArray {
        if (p2 != 0x00.toByte() || commandApdu.size > 5) {
            return SW_INCORRECT_P1P2
        }
        if (sessionSeq != verifiedPeerSessionSeq) {
            logHceJson("HCE_RESPONSE_FETCH_REJECTED_UNVERIFIED_PEER") {
                put("session_seq", sessionSeq)
                put("verified_session_seq", verifiedPeerSessionSeq)
            }
            return SW_SECURITY_STATUS_NOT_SATISFIED
        }
        val idx = p1.toInt() and 0xFF
        val frameBytes = VaultApprovalGate.responseFrame(idx) ?: return SW_CONDITIONS_NOT_SATISFIED
        logHceJson("HCE_RUST_RESPONSE_FRAME_SENT") {
            put("frame_index", idx)
            put("total_frames", VaultApprovalGate.responseFrameCount())
            put("frame_wire_len", frameBytes.size)
            put("session_seq", sessionSeq)
        }
        return frameBytes + SW_SUCCESS
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim().removePrefix("0x")
        val len = clean.length
        val out = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            out[i / 2] = clean.substring(i, i + 2).toInt(16).toByte()
            i += 2
        }
        return out
    }

    override fun onDeactivated(reason: Int) {
        val reasonStr = when (reason) {
            DEACTIVATION_LINK_LOSS -> "DEACTIVATION_LINK_LOSS"
            DEACTIVATION_DESELECTED -> "DEACTIVATION_DESELECTED"
            else -> "UNKNOWN_$reason"
        }
        logHceJson("HCE_DEACTIVATED") {
            put("reason", reasonStr)
        }
        messageDigest.reset()
        totalBytesReceived = 0
        chunkCount = 0
        pendingPeerContextBuffer.reset()
    }
}
