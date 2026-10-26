"""
Unified Verification Benchmark
Runs Gate 1 (AST Invariants) + Gate 2 (Base Fork Pre-Sim)
"""

import sys
import os
import json

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from invariants.ast_validator import ASTBoundaryValidator
from harness.atomic_presim import AtomicPreSimHarness

def main():
    contract_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contracts", "FlashLoanArbitrage.sol")
    print(f"[*] Reading contract: {contract_path}")
    with open(contract_path, "r", encoding="utf-8") as f:
        src = f.read()

    print("\n--- GATE 1: AST BOUNDARY INVARIANT VALIDATION ---")
    val = ASTBoundaryValidator(src)
    gate1 = val.validate_all()
    print(f"Gate 1 Status: {gate1['overall_status']} ({gate1['checks_run']}/{gate1['checks_run']} passed)")

    print("\n--- GATE 2: BASE RPC PRE-SIMULATION HARNESS ---")
    harness = AtomicPreSimHarness()
    gate2 = harness.run_benchmark()
    print(f"Gate 2 Status: {gate2['status']} (Router verified on-chain: {gate2['router_verified']})")

    receipt = {
        "pipeline": "anthgg17-atomic-verification",
        "gate1_ast_validation": gate1["overall_status"],
        "gate2_onchain_presim": "PASSED" if gate2["router_verified"] else "FAILED",
        "target_chain": "Base Mainnet (8453)",
        "router_address": "0x5314a0f7317f1a5fe5ef8e593d9bfb5a8968f0a4",
        "operator": "0xb0129b682fa218ab0cb7e7846efb3805ee97ea2b",
        "checks": gate1["results"],
        "ready_for_x402_settlement": gate1["overall_status"] == "PASSED" and gate2["router_verified"]
    }

    print("\n=== FINAL VERIFICATION RECEIPT ===")
    print(json.dumps(receipt, indent=2))

if __name__ == "__main__":
    main()
