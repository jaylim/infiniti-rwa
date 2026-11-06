# Infiniti RWA: RRWA and NTG-SF tokens

This repository holds the smart-contract source of the two real-world-asset (RWA) tokens, **RRWA** and **NTG-SF**. This document explains how the tokens work, who controls what, and which open standards and open-source projects they are built on.

## 1. Summary

- RRWA and NTG-SF are **permissioned security tokens** built on the **ERC-3643 standard** (the "T-REX" token standard).
- Unlike an ordinary ERC-20 token, they can only be held by wallets that have an on-chain identity (**ONCHAINID**) and have been registered by the issuer. A transfer to any other wallet is rejected by the token contract itself.
- Every mint and transfer is also checked against **compliance rules**. At the moment, one rule is active: a cap on total supply.
- The token, identity and compliance contracts are the **official, unmodified releases** of ERC-3643 4.1.3, ONCHAINID 2.2.1 and Tokeny T-REX 4.1.6. Only the import paths were changed so the files compile from this folder layout (see section 7).
- Each token is deployed as its own independent contract suite. The two tokens share no contracts.

| | RRWA | NTG-SF |
|---|---|---|
| Standard | ERC-3643 (T-REX 4.1.3) | ERC-3643 (T-REX 4.1.3) |
| Decimals | 18 | 18 |
| Supply cap at deployment | 480,000,000 | Unlimited |
| Network | Base | Base |

## 2. Why ERC-3643

Securities and fund units may only be held by approved investors. ERC-3643 is an Ethereum standard (EIP-3643) designed for exactly that case:

- **Identity:** every holder wallet is linked to an on-chain identity contract.
- **Eligibility:** the token asks an Identity Registry "is this wallet verified?" before every mint and transfer.
- **Compliance:** a modular compliance contract applies issuer rules (supply cap, allowed countries, holding limits, etc.) to every mint and transfer.
- **Control:** the issuer can freeze wallets, pause the token, burn tokens, force transfers, and recover tokens from a wallet whose key was lost. These are legal requirements for regulated assets.
- **Compatibility:** the token is still ERC-20 compatible, so wallets and block explorers can display balances and transfers.

ERC-3643 is maintained by the ERC-3643 Association, and its reference implementation (T-REX) was developed by Tokeny.

## 3. Components

Each token is made of the contracts below. All of them are in this repository.

| Component | Folder | What it does |
|---|---|---|
| **Token** | `erc-3643/token/` | The ERC-20-compatible token. Before any mint or transfer it checks that the receiver is verified, that neither wallet is frozen, that the token is not paused, and that compliance allows it. |
| **Identity Registry** (+ Storage) | `erc-3643/registry/` | The list of eligible wallets: wallet → ONCHAINID → country code (ISO 3166-1 numeric). `isVerified(wallet)` is what the token checks. |
| **Claim Topics Registry / Trusted Issuers Registry** | `erc-3643/registry/` | Define which signed claims (e.g. KYC) an identity must carry, and who may issue them. Both are currently **empty**, so registration by the issuer is the eligibility check (see section 5). |
| **Modular Compliance** | `erc-3643/compliance/modular/` | Holds the list of active compliance modules and asks each one before every mint and transfer. |
| **Compliance modules** | `modules/` | Individual rules. See section 4. |
| **ONCHAINID** (Identity, IdFactory, Gateway) | `onchain-id/` | The investor's on-chain identity contract (keys and claims, ERC-734 / ERC-735), the factory that creates one per wallet, and the Gateway that only lets the issuer's approved signers create identities with a chosen salt. |
| **AgentManager / OwnerManager** | `t-rex/roles/permissioning/` | Split the issuer's powers into separate roles (mint, whitelist, freeze, forced transfer, recovery, compliance), so day-to-day operator wallets never hold the owner's full rights. |
| **Proxies and Implementation Authority** | `erc-3643/proxy/`, `onchain-id/proxy/` | The token suite and identities are deployed behind proxies. The implementation authority, which controls upgrades, is held by the owner. |
| **T-REX Factory** | `erc-3643/factory/` | Deploys a complete token suite in one step. |

## 4. Compliance rules

| Module | Rule |
|---|---|
| **SupplyLimitModule** | Rejects any mint that would take total supply above the cap, for tokens whose compliance contract has added this module. Until a cap is set it is 0, so all mints are rejected. The cap can be changed by the compliance operator. |
| **CountryAllowModule** | Only wallets registered with an allowed country may receive tokens. |
| **MaxBalanceModule** | Caps how many tokens one investor identity can hold across all of its wallets. |
| **TimeExchangeLimitsModule** | Caps how much one investor can send to a tagged exchange within a time window. |

The three inactive modules can be switched on later without redeploying the token.

## 5. Token lifecycle

```
 Investor wallet                Issuer (operator wallet)                 Token contracts
 ───────────────                ────────────────────────                 ───────────────
                     1. create ONCHAINID ─────────────────────────────▶  Gateway → IdFactory
                     2. register wallet + country ────────────────────▶  AgentManager → Identity Registry
                     3. mint (after payment is confirmed) ────────────▶  Token
                                                                           checks: verified? not frozen?
                                                                                   supply cap OK?
 4. transfer ─────────────────────────────────────────────────────────▶  Token
                                                                           checks: receiver verified?
                                                                                   neither frozen? compliance OK?
                     5. freeze / unfreeze, pause, burn,
                        forced transfer, recover lost wallet ─────────▶  AgentManager → Token
```

1. **Identity.** The issuer creates an ONCHAINID for the investor's wallet through the Gateway. The operator signs an approval that expires after 15 minutes. One identity per wallet.
2. **Registration.** The issuer registers the wallet, its ONCHAINID and its country in the token's Identity Registry. From now on `isVerified(wallet)` is true and the wallet can receive the token. Each token has its own registry, so a wallet is registered separately for RRWA and for NTG-SF.
3. **Mint.** After a subscription is paid and approved, the issuer mints the tokens. The token's compliance check refuses a mint above the supply cap.
4. **Transfers.** Holders can transfer to other verified wallets. Transfers to unregistered or frozen wallets revert on-chain.
5. **Control.** Freeze, pause, burn, forced transfer and lost-wallet recovery are issuer actions, each limited to the role that holds it (section 6).

Note on eligibility: no claim topics are configured yet, so the chain does not require a signed KYC claim. Investor approval (KYC/AML) happens off-chain before the issuer registers the wallet; registration is the on-chain record of that approval. Claim requirements can be added later through the Claim Topics and Trusted Issuers registries.

## 6. Roles and permissions

| Role | Can do |
|---|---|
| **Owner** | Owns the token, registries, Gateway, AgentManager and OwnerManager; controls upgrades; keeps direct emergency agent rights; grants and revokes all other roles. |
| **Operator** | Through AgentManager: mint and burn (SupplyModifier), register / update / remove wallets (WhiteListManager), freeze / unfreeze and pause / unpause (Freezer). Also an approved Gateway signer for identity creation. |
| **Compliance operator** | Through OwnerManager: change compliance module settings (e.g. the supply cap) and add or remove modules. No mint or registry rights. |
| **Fund operator** | Through AgentManager: forced transfers and lost-wallet recovery only. |

Roles are granted to an operator's ONCHAINID rather than directly to its wallet. If an operator wallet is compromised, its roles can be revoked without touching the token or the other roles.

## 7. What is in this repository

| Folder | Source | Version | Changes |
|---|---|---|---|
| `erc-3643/` | ERC-3643 reference implementation (T-REX token suite) | 4.1.3 | Import paths only |
| `onchain-id/` | ONCHAINID | 2.2.1 | Import paths only |
| `t-rex/` | Tokeny T-REX (AgentManager, OwnerManager and role contracts) | 4.1.6 | Import paths only |
| `openzeppelin/` | OpenZeppelin Contracts and Contracts Upgradeable | 4.9.6 | None (dependencies of the above) |
| `modules/` | Compliance modules adapted from T-REX 4.1.6 modules of the same names | — | Restructured and re-documented; the rules are the same |

All contracts compile with Solidity **0.8.17**.

The "import paths only" claim was checked file by file against the published npm packages (`@erc3643org/erc-3643@4.1.3`, `@onchain-id/solidity@2.2.1`, `@tokenysolutions/t-rex@4.1.6`): apart from `import` lines, the files are identical.

## 8. References

**Standards**

- EIP-3643: T-REX, Token for Regulated EXchanges: https://eips.ethereum.org/EIPS/eip-3643
- ERC-3643 Association (documentation and ecosystem): https://www.erc3643.org

**Source code this repository is based on**

| Project | Version used | Repository | Package |
|---|---|---|---|
| ERC-3643 (T-REX token suite) | 4.1.3 | https://github.com/ERC-3643/ERC-3643/tree/4.1.3 | https://www.npmjs.com/package/@erc3643org/erc-3643/v/4.1.3 |
| ONCHAINID | 2.2.1 | https://github.com/onchain-id/solidity/tree/2.2.1 | https://www.npmjs.com/package/@onchain-id/solidity/v/2.2.1 |
| ONCHAINID Gateway | 2.2.1 | https://github.com/onchain-id/solidity/blob/2.2.1/contracts/gateway/Gateway.sol | (same package) |
| Tokeny T-REX (AgentManager, OwnerManager) | 4.1.6 | https://github.com/TokenySolutions/T-REX/tree/4.1.6 | https://www.npmjs.com/package/@tokenysolutions/t-rex/v/4.1.6 |
| OpenZeppelin Contracts / Contracts Upgradeable | 4.9.6 | https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v4.9.6 | https://www.npmjs.com/package/@openzeppelin/contracts/v/4.9.6 |


**Compliance modules (our own implementation)**

The four modules in `modules/` (SupplyLimitModule, CountryAllowModule, MaxBalanceModule and TimeExchangeLimitsModule) are not copied from any release. We wrote them for RRWA and NTG-SF, using the following as references:

- **Tokeny T-REX 4.1.6 compliance modules.** Each of our modules has the same name as a T-REX module and enforces the same rule. We followed T-REX's design for each rule and then restructured the code and rewrote its documentation. Source: https://github.com/TokenySolutions/T-REX/tree/4.1.6/contracts/compliance/modular/modules
- **ERC-3643 4.1.3 modular compliance interface.** Every module extends `AbstractModuleUpgradeable` from the official ERC-3643 release in `erc-3643/`. Because of this, any standard ERC-3643 compliance contract can bind the modules and call them in the usual way, and each module runs behind an upgradeable proxy.

Our modules keep the same rules as the T-REX originals, but they are not byte-for-byte copies. They should be reviewed as our own code and should not be assumed to share the audit status of the upstream releases.

**Further reading**

- ERC-3643 documentation: https://docs.erc3643.org
- ONCHAINID documentation: https://docs.onchainid.com

## 9. Licenses

- ERC-3643, ONCHAINID and T-REX are licensed under **GPL-3.0**. The license files are kept in `erc-3643/`, `onchain-id/` and `t-rex/`.
- OpenZeppelin Contracts are licensed under **MIT**. The license files are in `openzeppelin/`.
- The modules in `modules/` are marked **GPL-3.0-or-later**.
