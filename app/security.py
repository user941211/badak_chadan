import hashlib
import hmac
import os
from typing import Final

_ALGORITHM: Final[str] = "pbkdf2_sha256"
_ITERATIONS: Final[int] = 310_000
_SALT_BYTES: Final[int] = 16


def hash_password(password: str) -> str:
    salt = os.urandom(_SALT_BYTES)
    derived = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        _ITERATIONS,
    )
    return f"{_ALGORITHM}${_ITERATIONS}${salt.hex()}${derived.hex()}"


def verify_password(password: str, stored_hash: str) -> bool:
    try:
        algorithm, iter_text, salt_hex, digest_hex = stored_hash.split("$", 3)
        if algorithm != _ALGORITHM:
            return False
        iterations = int(iter_text)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except (ValueError, TypeError):
        return False

    actual = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        iterations,
    )
    return hmac.compare_digest(actual, expected)
