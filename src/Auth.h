// Password hashing and secure-token helpers built on OpenSSL.
// Portable across Linux/macOS/Windows — used identically inside the container.
#pragma once

#include <string>

namespace auth {

// Hash a plaintext password with PBKDF2-HMAC-SHA256 and a fresh random salt.
// Returns an encoded string of the form:
//   pbkdf2_sha256$<iterations>$<salt_hex>$<hash_hex>
// The whole string is what you persist; it is self-describing for verification.
std::string hashPassword(const std::string& password);

// Verify a plaintext password against a previously stored encoded hash.
// Returns false on any parse error or mismatch. Comparison is constant-time.
bool verifyPassword(const std::string& password, const std::string& encoded);

// Generate a cryptographically-random token as a lowercase hex string.
// `numBytes` is the entropy size; the returned string is 2*numBytes chars.
std::string randomToken(size_t numBytes = 32);

} // namespace auth
