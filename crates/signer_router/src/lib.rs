use public_core::evm::ParsedIntent;
use public_core::policy::PolicyVerdict;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum RouterError {
    #[error("Invalid state transition: current {current:?}, attempted {attempted:?}")]
    InvalidStateTransition {
        current: RequestState,
        attempted: RequestState,
    },

    #[error("Request cancelled by user. Signing call count: 0")]
    UserCancelled,

    #[error("Policy rejected request: {0}")]
    PolicyRejected(String),

    #[error("External signer disconnected during or after command transmission. Status: SIGNING_OUTCOME_UNKNOWN. Automatic retry and broadcast forbidden!")]
    SigningOutcomeUnknown,

    #[error("Backend mismatch: declared {declared:?}, executing {executing:?}")]
    BackendMismatch {
        declared: SignerBackend,
        executing: SignerBackend,
    },

    #[error("Request already consumed. Replay signing attempt rejected!")]
    AlreadyConsumed,

    #[error("Cannot cancel request in signed/dispatched state {current:?} (sign_command_count={sign_command_count})")]
    AlreadySigned {
        current: RequestState,
        sign_command_count: u32,
    },

    #[error("Request is already cancelled")]
    AlreadyCancelled,

    #[error("Cannot cancel request with unknown signing outcome (SIGNING_OUTCOME_UNKNOWN)")]
    OutcomeUnknownCannotCancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Transport {
    Qr,
    NfcIsoDepHce,
    NfcNdefMedia,
    NfcCard,
    Ble,
    Usb,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SignerBackend {
    LocalVaultKey,
    RemoteVault,
    Ledger,
    Tangem,
    Keycard,
    TapSigner,
    Satochip,
    CoolWallet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RequestState {
    Receiving,
    ReceivedUntrusted,
    Prepared,
    Reviewing,
    Approved,
    SignCommandSent,
    SignedVerified,
    SigningOutcomeUnknown,
    ResponseReady,
    Consumed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreparedRequest {
    pub handle_id: String,
    pub session_id: String,
    pub request_id: String,
    pub transport: Transport,
    pub backend: SignerBackend,
    pub chain_id: u64,
    pub account_address: String,
    pub raw_signing_digest: [u8; 32],
    pub intent: ParsedIntent,
    pub policy_verdict: PolicyVerdict,
    pub state: RequestState,
    pub sign_command_count: u32,
    pub signature_response: Option<Vec<u8>>,
}

impl PreparedRequest {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        session_id: String,
        request_id: String,
        transport: Transport,
        backend: SignerBackend,
        chain_id: u64,
        account_address: String,
        raw_signing_digest: [u8; 32],
        intent: ParsedIntent,
        policy_verdict: PolicyVerdict,
    ) -> Result<Self, RouterError> {
        if let PolicyVerdict::Rejected { reason } = &policy_verdict {
            return Err(RouterError::PolicyRejected(reason.clone()));
        }

        let handle_id = format!("handle-{}", &request_id);

        Ok(Self {
            handle_id,
            session_id,
            request_id,
            transport,
            backend,
            chain_id,
            account_address,
            raw_signing_digest,
            intent,
            policy_verdict,
            state: RequestState::Prepared,
            sign_command_count: 0,
            signature_response: None,
        })
    }

    pub fn with_handle_id(mut self, handle_id: String) -> Self {
        self.handle_id = handle_id;
        self
    }

    pub fn start_review(&mut self) -> Result<(), RouterError> {
        if self.state != RequestState::Prepared {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::Reviewing,
            });
        }
        self.state = RequestState::Reviewing;
        Ok(())
    }

    pub fn approve(&mut self) -> Result<(), RouterError> {
        if self.state == RequestState::Consumed {
            return Err(RouterError::AlreadyConsumed);
        }
        if self.state != RequestState::Reviewing {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::Approved,
            });
        }
        self.state = RequestState::Approved;
        Ok(())
    }

    pub fn cancel(&mut self) -> Result<(), RouterError> {
        match self.state {
            RequestState::Cancelled => Err(RouterError::AlreadyCancelled),
            RequestState::Consumed => Err(RouterError::AlreadyConsumed),
            RequestState::SigningOutcomeUnknown => Err(RouterError::OutcomeUnknownCannotCancel),
            RequestState::SignCommandSent
            | RequestState::SignedVerified
            | RequestState::ResponseReady => Err(RouterError::AlreadySigned {
                current: self.state,
                sign_command_count: self.sign_command_count,
            }),
            RequestState::Receiving
            | RequestState::ReceivedUntrusted
            | RequestState::Prepared
            | RequestState::Reviewing
            | RequestState::Approved => {
                if self.sign_command_count > 0 {
                    return Err(RouterError::AlreadySigned {
                        current: self.state,
                        sign_command_count: self.sign_command_count,
                    });
                }
                self.state = RequestState::Cancelled;
                Ok(())
            }
        }
    }

    pub fn revoke(&mut self) {
        if self.sign_command_count == 0
            && matches!(
                self.state,
                RequestState::Receiving
                    | RequestState::ReceivedUntrusted
                    | RequestState::Prepared
                    | RequestState::Reviewing
                    | RequestState::Approved
            )
        {
            self.state = RequestState::Cancelled;
        }
    }

    pub fn mark_sign_command_sent(&mut self, executing_backend: SignerBackend) -> Result<(), RouterError> {
        if self.state == RequestState::Consumed {
            return Err(RouterError::AlreadyConsumed);
        }
        if self.state != RequestState::Approved {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::SignCommandSent,
            });
        }
        if self.backend != executing_backend {
            return Err(RouterError::BackendMismatch {
                declared: self.backend,
                executing: executing_backend,
            });
        }
        self.state = RequestState::SignCommandSent;
        self.sign_command_count += 1;
        Ok(())
    }

    pub fn mark_disconnected_or_interrupted(&mut self) -> Result<(), RouterError> {
        match self.state {
            RequestState::SignCommandSent => {
                self.state = RequestState::SigningOutcomeUnknown;
                Err(RouterError::SigningOutcomeUnknown)
            }
            RequestState::SigningOutcomeUnknown => Err(RouterError::SigningOutcomeUnknown),
            RequestState::SignedVerified | RequestState::ResponseReady => {
                Err(RouterError::AlreadySigned {
                    current: self.state,
                    sign_command_count: self.sign_command_count,
                })
            }
            RequestState::Consumed => Err(RouterError::AlreadyConsumed),
            RequestState::Cancelled => Err(RouterError::AlreadyCancelled),
            RequestState::Receiving
            | RequestState::ReceivedUntrusted
            | RequestState::Prepared
            | RequestState::Reviewing
            | RequestState::Approved => {
                if self.sign_command_count > 0 {
                    self.state = RequestState::SigningOutcomeUnknown;
                    return Err(RouterError::SigningOutcomeUnknown);
                }
                self.state = RequestState::Cancelled;
                Ok(())
            }
        }
    }

    pub fn complete_with_signature(&mut self, signature: Vec<u8>) -> Result<(), RouterError> {
        if self.state != RequestState::SignCommandSent {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::SignedVerified,
            });
        }
        self.signature_response = Some(signature);
        self.state = RequestState::SignedVerified;
        Ok(())
    }

    pub fn prepare_response(&mut self) -> Result<(), RouterError> {
        if self.state != RequestState::SignedVerified {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::ResponseReady,
            });
        }
        self.state = RequestState::ResponseReady;
        Ok(())
    }

    pub fn consume(&mut self) -> Result<(), RouterError> {
        if self.state == RequestState::Consumed {
            return Err(RouterError::AlreadyConsumed);
        }
        if self.state != RequestState::ResponseReady && self.state != RequestState::SignedVerified {
            return Err(RouterError::InvalidStateTransition {
                current: self.state,
                attempted: RequestState::Consumed,
            });
        }
        self.state = RequestState::Consumed;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cancellation_guarantees_zero_sign_count() {
        let mut req = PreparedRequest::new(
            "sess-1".into(),
            "req-1".into(),
            Transport::NfcCard,
            SignerBackend::Keycard,
            11155111,
            "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
            [0x44; 32],
            ParsedIntent::NativeTransfer {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                value_wei: "1000".into(),
                fee_cap_wei: "21000".into(),
            },
            PolicyVerdict::Approved {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                amount_display: "1000 wei".into(),
                fee_cap_wei: "21000".into(),
            },
        )
        .unwrap();

        req.start_review().unwrap();
        // User cancels during review
        req.cancel().unwrap();

        assert_eq!(req.state, RequestState::Cancelled);
        assert_eq!(req.sign_command_count, 0, "Sign command count MUST be strictly 0 on cancellation!");
    }

    #[test]
    fn test_disconnection_after_send_transitions_to_outcome_unknown() {
        let mut req = PreparedRequest::new(
            "sess-1".into(),
            "req-1".into(),
            Transport::Usb,
            SignerBackend::Ledger,
            11155111,
            "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
            [0x44; 32],
            ParsedIntent::NativeTransfer {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                value_wei: "1000".into(),
                fee_cap_wei: "21000".into(),
            },
            PolicyVerdict::Approved {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                amount_display: "1000 wei".into(),
                fee_cap_wei: "21000".into(),
            },
        )
        .unwrap();

        req.start_review().unwrap();
        req.approve().unwrap();
        req.mark_sign_command_sent(SignerBackend::Ledger).unwrap();
        assert_eq!(req.sign_command_count, 1);

        // Connection dropped / USB unplugged while waiting for device screen confirmation
        let err = req.mark_disconnected_or_interrupted().unwrap_err();
        assert_eq!(err, RouterError::SigningOutcomeUnknown);
        assert_eq!(req.state, RequestState::SigningOutcomeUnknown);
        // Invariant: MUST NOT broadcast or auto-retry!
    }

    #[test]
    fn test_life_03_consumed_state_prevents_replay_signing() {
        let mut req = PreparedRequest::new(
            "sess-1".into(),
            "req-1".into(),
            Transport::Qr,
            SignerBackend::LocalVaultKey,
            11155111,
            "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
            [0x44; 32],
            ParsedIntent::NativeTransfer {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                value_wei: "1000".into(),
                fee_cap_wei: "21000".into(),
            },
            PolicyVerdict::Approved {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                amount_display: "1000 wei".into(),
                fee_cap_wei: "21000".into(),
            },
        )
        .unwrap();

        req.start_review().unwrap();
        req.approve().unwrap();
        req.mark_sign_command_sent(SignerBackend::LocalVaultKey).unwrap();
        req.complete_with_signature(vec![0x55; 65]).unwrap();
        req.prepare_response().unwrap();

        // Consume handle
        req.consume().unwrap();
        assert_eq!(req.state, RequestState::Consumed);

        // Replay attempt to approve or mark_sent must fail
        assert_eq!(req.approve().unwrap_err(), RouterError::AlreadyConsumed);
        assert_eq!(req.mark_sign_command_sent(SignerBackend::LocalVaultKey).unwrap_err(), RouterError::AlreadyConsumed);
        assert_eq!(req.consume().unwrap_err(), RouterError::AlreadyConsumed);
        assert_eq!(req.sign_command_count, 1, "Sign command count must remain strictly 1");
    }

    #[test]
    fn test_life_01_revoke_on_new_request() {
        let mut req_a = PreparedRequest::new(
            "sess-1".into(),
            "req-A".into(),
            Transport::Qr,
            SignerBackend::LocalVaultKey,
            11155111,
            "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
            [0x11; 32],
            ParsedIntent::NativeTransfer {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                value_wei: "1000".into(),
                fee_cap_wei: "21000".into(),
            },
            PolicyVerdict::Approved {
                chain_id: 11155111,
                recipient: "0x9858effd232b4033e47d90003d41ec34ecaeda94".into(),
                amount_display: "1000 wei".into(),
                fee_cap_wei: "21000".into(),
            },
        )
        .unwrap();

        req_a.start_review().unwrap();

        // New request arrives -> revoke req_a
        req_a.revoke();
        assert_eq!(req_a.state, RequestState::Cancelled);
        assert_eq!(req_a.sign_command_count, 0);

        // Attempting to approve revoked request must fail
        assert!(req_a.approve().is_err());
    }
}
