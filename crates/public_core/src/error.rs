use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum CoreError {
    #[error("RLP decode error: {0}")]
    RlpDecodeError(String),

    #[error("Invalid transaction format: {0}")]
    InvalidTransactionFormat(String),

    #[error("Replay protection missing: legacy transaction must use EIP-155 (v >= 35)")]
    ReplayProtectionMissing,

    #[error("Unsupported transaction type: {0:#x}")]
    UnsupportedTransactionType(u8),

    #[error("Policy rejected: {0}")]
    PolicyRejected(String),

    #[error("Contract deployment is strictly rejected in MVP")]
    ContractDeploymentRejected,

    #[error("Invalid gas parameters: {0}")]
    InvalidGasParameters(String),

    #[error("Dirty padding detected in ERC-20 recipient: first 12 bytes must be zero")]
    DirtyPaddingDetected,

    #[error("Chain ID mismatch: declared {declared}, payload {payload}")]
    ChainIdMismatch { declared: u64, payload: u64 },

    #[error("Network not in allowlist: chain_id {0}")]
    NetworkNotAllowed(u64),

    #[error("EIP-712 error: {0}")]
    Eip712Error(String),

    #[error("Permit or Allowance signature rejected by policy: {0}")]
    PermitRejected(String),

    #[error("Signature error: {0}")]
    SignatureError(String),

    #[error("Address mismatch: expected {expected}, recovered {recovered}")]
    AddressMismatch { expected: String, recovered: String },
}
