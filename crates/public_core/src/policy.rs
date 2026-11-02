use crate::error::CoreError;
use crate::evm::ParsedIntent;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenMetadata {
    pub symbol: String,
    pub decimals: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PolicyVerdict {
    Approved {
        chain_id: u64,
        recipient: String,
        amount_display: String,
        fee_cap_wei: String,
    },
    Rejected {
        reason: String,
    },
}

#[derive(Debug, Clone)]
pub struct PolicyEngine {
    pub allowed_chain_ids: Vec<u64>,
    pub max_fee_cap_wei: u128,
    pub token_registry: HashMap<String, TokenMetadata>,
    pub approved_eip712_templates: Vec<String>,
}

impl Default for PolicyEngine {
    fn default() -> Self {
        let mut registry = HashMap::new();
        // Sepolia Mock USDC (6 decimals)
        registry.insert(
            "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238".to_lowercase(),
            TokenMetadata {
                symbol: "USDC".into(),
                decimals: 6,
            },
        );
        // Sepolia Mock DAI (18 decimals)
        registry.insert(
            "0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357".to_lowercase(),
            TokenMetadata {
                symbol: "DAI".into(),
                decimals: 18,
            },
        );

        Self {
            // Mainnet (1) is strictly excluded from default signing allowlist in MVP
            allowed_chain_ids: vec![
                11155111, // Sepolia Testnet
                1337,     // Local Hardhat / Geth
                31337,    // Local Anvil
            ],
            max_fee_cap_wei: 50_000_000_000_000_000, // 0.05 ETH max execution fee safeguard
            token_registry: registry,
            approved_eip712_templates: vec![
                "Mail".to_string(),
                "LoginChallenge".to_string(),
            ],
        }
    }
}

impl PolicyEngine {
    pub fn evaluate_intent(&self, intent: &ParsedIntent) -> PolicyVerdict {
        match intent {
            ParsedIntent::NativeTransfer {
                chain_id,
                recipient,
                value_wei,
                fee_cap_wei,
            } => {
                if !self.allowed_chain_ids.contains(chain_id) {
                    return PolicyVerdict::Rejected {
                        reason: format!("Chain ID {} is not in the allowed network list", chain_id),
                    };
                }
                if recipient.is_empty()
                    || recipient == "0x0000000000000000000000000000000000000000"
                {
                    return PolicyVerdict::Rejected {
                        reason: "Zero or empty recipient address (contract deployment rejected in MVP)".into(),
                    };
                }
                let fee_cap: u128 = fee_cap_wei.parse().unwrap_or(u128::MAX);
                if fee_cap > self.max_fee_cap_wei {
                    return PolicyVerdict::Rejected {
                        reason: format!(
                            "Fee cap {} exceeds maximum policy safeguard limit of {}",
                            fee_cap_wei, self.max_fee_cap_wei
                        ),
                    };
                }

                PolicyVerdict::Approved {
                    chain_id: *chain_id,
                    recipient: recipient.clone(),
                    amount_display: format!("{} wei", value_wei),
                    fee_cap_wei: fee_cap_wei.clone(),
                }
            }
            ParsedIntent::Erc20Transfer {
                chain_id,
                token_contract,
                recipient,
                token_amount_raw,
                fee_cap_wei,
            } => {
                if !self.allowed_chain_ids.contains(chain_id) {
                    return PolicyVerdict::Rejected {
                        reason: format!("Chain ID {} is not in the allowed network list", chain_id),
                    };
                }
                if recipient.is_empty()
                    || recipient == "0x0000000000000000000000000000000000000000"
                {
                    return PolicyVerdict::Rejected {
                        reason: "Zero recipient address for ERC-20 transfer rejected".into(),
                    };
                }

                let fee_cap: u128 = fee_cap_wei.parse().unwrap_or(u128::MAX);
                if fee_cap > self.max_fee_cap_wei {
                    return PolicyVerdict::Rejected {
                        reason: format!(
                            "Fee cap {} exceeds maximum policy safeguard limit of {}",
                            fee_cap, self.max_fee_cap_wei
                        ),
                    };
                }

                let meta = match self.token_registry.get(&token_contract.to_lowercase()) {
                    Some(m) => m,
                    None => {
                        return PolicyVerdict::Rejected {
                            reason: format!(
                                "Token contract {} is not in the approved whitelist (EVM-09 Fail-Closed)",
                                token_contract
                            ),
                        };
                    }
                };

                let amount_display = format_units_decimal(token_amount_raw, meta.decimals)
                    .map(|val| format!("{} {}", val, meta.symbol))
                    .unwrap_or_else(|_| format!("{} {}", token_amount_raw, meta.symbol));

                PolicyVerdict::Approved {
                    chain_id: *chain_id,
                    recipient: recipient.clone(),
                    amount_display,
                    fee_cap_wei: fee_cap_wei.clone(),
                }
            }
            ParsedIntent::PolicyRejected { reason } => PolicyVerdict::Rejected {
                reason: reason.clone(),
            },
        }
    }

    pub fn evaluate_eip712_template(&self, template_name: &str) -> PolicyVerdict {
        let t_lower = template_name.to_lowercase();
        if t_lower.contains("permit") {
            return PolicyVerdict::Rejected {
                reason: format!("Permit / Allowance template '{template_name}' rejected by fail-closed policy (MSG-03)"),
            };
        }
        if !self.approved_eip712_templates.contains(&template_name.to_string()) {
            return PolicyVerdict::Rejected {
                reason: format!("Template '{template_name}' is not in approved EIP-712 templates list (MSG-02)"),
            };
        }
        PolicyVerdict::Approved {
            chain_id: 11155111,
            recipient: "EIP-712".into(),
            amount_display: format!("Typed Data: {template_name}"),
            fee_cap_wei: "0".into(),
        }
    }
}

pub fn format_units_decimal(raw_dec: &str, decimals: u8) -> Result<String, CoreError> {
    let s = raw_dec.trim();
    if s.is_empty() {
        return Ok("0".into());
    }
    let d = decimals as usize;
    if s.len() <= d {
        let zeros = "0".repeat(d - s.len());
        let frac = format!("{zeros}{s}");
        let clean_frac = frac.trim_end_matches('0');
        if clean_frac.is_empty() {
            Ok("0.0".into())
        } else {
            Ok(format!("0.{clean_frac}"))
        }
    } else {
        let int_part = &s[..s.len() - d];
        let frac_part = &s[s.len() - d..];
        let clean_frac = frac_part.trim_end_matches('0');
        if clean_frac.is_empty() {
            Ok(format!("{int_part}.0"))
        } else {
            Ok(format!("{int_part}.{clean_frac}"))
        }
    }
}
