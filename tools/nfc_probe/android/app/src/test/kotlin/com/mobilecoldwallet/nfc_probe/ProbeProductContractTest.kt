package com.mobilecoldwallet.nfc_probe

import android.content.Intent
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class ProbeProductContractTest {

    private lateinit var tempEvidenceDir: File

    @Before
    fun setUp() {
        tempEvidenceDir = Files.createTempDirectory("fcw_nfc_probe_test_").toFile()
        ProbeSessionState.resetForTesting(tempEvidenceDir)
        VaultApprovalGate.resetForTesting()
    }

    /**
     * Direct IsoDep transport wiring MainActivity (Reader) to FcwHostApduService (HCE).
     */
    private class HceBackedIsoDepTransport(
        private val hceService: FcwHostApduService,
        private val onBeforeTransceive: ((Int, ByteArray) -> Unit)? = null
    ) : MainActivity.IsoDepTransport {
        override val maxTransceiveLength: Int = 253
        override var timeout: Int = 5000
        var connected = false
        var closed = false
        var transceiveCount = 0

        override fun connect() {
            connected = true
        }

        override fun close() {
            closed = true
        }

        override fun transceive(commandApdu: ByteArray): ByteArray {
            transceiveCount++
            onBeforeTransceive?.invoke(transceiveCount, commandApdu)
            return hceService.processCommandApdu(commandApdu, null)
        }
    }

    private fun resumedActivity(): MainActivity = MainActivity().apply {
        isActivityResumed = true
        uiThreadPoster = { it.run() }
    }

    private fun sw(resp: ByteArray): Int =
        ((resp[resp.size - 2].toInt() and 0xFF) shl 8) or (resp[resp.size - 1].toInt() and 0xFF)

    /** Simulates the second (Vault) device's user tapping Approve/Reject on its own UI, off the APDU thread. */
    private fun startVaultUser(decision: String, onPending: ((JSONObject) -> Unit)? = null): Thread {
        val pendingLatch = CountDownLatch(1)
        val seen = AtomicReference<JSONObject>()
        VaultApprovalGate.reviewListener = { review ->
            if (review.optString("state") == "PENDING_LOCAL_REVIEW" && seen.compareAndSet(null, review)) {
                pendingLatch.countDown()
            }
        }
        val t = Thread {
            if (!pendingLatch.await(5, TimeUnit.SECONDS)) return@Thread
            val review = seen.get()
            onPending?.invoke(review)
            when (decision) {
                "APPROVE" -> VaultApprovalGate.approveLocally(review.getString("handle_id"), "TEST_VAULT_UI")
                "REJECT" -> VaultApprovalGate.rejectLocally(review.getString("handle_id"), "TEST_VAULT_UI")
                "INVALIDATE_SESSION" -> ProbeSessionState.invalidate("TEST_VAULT_SCREEN_LOCK")
                else -> Unit
            }
        }
        t.start()
        return t
    }

    // ---------------------------------------------------------------------------------------
    // A1 / A3: authenticated debug controller (TestControlGate is the production decision code
    // used by TestControlProvider.call()).
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA1A3_AuthorizedShellControllerActivatesRunAndLiveActivityAdoptsAck() {
        val activity = resumedActivity()
        val before = ProbeSessionState.snapshot()

        val req = TestControlGate.Request(TestControlGate.METHOD_ACTIVATE_RUN, "READER", "shared-run-phase1-001", "phase1")
        val decision = TestControlGate.decide(req, isDebuggableBuild = true, callingUid = 2000, callerHoldsDump = true)
        assertTrue(decision.reason, decision.accepted)

        val ack = TestControlGate.activate(decision, 2000) { snap -> activity.applyAuthenticatedControl(snap) }
        assertTrue(ack.getBoolean("ack"))
        assertEquals("shared-run-phase1-001", ack.getString("run_id"))
        assertEquals("phase1", ack.getString("phase"))
        assertEquals("READER", ack.getString("role"))
        assertTrue(ack.getLong("generation") > before.generation)
        assertTrue(ack.getBoolean("applied_to_activity"))
        assertTrue(ack.getBoolean("activity_resumed"))
        assertTrue(ack.getBoolean("reader_mode_active"))
        assertTrue(ack.getBoolean("session_stable"))
        assertFalse("READER device must not be an armed Vault", ack.getBoolean("vault_armed"))

        // The live activity now runs exactly the identity returned in the ACK.
        assertEquals(ack.getString("run_id"), activity.currentRunId)
        assertEquals(ack.getLong("generation"), activity.currentGeneration)

        val ackEvt = ProbeSessionState.readEventsForRun("shared-run-phase1-001")
            .first { it.optString("event") == "PROBE_CONTROL_ACK" }
        assertEquals(ack.getLong("generation"), ackEvt.getLong("generation"))
        assertEquals("TEST_CONTROL_PROVIDER_UID_2000", ackEvt.getString("trigger_source"))

        // HCE role arms the Vault
        val hceDecision = TestControlGate.decide(
            TestControlGate.Request(TestControlGate.METHOD_ACTIVATE_RUN, "HCE", "shared-run-phase1-002", "phase1"),
            true, 2000, true
        )
        val hceAck = TestControlGate.activate(hceDecision, 2000) { snap -> activity.applyAuthenticatedControl(snap) }
        assertTrue(hceAck.getBoolean("vault_armed"))
        assertFalse(hceAck.getBoolean("reader_mode_active"))
    }

    @Test
    fun testA3_UnauthorizedCallersReleaseBuildAndMalformedRequestsRejectedWithoutStateChange() {
        val initial = ProbeSessionState.activateRun(MainActivity.Role.HCE, "initial-safe-run", "local_ui", "LOCAL_UI")
        val good = TestControlGate.Request(TestControlGate.METHOD_ACTIVATE_RUN, "READER", "attacker-run", "spoofed")

        data class Case(val label: String, val req: TestControlGate.Request, val debuggable: Boolean, val uid: Int, val dump: Boolean)
        val cases = listOf(
            Case("normal third-party app", good, true, 10999, false),
            Case("third-party app that somehow holds DUMP", good, true, 10999, true),
            Case("app's own UID (run-as)", good, true, 10150, false),
            Case("shell UID without DUMP", good, true, 2000, false),
            // Regression for the old TestControlActivity, whose resolveCallingUid() fell back to 2000
            // when the caller was unknown: an unknown/invalid UID must be rejected.
            Case("unknown caller identity", good, true, -1, false),
            Case("release (non-debuggable) build even from shell", good, false, 2000, true),
            Case("lower-case role", good.copy(role = "reader"), true, 2000, true),
            Case("path-like run_id", good.copy(runId = "../../x"), true, 2000, true),
            Case("empty phase", good.copy(phase = ""), true, 2000, true),
            Case("unknown method", good.copy(method = "set_role"), true, 2000, true),
        )
        for (c in cases) {
            val d = TestControlGate.decide(c.req, c.debuggable, c.uid, c.dump)
            assertFalse("${c.label} must be rejected (${d.reason})", d.accepted)
            val snap = ProbeSessionState.snapshot()
            assertEquals(c.label, initial.runId, snap.runId)
            assertEquals(c.label, initial.generation, snap.generation)
            assertEquals(c.label, MainActivity.Role.HCE, snap.role)
        }

        // Intent-based control is gone: MainActivity rejects every control extra, including the
        // legacy internal_sync/token path and the ACTION_TEST_SET_ROLE string.
        val spoofedIntent = object : Intent() {
            override fun getAction(): String = MainActivity.ACTION_TEST_SET_ROLE
            override fun hasExtra(name: String?): Boolean = name in setOf("role", "run_id", "phase", "internal_sync")
            override fun getBooleanExtra(name: String?, defaultValue: Boolean): Boolean = name == "internal_sync"
            override fun getStringExtra(name: String?): String? = when (name) {
                "role" -> "READER"
                "run_id" -> "attacker-injected-run"
                "phase" -> "spoofed"
                else -> null
            }
        }
        assertFalse(MainActivity().handleIntentRole(spoofedIntent, "ON_NEW_INTENT"))
        assertEquals(initial.runId, ProbeSessionState.snapshot().runId)
        assertEquals(initial.generation, ProbeSessionState.snapshot().generation)
    }

    @Test
    fun testA1_ControllerAckReportsNotAppliedWhenSessionMovedBeforeApply() {
        val activity = resumedActivity()
        val decision = TestControlGate.decide(
            TestControlGate.Request(TestControlGate.METHOD_ACTIVATE_RUN, "READER", "race-run", "phase1"), true, 2000, true
        )
        val ack = TestControlGate.activate(decision, 2000) { snap ->
            // e.g. activity paused between activation and UI apply
            ProbeSessionState.invalidate("RACE_ON_PAUSE")
            activity.applyAuthenticatedControl(snap)
        }
        assertTrue(ack.getBoolean("ack"))
        assertFalse("A superseded snapshot must not be reported as applied", ack.getBoolean("applied_to_activity"))
        assertFalse("ACK must expose that the session moved", ack.getBoolean("session_stable"))
    }

    // ---------------------------------------------------------------------------------------
    // A2 / A7 (kept from previous candidate)
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA2_RepeatedStartProbeCreatesFreshRunIdGenerationAndToken() {
        val activity = resumedActivity()

        val snap1 = activity.startProbeSession(requestedPhase = "phase1")
        assertEquals(MainActivity.Role.READER, activity.currentRole)
        assertTrue(activity.isReaderModeActive)

        val snap2 = activity.startProbeSession(requestedPhase = "phase1")
        assertNotEquals("Repeated Start Probe must create a fresh run_id", snap1.runId, snap2.runId)
        assertTrue("Repeated Start Probe must increment generation", snap2.generation > snap1.generation)
        assertTrue("Repeated Start Probe must rotate activeToken", snap2.activeToken > snap1.activeToken)
    }

    @Test
    fun testA2_OverlappingTagCallbacksSingleFlightAndCancelMidTransceive() {
        val activity = resumedActivity()
        val hce = FcwHostApduService()

        val snap = activity.startProbeSession(requestedRunId = "run-overlap-test", requestedPhase = "phase1")
        val enteredTransceiveLatch = CountDownLatch(1)
        val proceedTransceiveLatch = CountDownLatch(1)
        val secondCallbackRejected = AtomicBoolean(false)

        val slowTransport = HceBackedIsoDepTransport(hce) { count, _ ->
            if (count == 4) {
                enteredTransceiveLatch.countDown()
                proceedTransceiveLatch.await(5, TimeUnit.SECONDS)
            }
        }

        val worker1 = Thread {
            activity.executeReaderSession(slowTransport)
        }
        worker1.start()

        assertTrue("First session must enter transceive", enteredTransceiveLatch.await(5, TimeUnit.SECONDS))

        val overlappingTransport = HceBackedIsoDepTransport(hce)
        activity.executeReaderSession(overlappingTransport)
        assertTrue("Overlapping transport must be closed and rejected", overlappingTransport.closed)
        assertEquals("Overlapping transport must perform zero transceives", 0, overlappingTransport.transceiveCount)

        val midEvents = ProbeSessionState.readEventsForRun(snap.runId)
        if (midEvents.any { it.optString("event") == "TAG_CALLBACK_REJECTED_SINGLE_FLIGHT_BUSY" }) {
            secondCallbackRejected.set(true)
        }
        assertTrue("Must record TAG_CALLBACK_REJECTED_SINGLE_FLIGHT_BUSY", secondCallbackRejected.get())

        activity.cancelProbeSession("TEST_MID_FLIGHT_CANCEL")
        proceedTransceiveLatch.countDown()
        worker1.join(5000)

        assertTrue("Original transport must be closed after cancel", slowTransport.closed)
        assertNull("Cancelled stale session must not publish a passing lastRunSummary", activity.lastRunSummary)

        val finalEvents = ProbeSessionState.readEventsForRun(snap.runId)
        assertTrue(
            "Must record STALE_SESSION_ABORTED when cancelled mid-transceive",
            finalEvents.any { it.optString("event") == "STALE_SESSION_ABORTED" }
        )
    }

    @Test
    fun testA7_FullProbeLoopProducesPersistentJsonlAndJsonReportsOnBothReaderAndHCE() {
        val activity = resumedActivity()
        val hce = FcwHostApduService()

        val snap = activity.startProbeSession(
            requestedRunId = "run-full-persistence-01",
            requestedPhase = "phase1",
            triggerSource = "TEST_HARNESS"
        )
        val transport = HceBackedIsoDepTransport(hce)
        activity.executeReaderSession(transport)

        val summary = activity.lastRunSummary
        assertNotNull("Completed probe run must publish summary", summary)
        assertTrue("All positive and negative probe assertions must pass", summary!!.getBoolean("all_passed"))
        assertEquals("run-full-persistence-01", summary.getString("run_id"))
        assertEquals("phase1", summary.getString("phase"))
        assertEquals(snap.generation, summary.getLong("generation"))

        val jsonlFile = File(tempEvidenceDir, "events_run-full-persistence-01.jsonl")
        val readerReportFile = File(tempEvidenceDir, "report_reader_run-full-persistence-01.json")
        val hceReportFile = File(tempEvidenceDir, "report_hce_run-full-persistence-01.json")

        assertTrue("Persistent JSONL event log must exist", jsonlFile.isFile)
        assertTrue("Persistent Reader JSON report must exist", readerReportFile.isFile)
        assertTrue("Persistent HCE JSON report must exist", hceReportFile.isFile)

        val persistedEvents = ProbeSessionState.readEventsForRun("run-full-persistence-01")
        assertTrue("Must record both Reader and HCE events", persistedEvents.size >= 20)

        var prevSeq = 0L
        for (evt in persistedEvents) {
            val seq = evt.getLong("event_seq")
            assertTrue("event_seq must be strictly increasing ($seq > $prevSeq)", seq > prevSeq)
            prevSeq = seq
            assertEquals("run-full-persistence-01", evt.getString("run_id"))
            assertEquals("phase1", evt.getString("phase"))
        }

        // Byte lengths the runner cross-checks against HCE digests
        val byName = persistedEvents.associateBy { it.optString("event") }
        assertEquals(32, byName.getValue("TEST_32B").getInt("bytes"))
        assertEquals(512, byName.getValue("TEST_512B").getInt("bytes"))
        assertEquals(4096, byName.getValue("TEST_4KIB").getInt("bytes"))

        val readerReport = JSONObject(readerReportFile.readText(Charsets.UTF_8))
        assertTrue(readerReport.getBoolean("all_passed"))
        assertTrue(readerReport.getJSONArray("events").length() >= 20)
    }

    // ---------------------------------------------------------------------------------------
    // A4 / A6: NFC request -> LOCAL Vault review -> Rust core signature -> NFC response ->
    // watch-only verification. The NFC peer can never approve.
    // ---------------------------------------------------------------------------------------

    private val rawRlpHex = MainActivity.PUBLIC_TEST_TX_RLP_HEX
    private val expectedSigner = MainActivity.PUBLIC_TEST_SIGNER

    private fun armVaultAsSecondDevice() {
        // In this single-JVM harness both "devices" share ProbeSessionState; arming here stands in
        // for the Vault phone's user selecting HCE Vault Mode.
        assertTrue("VaultCoreBridge JNI must load host vault_ffi", VaultCoreBridge.isAvailable)
        assertTrue("WalletCoreBridge JNI must load host wallet_ffi", WalletCoreBridge.isAvailable)
        assertTrue(VaultApprovalGate.ensureVaultInitialized())
        VaultApprovalGate.setArmed(true, "TEST_SECOND_DEVICE_HCE_MODE")
    }

    @Test
    fun testA4A6_LocalVaultApprovalProducesVerifiedNfcSignatureExactlyOnce() {
        armVaultAsSecondDevice()
        val activity = MainActivity()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()
        val shownDigest = AtomicReference<String>()

        val vaultUser = startVaultUser("APPROVE") { review -> shownDigest.set(review.optString("signing_digest")) }
        val result = activity.executeRustTransactionSession(
            transport = HceBackedIsoDepTransport(hce),
            sessionId = "sess-jvm-approve-01",
            requestId = "req-jvm-approve-01",
            rawRlpHex = rawRlpHex,
            chainId = MainActivity.PUBLIC_TEST_CHAIN_ID,
            expectedAddress = expectedSigner,
            approvalTimeoutMs = 5_000,
            pollIntervalMs = 5
        )
        vaultUser.join(5000)

        assertTrue("Watch-only wallet must verify the NFC response: $result", result.optBoolean("verified"))
        assertEquals("VERIFIED", result.optString("status"))
        assertEquals(expectedSigner.lowercase(), result.optString("recovered_address").lowercase())
        assertTrue(result.getInt("max_capdu_wire_len") <= 134)
        assertTrue(result.getInt("max_lc") <= 128)
        assertTrue("Reader must have polled while awaiting local approval", result.getInt("status_polls") >= 1)
        assertEquals(64, shownDigest.get().length)
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
    }

    @Test
    fun testA4A6_RemoteApproveApduIsRejectedAndNeverSigns() {
        armVaultAsSecondDevice()
        val activity = MainActivity()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()
        val remoteApproveSw = AtomicReference<Int>()
        val statusAfterRemote = AtomicReference<Int>()

        // Old candidate: Reader sent 80 41 01 00 and the HCE signed. Now the peer tries the same
        // right before its first status poll, and no local user ever approves.
        val result = activity.executeRustTransactionSession(
            transport = HceBackedIsoDepTransport(hce),
            sessionId = "sess-jvm-remote-02",
            requestId = "req-jvm-remote-02",
            rawRlpHex = rawRlpHex,
            chainId = MainActivity.PUBLIC_TEST_CHAIN_ID,
            expectedAddress = expectedSigner,
            approvalTimeoutMs = 60,
            pollIntervalMs = 5,
            transceiver = { apdu, step ->
                if (step == "TX_STATUS_POLL" && remoteApproveSw.get() == null) {
                    val r = hce.processCommandApdu(byteArrayOf(0x80.toByte(), 0x41, 0x01, 0x00, 0x00), null)
                    remoteApproveSw.set(sw(r))
                    val st = hce.processCommandApdu(byteArrayOf(0x80.toByte(), 0x41, 0x00, 0x00, 0x00), null)
                    statusAfterRemote.set(st[0].toInt() and 0xFF)
                }
                hce.processCommandApdu(apdu, null)
            }
        )

        assertEquals("Remote approve must be refused with 6982", 0x6982, remoteApproveSw.get())
        assertEquals("Review must still be pending after remote approve", VaultApprovalGate.STATE_PENDING, statusAfterRemote.get())
        assertEquals("APPROVAL_TIMEOUT_CANCELLED", result.optString("status"))
        assertEquals("9000", result.optString("cancel_sw"))
        assertFalse(result.optBoolean("verified"))
        assertEquals("No signing primitive may run without local approval", countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())
        assertNull("No response frame may be released", hce.processCommandApdu(byteArrayOf(0x80.toByte(), 0x50, 0x00, 0x00, 0x00), null).takeIf { sw(it) == 0x9000 })
    }

    @Test
    fun testA4A6_LocalRejectReaderCancelAndSessionChangeAllSignZeroTimes() {
        armVaultAsSecondDevice()
        val activity = MainActivity()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        val rejecter = startVaultUser("REJECT")
        val rejected = activity.executeRustTransactionSession(
            HceBackedIsoDepTransport(hce), "sess-jvm-reject-03", "req-jvm-reject-03", rawRlpHex,
            MainActivity.PUBLIC_TEST_CHAIN_ID, expectedSigner, approvalTimeoutMs = 5_000, pollIntervalMs = 5
        )
        rejecter.join(5000)
        assertEquals("REJECTED_BY_VAULT_USER", rejected.optString("status"))

        val cancelled = activity.executeRustTransactionSession(
            HceBackedIsoDepTransport(hce), "sess-jvm-cancel-04", "req-jvm-cancel-04", rawRlpHex,
            MainActivity.PUBLIC_TEST_CHAIN_ID, expectedSigner, cancelInsteadOfWaiting = true
        )
        assertEquals("CANCELLED", cancelled.optString("status"))
        assertEquals("9000", cancelled.optString("cancel_sw"))

        val locker = startVaultUser("INVALIDATE_SESSION")
        val sessionChanged = activity.executeRustTransactionSession(
            HceBackedIsoDepTransport(hce), "sess-jvm-lock-05", "req-jvm-lock-05", rawRlpHex,
            MainActivity.PUBLIC_TEST_CHAIN_ID, expectedSigner, approvalTimeoutMs = 5_000, pollIntervalMs = 5
        )
        locker.join(5000)
        assertEquals("VAULT_CANCELLED", sessionChanged.optString("status"))

        assertEquals(countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())
    }

    @Test
    fun testA4A6_UnarmedDeviceAndMissingChainIdAreRefusedBeforePrepare() {
        assertTrue(VaultApprovalGate.ensureVaultInitialized())
        VaultApprovalGate.setArmed(false, "TEST_READER_ROLE_DEVICE")
        val activity = MainActivity()
        val hce = FcwHostApduService()
        val result = activity.executeRustTransactionSession(
            HceBackedIsoDepTransport(hce), "sess-jvm-unarmed-06", "req-jvm-unarmed-06", rawRlpHex,
            MainActivity.PUBLIC_TEST_CHAIN_ID, expectedSigner, approvalTimeoutMs = 50, pollIntervalMs = 5
        )
        assertEquals("REQUEST_FRAME_REJECTED", result.optString("status"))
        assertTrue(result.optString("error").contains("6985"))
        assertEquals("NONE", VaultApprovalGate.currentReviewJson().optString("state"))

        // Armed Vault, but the request omits chain_id: old HCE defaulted to Sepolia; now refused (6985).
        VaultApprovalGate.setArmed(true, "TEST_SECOND_DEVICE_HCE_MODE")
        val noChainPayloadHex = JSONObject().put("rlp_hex", rawRlpHex).toString().toByteArray(Charsets.UTF_8)
            .joinToString("") { "%02x".format(it) }
        val chunks = org.json.JSONArray(
            WalletCoreBridge.nativeChunkPayload("sess-jvm-nochain-06b", "req-jvm-nochain-06b", 4, noChainPayloadHex, 120)
        )
        assertEquals(0x9000, sw(hce.processCommandApdu(byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + MainActivity.AID_BYTES + byteArrayOf(0x00), null)))
        var lastSw = 0
        for (i in 0 until chunks.length()) {
            val frames = chunks.getJSONObject(i).getJSONArray("apdu_frames_hex")
            for (j in 0 until frames.length()) {
                val hex = frames.getString(j)
                val bytes = ByteArray(hex.length / 2) { k -> hex.substring(2 * k, 2 * k + 2).toInt(16).toByte() }
                lastSw = sw(hce.processCommandApdu(bytes, null))
            }
        }
        assertEquals("Request without chain_id must be refused", 0x6985, lastSw)
        assertEquals("NONE", VaultApprovalGate.currentReviewJson().optString("state"))
    }

    @Test
    fun testA4A6_ProductTagPathRunsGuardedTxFlowAndPersistsReport() {
        val activity = resumedActivity()
        val snap = activity.startTxSession(requestedRunId = "run-tx-product-07", requestedPhase = "tx1")
        assertEquals(MainActivity.ReaderMode.RUST_TX, activity.readerMode)
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        val vaultUser = startVaultUser("APPROVE")
        val result = activity.executeRustTxReaderSession(
            HceBackedIsoDepTransport(hce), approvalTimeoutMs = 5_000, pollIntervalMs = 5
        )
        vaultUser.join(5000)

        assertNotNull(result)
        assertEquals("VERIFIED", result!!.optString("status"))
        assertEquals("run-tx-product-07", result.getString("run_id"))
        assertEquals(snap.generation, result.getLong("generation"))
        assertEquals("NFC_ISODEP_HCE", result.getString("transport"))
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
        assertEquals(result.toString(), activity.lastTxResult.toString())

        val report = JSONObject(File(tempEvidenceDir, "report_reader_run-tx-product-07.json").readText())
        assertEquals("VERIFIED", report.getString("status"))
        val events = ProbeSessionState.readEventsForRun("run-tx-product-07").map { it.optString("event") }
        for (required in listOf("TX_TAG_DISCOVERED", "HCE_RUST_TX_PREPARED", "VAULT_REVIEW_PENDING",
                "VAULT_LOCAL_APPROVED_AND_SIGNED", "HCE_RUST_RESPONSE_FRAME_SENT", "RUST_TX_COMPLETE")) {
            assertTrue("missing $required in $events", events.contains(required))
        }
    }

    @Test
    fun testA2A4_CancelDuringApprovalWaitAbortsReaderAndNeverSigns() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-cancel-08", requestedPhase = "tx1")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        val polls = java.util.concurrent.atomic.AtomicInteger(0)
        val result = activity.executeRustTxReaderSession(
            HceBackedIsoDepTransport(hce) { _, apdu ->
                if (apdu.size >= 3 && apdu[1] == 0x41.toByte() && apdu[2] == 0x00.toByte() && polls.incrementAndGet() == 2) {
                    activity.cancelProbeSession("USER_CANCEL_WHILE_WAITING")
                }
            },
            approvalTimeoutMs = 5_000,
            pollIntervalMs = 5
        )
        assertNotNull(result)
        assertEquals("ABORTED_STALE", result!!.optString("status"))
        assertNull("Stale result must not be published to UI", activity.lastTxResult)
        assertEquals("CANCELLED", VaultApprovalGate.currentReviewJson().optString("state"))
        assertEquals(countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())
    }

    // ---------------------------------------------------------------------------------------
    // FCW-H2-D359879-RECHECK Section 二: Genuine Two-Tap & Three-Tap NFC Transaction Flow
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA4A6_GenuineTwoTapNfcTransactionFlow_Touch1Disconnect_LocalVaultApprove_Touch2CollectAndVerify() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-2tap-01", requestedPhase = "tx_2tap")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Touch 1: Deliver request over IsoDep #1 and disconnect cleanly without waiting in-field
        val touch1Transport = HceBackedIsoDepTransport(hce)
        val touch1Res = activity.executeRustTxReaderSession(touch1Transport)
        assertNotNull(touch1Res)
        assertTrue("Touch 1 transport must connect", touch1Transport.connected)
        assertTrue("Touch 1 transport must close cleanly after Touch 1", touch1Transport.closed)
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res!!.optString("status"))
        assertEquals(1, touch1Res.optInt("touch_count"))
        assertTrue(touch1Res.optBoolean("request_delivered"))
        assertFalse(touch1Res.optBoolean("verified"))
        assertEquals("Zero signatures during Touch 1", countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Physical RF link loss between Touch 1 and Touch 2 must NOT cancel the pending review
        hce.onDeactivated(android.nfc.cardemulation.HostApduService.DEACTIVATION_LINK_LOSS)
        val pendingReview = VaultApprovalGate.currentReviewJson()
        assertEquals("PENDING_LOCAL_REVIEW", pendingReview.optString("state"))
        assertEquals("PRE_SIGN_PENDING", pendingReview.optString("signing_fact_state"))
        assertEquals(touch1Res.getString("request_id"), pendingReview.getString("request_id"))
        assertEquals(touch1Res.getString("signing_digest"), pendingReview.getString("signing_digest"))

        // Offline local review and approval on the Vault screen
        val approveOut = VaultApprovalGate.approveLocallyWithReviewSnapshot(pendingReview, "TEST_VAULT_LOCAL_UI")
        assertTrue("Local approval must succeed: $approveOut", approveOut.optBoolean("approved"))
        assertEquals("SIGNED_AWAITING_DELIVERY", approveOut.optString("signing_fact_state"))
        assertTrue(approveOut.optBoolean("signed_fact_recorded"))
        assertEquals("Exactly 1 primitive sign after local approval", countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Touch 2: Reconnect with a brand-new IsoDep #2, verify peer/request/digest/account context,
        // fetch cached signed response frames (INS=0x50), and verify against the retained PendingWalletRequest
        val touch2Transport = HceBackedIsoDepTransport(hce)
        val touch2Res = activity.executeRustTxReaderSession(touch2Transport)
        assertNotNull(touch2Res)
        assertTrue("Touch 2 transport must connect", touch2Transport.connected)
        assertTrue("Touch 2 transport must close", touch2Transport.closed)
        assertTrue("Touch 2 must verify signature: $touch2Res", touch2Res!!.optBoolean("verified"))
        assertEquals("VERIFIED", touch2Res.optString("status"))
        assertEquals(2, touch2Res.optInt("touch_count"))
        assertEquals("Touch 2 must reuse Touch 1 request_id without re-sending request",
            touch1Res.getString("request_id"), touch2Res.getString("request_id"))
        assertEquals("Touch 2 must reuse Touch 1 session_id",
            touch1Res.getString("session_id"), touch2Res.getString("session_id"))
        assertEquals(expectedSigner.lowercase(), touch2Res.optString("recovered_address").lowercase())
        assertEquals("Still only 1 primitive sign across Touch 1 + Touch 2",
            countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
        assertEquals("SIGNED_DELIVERED", VaultApprovalGate.currentReviewJson().optString("signing_fact_state"))
    }

    @Test
    fun testA4A6_ThreeTapRecovery_Touch2InterruptedMidFetch_Touch3CompletesWithoutResigning() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-3tap-02", requestedPhase = "tx_3tap")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Touch 1: Send request and disconnect
        val touch1Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res.optString("status"))
        assertEquals(1, touch1Res.optInt("touch_count"))

        // Local Vault approval
        val review = VaultApprovalGate.currentReviewJson()
        val approveOut = VaultApprovalGate.approveLocallyWithReviewSnapshot(review, "TEST_VAULT_LOCAL_UI")
        assertTrue(approveOut.optBoolean("approved"))
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Touch 2: Interrupted mid-fetch of INS=0x50 (succeeds on frame 0, throws IOException on frame 1)
        val touch2Transport = HceBackedIsoDepTransport(hce) { _, apdu ->
            if (apdu.size >= 3 && apdu[1] == 0x50.toByte() && apdu[2] == 0x01.toByte()) {
                throw java.io.IOException("Simulated RF link loss mid-response on Touch 2")
            }
        }
        val touch2Res = activity.executeRustTxReaderSession(touch2Transport)!!
        assertEquals("TOUCH_2_INTERRUPTED_RETRY_READY", touch2Res.optString("status"))
        assertFalse(touch2Res.optBoolean("verified"))
        assertEquals(2, touch2Res.optInt("touch_count"))
        assertEquals(1, touch2Res.optInt("fetched_frames_before_interrupt"))
        hce.onDeactivated(android.nfc.cardemulation.HostApduService.DEACTIVATION_LINK_LOSS)

        // Vault still retains the signed response cache and does NOT re-sign
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
        assertEquals("SIGNED_AWAITING_DELIVERY", VaultApprovalGate.currentReviewJson().optString("signing_fact_state"))

        // Touch 3: Reconnects, resets only the incomplete transport assembler, fetches cached frames, and verifies
        val touch3Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertTrue("Touch 3 must complete verification: $touch3Res", touch3Res.optBoolean("verified"))
        assertEquals("VERIFIED", touch3Res.optString("status"))
        assertEquals(3, touch3Res.optInt("touch_count"))
        assertEquals(touch1Res.getString("request_id"), touch3Res.getString("request_id"))
        assertEquals("Still only 1 primitive sign across all 3 touches",
            countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
        assertEquals("SIGNED_DELIVERED", VaultApprovalGate.currentReviewJson().optString("signing_fact_state"))
    }

    @Test
    fun testA4A6_Touch2NegativeCases_Unapproved_MismatchedPeerContext_Rejected_And_Expired() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-2tap-neg-03", requestedPhase = "tx_2tap_neg")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Touch 1
        val touch1Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res.optString("status"))
        hce.onDeactivated(android.nfc.cardemulation.HostApduService.DEACTIVATION_LINK_LOSS)

        // 1. Touch 2 before Vault user approves -> STILL_PENDING_LOCAL_REVIEW
        val unapprovedTouch2 = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("STILL_PENDING_LOCAL_REVIEW", unapprovedTouch2.optString("status"))
        assertFalse(unapprovedTouch2.optBoolean("verified"))

        // 2. Mismatched peer/session/request/digest/account context on follow-up touch -> 6982 PEER_CONTEXT_MISMATCH_REJECTED
        val validCtx = JSONObject().apply {
            put("session_id", touch1Res.getString("session_id"))
            put("request_id", touch1Res.getString("request_id"))
            put("payload_sha256", touch1Res.getString("payload_sha256"))
            put("signing_digest", touch1Res.getString("signing_digest"))
            put("chain_id", MainActivity.PUBLIC_TEST_CHAIN_ID)
            put("expected_signer", expectedSigner)
        }
        val mismatchMutations = listOf(
            "session_id" to "nfc-wrong-session",
            "request_id" to "req-wrong-request",
            "payload_sha256" to "ff".repeat(32),
            "signing_digest" to "aa".repeat(32),
            "chain_id" to 1L,
            "expected_signer" to "0x1111111111111111111111111111111111111111"
        )
        for ((field, badVal) in mismatchMutations) {
            val badCtx = JSONObject(validCtx.toString()).put(field, badVal)
            val badRes = activity.executeRustTxReaderSession(
                HceBackedIsoDepTransport(hce),
                peerContextOverride = badCtx
            )!!
            assertEquals("Mismatch on $field must be rejected", "PEER_CONTEXT_MISMATCH_REJECTED", badRes.optString("status"))
            assertEquals("6982", badRes.optString("error_sw"))
            assertFalse(badRes.optBoolean("verified"))
        }

        // Direct INS=0x50 on a new RF session without context verification must be rejected with 6982
        val selResp = hce.processCommandApdu(
            byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, 0x05) + MainActivity.AID_BYTES + byteArrayOf(0x00), null
        )
        assertEquals(0x9000, sw(selResp))
        val unverifiedFetch = hce.processCommandApdu(byteArrayOf(0x80.toByte(), 0x50, 0x00, 0x00, 0x00), null)
        assertEquals(0x6982, sw(unverifiedFetch))

        // 3. Vault user rejects locally -> Touch 2 receives REJECTED_BY_VAULT_USER
        val handleId = VaultApprovalGate.currentReviewJson().getString("handle_id")
        assertTrue(VaultApprovalGate.rejectLocally(handleId, "TEST_VAULT_REJECT"))
        val rejectedTouch2 = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("REJECTED_BY_VAULT_USER", rejectedTouch2.optString("status"))
        assertFalse(rejectedTouch2.optBoolean("verified"))

        // 4. Expired pending review on Vault -> Touch 2 receives VAULT_CANCELLED
        activity.startTxSession(requestedRunId = "run-tx-2tap-exp-04", requestedPhase = "tx_2tap_exp")
        armVaultAsSecondDevice()
        var fakeNow = 10_000L
        VaultApprovalGate.clock = { fakeNow }
        val expTouch1 = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", expTouch1.optString("status"))
        fakeNow += VaultApprovalGate.PENDING_TTL_MS + 1_000L
        val expTouch2 = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("VAULT_CANCELLED", expTouch2.optString("status"))
        assertFalse(expTouch2.optBoolean("verified"))
        assertEquals(countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())
    }

    // ---------------------------------------------------------------------------------------
    // FCW-H2-D359879-RECHECK Section 三: Preserve Signed Facts Across Cancel/Background + UI Races
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA2A4_PreserveSignedFactsAcrossPauseCancelAndDeactivation_AndBlockResigning() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-signed-fact-05", requestedPhase = "tx_fact")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Touch 1 + Local approval
        val touch1Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res.optString("status"))
        val review = VaultApprovalGate.currentReviewJson()
        val handleId = review.getString("handle_id")
        val reqId = review.getString("request_id")
        val approveOut = VaultApprovalGate.approveLocallyWithReviewSnapshot(review, "TEST_VAULT_UI")
        assertTrue(approveOut.optBoolean("approved"))
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Ambient RF link loss, onPause cancelPending, and Reader cancel (INS=0x41 P1=0x02) AFTER signing
        // MUST NOT overwrite state to CANCELLED or PRE_SIGN_CANCELLED or wipe response cache!
        hce.onDeactivated(android.nfc.cardemulation.HostApduService.DEACTIVATION_LINK_LOSS)
        VaultApprovalGate.cancelPending("SESSION_INVALIDATED_ON_PAUSE")
        assertFalse("Reader cancel must be refused after signing", VaultApprovalGate.cancelFromReader())

        val afterCancelReview = VaultApprovalGate.currentReviewJson()
        assertEquals("APPROVED_SIGNED", afterCancelReview.optString("state"))
        assertEquals("SIGNED_AWAITING_DELIVERY", afterCancelReview.optString("signing_fact_state"))
        assertTrue("signed_fact_recorded must remain true", afterCancelReview.optBoolean("signed_fact_recorded"))
        assertTrue("Cached response frames must remain available for Touch 2", afterCancelReview.optInt("response_apdu_frames") > 0)

        // Attempting to approve the same handle again or re-register the same requestId/handleId must be blocked
        val secondApprove = VaultApprovalGate.approveLocally(handleId, "TEST_VAULT_UI_DUPLICATE")
        assertFalse(secondApprove.optBoolean("approved"))
        assertFalse(
            "Re-registering an already-signed requestId must be refused",
            VaultApprovalGate.registerPrepared(
                handleId = "new-handle-same-req",
                sessionId = touch1Res.getString("session_id"),
                requestId = reqId,
                summary = JSONObject(),
                signingDigestHex = touch1Res.getString("signing_digest")
            )
        )
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Touch 2 delivers the signed response and transitions to SIGNED_DELIVERED
        val touch2Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertTrue(touch2Res.optBoolean("verified"))
        assertEquals("SIGNED_DELIVERED", VaultApprovalGate.currentReviewJson().optString("signing_fact_state"))
        assertEquals(1, VaultApprovalGate.getLastSignedFactJson().optInt("delivery_count"))

        // Explicit user discard transitions to SIGNED_DISCARDED_BY_USER while preserving signed_fact_recorded=true
        assertTrue(VaultApprovalGate.discardSignedResponseByUser(handleId, "USER_EXPLICIT_DISCARD"))
        val afterDiscard = VaultApprovalGate.currentReviewJson()
        assertEquals("SIGNED_DISCARDED_BY_USER", afterDiscard.optString("state"))
        assertEquals("SIGNED_DISCARDED_BY_USER", afterDiscard.optString("signing_fact_state"))
        assertTrue(afterDiscard.optBoolean("signed_fact_recorded"))
        assertEquals(0, afterDiscard.optInt("response_apdu_frames"))
    }

    @Test
    fun testA2A4_ExternalSignOutcomeUnknownPreservesFactAndBlocksCancel() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-unknown-06", requestedPhase = "tx_unknown")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()

        val touch1Res = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res.optString("status"))
        val review = VaultApprovalGate.currentReviewJson()
        val handleId = review.getString("handle_id")

        VaultApprovalGate.afterSignDispatchTestHook = {
            JSONObject().put("status", "OUTCOME_UNKNOWN").put("error", "SigningOutcomeUnknown").toString()
        }
        val out = VaultApprovalGate.approveLocallyWithReviewSnapshot(review, "TEST_VAULT_UI")
        assertFalse(out.optBoolean("approved"))
        assertEquals("EXTERNAL_SIGN_OUTCOME_UNKNOWN", out.optString("signing_fact_state"))
        assertTrue(out.optBoolean("signed_fact_recorded"))

        // Subsequent cancelPending must NOT overwrite EXTERNAL_SIGN_OUTCOME_UNKNOWN into PRE_SIGN_CANCELLED
        VaultApprovalGate.cancelPending("SESSION_INVALIDATED_ON_PAUSE")
        val current = VaultApprovalGate.currentReviewJson()
        assertEquals("EXTERNAL_SIGN_OUTCOME_UNKNOWN", current.optString("state"))
        assertEquals("EXTERNAL_SIGN_OUTCOME_UNKNOWN", current.optString("signing_fact_state"))
        assertTrue(current.optBoolean("signed_fact_recorded"))
        assertFalse(VaultApprovalGate.approveLocally(handleId, "RETRY").optBoolean("approved"))
    }

    @Test
    fun testA2A4_UiReviewRaceProtection_SupersededRequestAndMismatchedIdentityRejectedWithoutSigning() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-race-07", requestedPhase = "tx_race")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Request A arrives
        val touch1A = activity.executeRustTxReaderSession(HceBackedIsoDepTransport(hce))!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1A.optString("status"))
        val staleUiSnapshotA = VaultApprovalGate.currentReviewJson()
        val seqA = staleUiSnapshotA.getLong("review_seq")

        // Before the user taps Approve on Request A, Request B arrives and supersedes Request A
        val regB = JSONObject(
            WalletCoreBridge.nativeRegisterPendingTx("sess-race-B", "req-race-B", rawRlpHex, MainActivity.PUBLIC_TEST_CHAIN_ID, expectedSigner)
        )
        val prepB = JSONObject(
            VaultCoreBridge.nativePrepareLegacyTxWithTransport("sess-race-B", "req-race-B", rawRlpHex, MainActivity.PUBLIC_TEST_CHAIN_ID, 1)
        )
        assertTrue(
            VaultApprovalGate.registerPrepared(
                handleId = prepB.getString("handle_id"),
                sessionId = "sess-race-B",
                requestId = "req-race-B",
                summary = prepB,
                signingDigestHex = regB.optString("signing_digest").ifEmpty { regB.getString("expected_digest") },
                payloadSha256 = "bb".repeat(32),
                chainId = MainActivity.PUBLIC_TEST_CHAIN_ID,
                expectedSigner = expectedSigner,
                txType = "LEGACY_EIP155"
            )
        )
        val activeSnapshotB = VaultApprovalGate.currentReviewJson()
        assertTrue(activeSnapshotB.getLong("review_seq") > seqA)

        // Race 1: User clicks Approve with stale snapshot A
        val resStaleA = VaultApprovalGate.approveLocallyWithReviewSnapshot(staleUiSnapshotA, "STALE_UI_CLICK_A")
        assertFalse("Stale snapshot A must not approve: $resStaleA", resStaleA.optBoolean("approved"))
        assertEquals(countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Race 2: Tampered/raced UI call passing B's handle_id but A's review_seq / request_id / payload_sha256
        val hybridSnapshot = JSONObject(activeSnapshotB.toString()).put("review_seq", seqA)
        val resHybrid = VaultApprovalGate.approveLocallyWithReviewSnapshot(hybridSnapshot, "RACED_UI_CLICK")
        assertFalse("Mismatched review_seq must be rejected", resHybrid.optBoolean("approved"))
        assertEquals("REVIEW_IDENTITY_MISMATCH_OR_SUPERSEDED", resHybrid.optString("reason"))
        assertEquals(countBefore, VaultCoreBridge.nativeGetPrimitiveSignCount())

        // Valid approval with complete matching snapshot B succeeds
        val resValidB = VaultApprovalGate.approveLocallyWithReviewSnapshot(activeSnapshotB, "VALID_UI_CLICK_B")
        assertTrue(resValidB.optBoolean("approved"))
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())
    }

    // ---------------------------------------------------------------------------------------
    // FCW-H2-D359879-RECHECK Section 五 Part C: EIP-1559 vs Legacy Symbol Alignment
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA5PartC_Eip1559Type2TransactionUsesEip1559PrepareSymbolAndVerifiesEndToEnd() {
        val activity = resumedActivity()
        activity.startTxSession(requestedRunId = "run-tx-eip1559-08", requestedPhase = "tx_eip1559")
        armVaultAsSecondDevice()
        val hce = FcwHostApduService()
        val countBefore = VaultCoreBridge.nativeGetPrimitiveSignCount()

        // Valid canonical 9-field unsigned EIP-1559 (0x02) Sepolia transfer to 0x9858effd232b4033e47d90003d41ec34ecaeda94 (whitelisted recipient & chain)
        val eip1559UnsignedHex =
            "02f183aa36a780843b9aca008477359400825208949858effd232b4033e47d90003d41ec34ecaeda9487038d7ea4c6800080c0"

        val touch1Res = activity.executeRustTxReaderSession(
            HceBackedIsoDepTransport(hce),
            rawRlpHex = eip1559UnsignedHex,
            chainId = MainActivity.PUBLIC_TEST_CHAIN_ID,
            expectedAddress = expectedSigner
        )!!
        assertEquals("AWAITING_VAULT_APPROVAL_TOUCH_2", touch1Res.optString("status"))

        val review = VaultApprovalGate.currentReviewJson()
        assertEquals("EIP1559", review.optString("tx_type"))
        assertEquals("nativePrepareEip1559TxWithTransport", review.optJSONObject("summary")?.optString("prepare_symbol"))

        assertTrue(VaultApprovalGate.approveLocallyWithReviewSnapshot(review, "TEST_VAULT_EIP1559").optBoolean("approved"))
        assertEquals(countBefore + 1, VaultCoreBridge.nativeGetPrimitiveSignCount())

        val touch2Res = activity.executeRustTxReaderSession(
            HceBackedIsoDepTransport(hce),
            rawRlpHex = eip1559UnsignedHex,
            chainId = MainActivity.PUBLIC_TEST_CHAIN_ID,
            expectedAddress = expectedSigner
        )!!
        assertTrue("EIP-1559 Touch 2 must verify: $touch2Res", touch2Res.optBoolean("verified"))
        assertEquals("VERIFIED", touch2Res.optString("status"))
    }

    // ---------------------------------------------------------------------------------------
    // FCW-H2-D359879-RECHECK Section 六: Persistent Evidence Hardening & Post-Restart History
    // ---------------------------------------------------------------------------------------

    @Test
    fun testA7_HardenedEvidence_ConcurrentEventSeq_WriteFailure_CorruptionGapDetection_AndPostRestartHistory() {
        val activity = resumedActivity()
        activity.startProbeSession(requestedRunId = "run-hardened-ev-01", requestedPhase = "phase1")

        // 1. Concurrent Reader & HCE logging must produce strictly sequential 1..N event_seq and run_event_seq
        val threads = (1..4).map { tIdx ->
            Thread {
                for (i in 1..15) {
                    ProbeSessionState.recordAndLogEvent(
                        eventName = if (tIdx % 2 == 0) "CONCURRENT_READER_EVT" else "CONCURRENT_HCE_EVT",
                        source = if (tIdx % 2 == 0) "READER" else "HCE",
                        payload = JSONObject().put("thread", tIdx).put("iter", i)
                    )
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(5000) }

        val checkClean = ProbeSessionState.readAndValidateEventsForRun("run-hardened-ev-01")
        assertTrue("Concurrent JSONL must be valid: ${checkClean.errorDetail}", checkClean.ok)
        val seqs = checkClean.events.map { it.getLong("run_event_seq") }
        assertEquals((1L..seqs.size.toLong()).toList(), seqs)

        // 2. Terminal state precedence: CANCELLED report must not be overwritten by a stale PASSED report
        val cancelPayload = JSONObject().put("status", "CANCELLED").put("all_passed", false)
        assertTrue(ProbeSessionState.writePersistentReportDetailed("READER", "run-hardened-ev-01", "phase1", activity.currentGeneration, cancelPayload).ok)
        val stalePassPayload = JSONObject().put("status", "PASSED").put("all_passed", true)
        val staleWrite = ProbeSessionState.writePersistentReportDetailed("READER", "run-hardened-ev-01", "phase1", activity.currentGeneration, stalePassPayload)
        assertFalse("Stale PASSED must be rejected when CANCELLED is already recorded", staleWrite.ok)
        assertEquals("STALE_PASS_REJECTED_AFTER_TERMINAL_FAILURE", staleWrite.errorCode)
        val savedReport = JSONObject(File(tempEvidenceDir, "report_reader_run-hardened-ev-01.json").readText())
        assertEquals("Terminal CANCELLED must not be overwritten by PASSED", "CANCELLED", savedReport.optString("status"))
        assertFalse(savedReport.optBoolean("all_passed"))

        // 3. Explicit EVIDENCE_WRITE_FAILED when target report path is blocked by a directory
        val blockedRunId = "run-write-blocked-02"
        activity.startProbeSession(requestedRunId = blockedRunId, requestedPhase = "phase1")
        val blockingDir = File(tempEvidenceDir, "report_reader_${blockedRunId}.json")
        assertTrue(blockingDir.mkdirs())
        File(blockingDir, "keep").writeText("non-empty")
        val failedWrite = ProbeSessionState.writePersistentReportDetailed(
            "READER", blockedRunId, "phase1", activity.currentGeneration, JSONObject().put("status", "PASSED")
        )
        assertFalse("Write must fail when target path is a non-empty directory", failedWrite.ok)
        assertEquals("EVIDENCE_WRITE_FAILED", failedWrite.errorCode)
        val blockedBundle = activity.buildPersistentEvidenceBundle(blockedRunId)
        assertEquals("EVIDENCE_WRITE_FAILED", blockedBundle.optString("evidence_status"))

        // 4. Corruption & deleted-line gap detection in events_<runId>.jsonl
        val gapRunId = "run-gap-detect-03"
        activity.startProbeSession(requestedRunId = gapRunId, requestedPhase = "phase1")
        for (i in 1..4) {
            ProbeSessionState.recordAndLogEvent("STEP_$i", "READER", JSONObject().put("step", i))
        }
        val gapJsonlFile = File(tempEvidenceDir, "events_${gapRunId}.jsonl")
        val lines = gapJsonlFile.readLines(Charsets.UTF_8).toMutableList()
        assertTrue(lines.size >= 4)
        // Delete middle event line to create a sequence gap
        lines.removeAt(2)
        gapJsonlFile.writeText(lines.joinToString("\n") + "\n", Charsets.UTF_8)
        val gapBundle = activity.buildPersistentEvidenceBundle(gapRunId)
        assertEquals("EVIDENCE_CORRUPTED_OR_MISSING_EVENT", gapBundle.optString("evidence_status"))
        assertFalse(gapBundle.optBoolean("all_passed", true))

        // Corrupt JSON line detection
        gapJsonlFile.appendText("{corrupted-json-line\n", Charsets.UTF_8)
        val corruptCheck = ProbeSessionState.readAndValidateEventsForRun(gapRunId)
        assertFalse(corruptCheck.ok)
        assertEquals("EVIDENCE_CORRUPTED_OR_MISSING_EVENT", corruptCheck.status)

        // 5. Post-restart historical run discovery and export
        ProbeSessionState.simulateProcessRestart(tempEvidenceDir)
        val runsAfterRestart = ProbeSessionState.listPersistedRuns()
        val discoveredRunIds = (0 until runsAfterRestart.length()).map {
            runsAfterRestart.getJSONObject(it).getString("run_id")
        }
        assertTrue("Historical run must be discoverable after restart", discoveredRunIds.contains("run-hardened-ev-01"))
        val exportedHistorical = activity.buildPersistentEvidenceBundle("run-hardened-ev-01")
        assertEquals("OK", exportedHistorical.optString("evidence_status"))
        assertEquals("run-hardened-ev-01", exportedHistorical.optString("run_id"))
        assertTrue(exportedHistorical.optInt("events_count") >= 60)
    }
}

