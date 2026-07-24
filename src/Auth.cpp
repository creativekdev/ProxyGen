#include "Auth.h"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#include <array>
#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace auth {
namespace {

constexpr int kIterations = 210000; // OWASP-recommended floor for PBKDF2-SHA256
constexpr int kSaltBytes = 16;
constexpr int kHashBytes = 32;

std::string toHex(const unsigned char* data, size_t len) {
  static const char* kDigits = "0123456789abcdef";
  std::string out;
  out.reserve(len * 2);
  for (size_t i = 0; i < len; ++i) {
    out.push_back(kDigits[data[i] >> 4]);
    out.push_back(kDigits[data[i] & 0x0F]);
  }
  return out;
}

bool fromHex(const std::string& hex, std::vector<unsigned char>& out) {
  if (hex.size() % 2 != 0) {
    return false;
  }
  out.clear();
  out.reserve(hex.size() / 2);
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (size_t i = 0; i < hex.size(); i += 2) {
    int hi = nibble(hex[i]);
    int lo = nibble(hex[i + 1]);
    if (hi < 0 || lo < 0) {
      return false;
    }
    out.push_back(static_cast<unsigned char>((hi << 4) | lo));
  }
  return true;
}

std::vector<unsigned char> pbkdf2(const std::string& password,
                                  const unsigned char* salt,
                                  size_t saltLen,
                                  int iterations,
                                  int keyLen) {
  std::vector<unsigned char> out(keyLen);
  int rc = PKCS5_PBKDF2_HMAC(password.data(),
                             static_cast<int>(password.size()),
                             salt,
                             static_cast<int>(saltLen),
                             iterations,
                             EVP_sha256(),
                             keyLen,
                             out.data());
  if (rc != 1) {
    throw std::runtime_error("PKCS5_PBKDF2_HMAC failed");
  }
  return out;
}

} // namespace

std::string hashPassword(const std::string& password) {
  std::array<unsigned char, kSaltBytes> salt{};
  if (RAND_bytes(salt.data(), kSaltBytes) != 1) {
    throw std::runtime_error("RAND_bytes failed generating salt");
  }
  auto derived = pbkdf2(password, salt.data(), salt.size(), kIterations, kHashBytes);

  std::ostringstream oss;
  oss << "pbkdf2_sha256$" << kIterations << '$'
      << toHex(salt.data(), salt.size()) << '$'
      << toHex(derived.data(), derived.size());
  return oss.str();
}

bool verifyPassword(const std::string& password, const std::string& encoded) {
  // Split on '$' into: algo, iterations, salt_hex, hash_hex
  std::vector<std::string> parts;
  std::string cur;
  for (char c : encoded) {
    if (c == '$') {
      parts.push_back(std::move(cur));
      cur.clear();
    } else {
      cur.push_back(c);
    }
  }
  parts.push_back(std::move(cur));

  if (parts.size() != 4 || parts[0] != "pbkdf2_sha256") {
    return false;
  }

  int iterations = 0;
  try {
    iterations = std::stoi(parts[1]);
  } catch (...) {
    return false;
  }
  if (iterations <= 0) {
    return false;
  }

  std::vector<unsigned char> salt;
  std::vector<unsigned char> expected;
  if (!fromHex(parts[2], salt) || !fromHex(parts[3], expected)) {
    return false;
  }
  if (expected.empty()) {
    return false;
  }

  std::vector<unsigned char> actual;
  try {
    actual = pbkdf2(password, salt.data(), salt.size(), iterations,
                    static_cast<int>(expected.size()));
  } catch (...) {
    return false;
  }

  if (actual.size() != expected.size()) {
    return false;
  }
  // Constant-time comparison to avoid leaking match progress via timing.
  return CRYPTO_memcmp(actual.data(), expected.data(), actual.size()) == 0;
}

std::string randomToken(size_t numBytes) {
  std::vector<unsigned char> buf(numBytes);
  if (RAND_bytes(buf.data(), static_cast<int>(numBytes)) != 1) {
    throw std::runtime_error("RAND_bytes failed generating token");
  }
  return toHex(buf.data(), buf.size());
}

} // namespace auth
