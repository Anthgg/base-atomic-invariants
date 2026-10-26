# Base Atomic Invariants & Pre-Simulation Harness

Deterministic AST boundary verification and zero-gas-waste pre-simulation harness for autonomous agent routers on **Base Mainnet (Chain ID 8453)**.

Designed for automated bounty verification, agent-to-agent collaboration, and `x402` micropayment settlements.

---

## Architecture Overview

Autonomous execution on Base requires multi-gate verification before any transaction is broadcast to the public mempool:

```
┌─────────────────────────────────┐
│ GATE 1: AST Boundary Validator │
│ - Modifier reachability         │
│ - Callback sender assertions    │
│ - Storage layout diffs          │
│ - Atomic revert checks          │
└────────────────┬────────────────┘
                 │ (Passed)
                 ▼
┌─────────────────────────────────┐
│ GATE 2: Base Fork Pre-Sim       │
│ - eth_call state simulation     │
│ - Slippage & tick-ladder model  │
│ - Gas consumption ceiling       │
│ - Revert on sub-marginal profit │
└────────────────┬────────────────┘
                 │ (Passed)
                 ▼
┌─────────────────────────────────┐
│ GATE 3: Atomic On-Chain Router  │
│ - Morpho Blue 0% flash loans    │
│ - Balancer V2 & Aave V3 fallback│
│ - x402 automated settlement     │
└─────────────────────────────────┘
```

---

## 1. Gate 1: AST Boundary Invariants (`invariants/ast_validator.py`)

Parses Solidity AST nodes and enforces strict security invariants before compilation or bytecode analysis:

1. **Callback Sender Assertions**: Enforces that external callback endpoints (`onMorphoFlashLoan`, `receiveFlashLoan`) strictly assert `msg.sender == PROTOCOL_IMMUTABLE`.
2. **Atomic Revert Invariants**: Ensures `finalBalance < requiredBalance` triggers explicit reverts (`InsufficientNetProfit`), guaranteeing atomic rollbacks when net profit is $\le 0$.
3. **Storage Layout Preservation**: Detects storage slot collisions, proxy layout hazards, and uninitialized pointers.
4. **Modifier Reachability**: Audits external administrative and fund-routing functions.

---

## 2. Gate 2: Pre-Simulation Harness (`harness/atomic_presim.py`)

Executes real-time pre-flight verification against Base Mainnet RPC endpoints without spending gas:

* Queries state directly via `eth_call` and `eth_estimateGas`.
* Validates ownership state and execution eligibility.
* If a flash arbitrage route does not yield surplus profit after pool fees (0.05% - 0.30%) and L2 execution gas, the transaction is discarded off-chain with zero gas waste.

---

## 3. Production Contract on Base Mainnet

The verified Solidity router is deployed and active on Base:

* **Router Contract**: [`0x5314a0f7317f1a5fe5ef8e593d9bfb5a8968f0a4`](https://basescan.org/address/0x5314a0f7317f1a5fe5ef8e593d9bfb5a8968f0a4)
* **Flash Loan Protocols**:
  * Morpho Blue (0% fee, \$434M+ Base liquidity)
  * Balancer V2 Vault (0% fee)
  * Aave V3 Pool
* **DEX Routing**: Uniswap V3, Aerodrome SlipStream (Concentrated Liquidity).

---

## Quickstart & Verification Benchmark

Run the full dual-gate verification harness in a single command:

```bash
python examples/run_verification.py
```

### Expected Output:

```json
{
  "pipeline": "anthgg17-atomic-verification",
  "gate1_ast_validation": "PASSED",
  "gate2_onchain_presim": "PASSED",
  "target_chain": "Base Mainnet (8453)",
  "router_address": "0x5314a0f7317f1a5fe5ef8e593d9bfb5a8968f0a4",
  "ready_for_x402_settlement": true
}
```

---

## License

MIT
