"""
Idempotency Engine & Pre-Sign Calldata Shield
Implements RFC 8785 Canonical JSON Digest, 24h zero-credit replay cache,
parameter drift detection (409 IDEMPOTENCY_PARAMETER_MISMATCH),
and Unicode NFKC + Plane 14 prompt/calldata sanitization.
"""

import hashlib
import json
import time
import unicodedata
import re
from typing import Dict, Any, Optional, Tuple


class CanonicalRequestHasher:
    @staticmethod
    def canonical_digest(data: Dict[str, Any]) -> str:
        """
        RFC 8785 Canonical JSON Serialization (JCS) deterministic hash.
        Sorts keys recursively, eliminates whitespace, and hashes via SHA-256.
        """
        canonical_str = json.dumps(data, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
        return hashlib.sha256(canonical_str.encode('utf-8')).hexdigest()


class PreSignCalldataShield:
    # Plane 14 tag characters (U+E0001 to U+E007F) used for prompt injection / steganography
    PLANE_14_REGEX = re.compile(r'[\U000e0001-\U000e007f]')
    
    # Prohibited wallet draining and signature theft selectors
    PROHIBITED_SELECTORS = [
        "transferWithAuthorization",
        "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
        "pay_lightning_invoice",
        "eth_sendTransaction",
        "export_private_key"
    ]

    @classmethod
    def sanitize_payload(cls, raw_payload: str) -> Tuple[bool, str, Optional[str]]:
        """
        Normalizes input under Unicode NFKC, strips Plane 14 hidden tags,
        and verifies that calldata doesn't contain unauthorized draining patterns.
        """
        # 1. Unicode NFKC normalization
        normalized = unicodedata.normalize('NFKC', raw_payload)
        
        # 2. Strip Plane 14 invisible Unicode tags
        cleaned = cls.PLANE_14_REGEX.sub('', normalized)
        
        # 3. Check for drainer patterns in string representation
        for prohibited in cls.PROHIBITED_SELECTORS:
            if prohibited.lower() in cleaned.lower():
                return False, cleaned, f"Blocked unauthorized drainer instruction: {prohibited}"

        return True, cleaned, None


class IdempotencyCache:
    def __init__(self, ttl_seconds: int = 86400):  # 24 hours
        self.ttl = ttl_seconds
        # Maps idempotency_key -> (timestamp, canonical_sha256, cached_receipt)
        self.store: Dict[str, Tuple[float, str, Dict[str, Any]]] = {}

    def process_request(
        self,
        idempotency_key: str,
        request_payload: Dict[str, Any],
        compute_fn
    ) -> Tuple[int, Dict[str, Any], Dict[str, str]]:
        now = time.time()
        request_sha256 = CanonicalRequestHasher.canonical_digest(request_payload)

        # Clean expired entries
        expired = [k for k, v in self.store.items() if now - v[0] > self.ttl]
        for k in expired:
            del self.store[k]

        if idempotency_key in self.store:
            stored_time, stored_sha256, cached_receipt = self.store[idempotency_key]
            
            # Check for parameter drift
            if stored_sha256 != request_sha256:
                return (
                    409,
                    {
                        "error": "IDEMPOTENCY_PARAMETER_MISMATCH",
                        "message": "Parameters in replay do not match original intent digest.",
                        "idempotency_key": idempotency_key,
                        "stored_sha256": stored_sha256,
                        "current_sha256": request_sha256
                    },
                    {"X-Idempotent-Replay": "error"}
                )

            # Replay within 24h at zero credits
            headers = {
                "X-Idempotent-Replay": "true",
                "X-Charged-Credits": "0",
                "X-Cached-At": str(int(stored_time))
            }
            return 200, cached_receipt, headers

        # Execute fresh computation
        result = compute_fn(request_payload)
        self.store[idempotency_key] = (now, request_sha256, result)
        
        headers = {
            "X-Idempotent-Replay": "false",
            "X-Charged-Credits": "1",
            "X-Artifact-Digest": request_sha256
        }
        return 200, result, headers


if __name__ == "__main__":
    # Self-test benchmark
    test_req = {
        "router": "0x5314a0f7317f1a5fe5ef8e593d9bfb5a8968f0a4",
        "loan_amount": 1000000000,
        "token": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    }
    digest = CanonicalRequestHasher.canonical_digest(test_req)
    print(f"[*] RFC 8785 Digest: {digest}")

    shield = PreSignCalldataShield()
    ok, cleaned, err = shield.sanitize_payload("Execute swap on Uniswap V3 \U000e0001\U000e0020")
    print(f"[*] Sanitizer check: OK={ok}, Cleaned length={len(cleaned)}")

    cache = IdempotencyCache()
    code1, res1, h1 = cache.process_request("key-123", test_req, lambda r: {"status": "SUCCESS", "net_profit": 42000})
    print(f"[*] Call 1: HTTP {code1}, Headers={h1}")

    code2, res2, h2 = cache.process_request("key-123", test_req, lambda r: {"status": "SUCCESS"})
    print(f"[*] Call 2 (24h replay): HTTP {code2}, Headers={h2}")
