// Thread-safe SQLite-backed store for users and login sessions.
//
// Proxygen serves each request on one of several worker EventBase threads, so
// every public method here is guarded by an internal mutex. Auth traffic is low
// volume, so a single serialized connection is more than fast enough and keeps
// the concurrency story trivially correct.
#pragma once

#include <cstdint>
#include <mutex>
#include <string>

struct sqlite3;

namespace app {

struct AuthResult {
  bool ok{false};
  std::string error;      // human-readable reason when ok == false
  int64_t userId{0};      // populated when ok == true
  std::string username;   // populated when ok == true
};

struct SessionInfo {
  bool found{false};
  int64_t userId{0};
  std::string username;
};

class UserDb {
 public:
  // Opens (creating if needed) the SQLite database at `path` and ensures the
  // schema exists. Throws std::runtime_error on failure.
  explicit UserDb(const std::string& path);
  ~UserDb();

  UserDb(const UserDb&) = delete;
  UserDb& operator=(const UserDb&) = delete;

  // Creates a new account. Fails if the username already exists or the input is
  // invalid. On success returns the new user's id and username.
  AuthResult createUser(const std::string& username, const std::string& password);

  // Verifies credentials. On success returns the user's id and username.
  AuthResult verifyUser(const std::string& username, const std::string& password);

  // Creates a session for `userId` valid for `ttlSeconds` and returns its token.
  std::string createSession(int64_t userId, int64_t ttlSeconds);

  // Looks up an unexpired session by token.
  SessionInfo lookupSession(const std::string& token);

  // Deletes a session (logout). Safe to call with an unknown token.
  void deleteSession(const std::string& token);

 private:
  void exec(const char* sql);

  sqlite3* db_{nullptr};
  std::mutex mu_;
};

} // namespace app
