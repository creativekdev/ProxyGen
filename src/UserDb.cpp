#include "UserDb.h"

#include <sqlite3.h>

#include <ctime>
#include <stdexcept>

#include "Auth.h"

namespace app {
namespace {

// RAII wrapper for a prepared statement so early returns can't leak it.
class Stmt {
 public:
  Stmt(sqlite3* db, const char* sql) {
    if (sqlite3_prepare_v2(db, sql, -1, &stmt_, nullptr) != SQLITE_OK) {
      throw std::runtime_error(std::string("prepare failed: ") +
                               sqlite3_errmsg(db));
    }
  }
  ~Stmt() {
    if (stmt_) {
      sqlite3_finalize(stmt_);
    }
  }
  Stmt(const Stmt&) = delete;
  Stmt& operator=(const Stmt&) = delete;

  void bindText(int i, const std::string& v) {
    sqlite3_bind_text(stmt_, i, v.data(), static_cast<int>(v.size()),
                      SQLITE_TRANSIENT);
  }
  void bindInt64(int i, int64_t v) { sqlite3_bind_int64(stmt_, i, v); }

  int step() { return sqlite3_step(stmt_); }

  int64_t columnInt64(int i) { return sqlite3_column_int64(stmt_, i); }
  std::string columnText(int i) {
    const unsigned char* t = sqlite3_column_text(stmt_, i);
    int n = sqlite3_column_bytes(stmt_, i);
    return t ? std::string(reinterpret_cast<const char*>(t), n) : std::string();
  }

  sqlite3_stmt* raw() { return stmt_; }

 private:
  sqlite3_stmt* stmt_{nullptr};
};

bool validUsername(const std::string& u) {
  if (u.size() < 3 || u.size() > 64) {
    return false;
  }
  for (char c : u) {
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
    if (!ok) {
      return false;
    }
  }
  return true;
}

} // namespace

UserDb::UserDb(const std::string& path) {
  int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
  if (sqlite3_open_v2(path.c_str(), &db_, flags, nullptr) != SQLITE_OK) {
    std::string msg = db_ ? sqlite3_errmsg(db_) : "unknown error";
    if (db_) {
      sqlite3_close(db_);
      db_ = nullptr;
    }
    throw std::runtime_error("failed to open database '" + path + "': " + msg);
  }

  exec("PRAGMA journal_mode=WAL;");
  exec("PRAGMA foreign_keys=ON;");
  exec(
      "CREATE TABLE IF NOT EXISTS users ("
      "  id            INTEGER PRIMARY KEY AUTOINCREMENT,"
      "  username      TEXT NOT NULL UNIQUE COLLATE NOCASE,"
      "  password_hash TEXT NOT NULL,"
      "  created_at    INTEGER NOT NULL"
      ");");
  exec(
      "CREATE TABLE IF NOT EXISTS sessions ("
      "  token      TEXT PRIMARY KEY,"
      "  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,"
      "  expires_at INTEGER NOT NULL"
      ");");
  exec("CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);");
}

UserDb::~UserDb() {
  if (db_) {
    sqlite3_close(db_);
  }
}

void UserDb::exec(const char* sql) {
  char* err = nullptr;
  if (sqlite3_exec(db_, sql, nullptr, nullptr, &err) != SQLITE_OK) {
    std::string msg = err ? err : "unknown error";
    sqlite3_free(err);
    throw std::runtime_error(std::string("exec failed: ") + msg);
  }
}

AuthResult UserDb::createUser(const std::string& username,
                              const std::string& password) {
  AuthResult r;
  if (!validUsername(username)) {
    r.error =
        "username must be 3-64 chars, letters/digits/._- only";
    return r;
  }
  if (password.size() < 8 || password.size() > 256) {
    r.error = "password must be 8-256 characters";
    return r;
  }

  std::string hash = auth::hashPassword(password);
  int64_t now = static_cast<int64_t>(std::time(nullptr));

  std::lock_guard<std::mutex> lock(mu_);
  Stmt stmt(db_,
            "INSERT INTO users(username, password_hash, created_at) "
            "VALUES(?, ?, ?);");
  stmt.bindText(1, username);
  stmt.bindText(2, hash);
  stmt.bindInt64(3, now);

  int rc = stmt.step();
  if (rc == SQLITE_CONSTRAINT) {
    r.error = "username is already taken";
    return r;
  }
  if (rc != SQLITE_DONE) {
    r.error = std::string("database error: ") + sqlite3_errmsg(db_);
    return r;
  }

  r.ok = true;
  r.userId = sqlite3_last_insert_rowid(db_);
  r.username = username;
  return r;
}

AuthResult UserDb::verifyUser(const std::string& username,
                              const std::string& password) {
  AuthResult r;
  std::lock_guard<std::mutex> lock(mu_);
  Stmt stmt(db_,
            "SELECT id, username, password_hash FROM users "
            "WHERE username = ? COLLATE NOCASE;");
  stmt.bindText(1, username);

  int rc = stmt.step();
  if (rc == SQLITE_ROW) {
    int64_t id = stmt.columnInt64(0);
    std::string canonicalName = stmt.columnText(1);
    std::string hash = stmt.columnText(2);
    if (auth::verifyPassword(password, hash)) {
      r.ok = true;
      r.userId = id;
      r.username = canonicalName;
      return r;
    }
  }
  // Same generic message whether the user is missing or the password is wrong,
  // so we don't reveal which usernames exist.
  r.error = "invalid username or password";
  return r;
}

std::string UserDb::createSession(int64_t userId, int64_t ttlSeconds) {
  std::string token = auth::randomToken(32);
  int64_t expires = static_cast<int64_t>(std::time(nullptr)) + ttlSeconds;

  std::lock_guard<std::mutex> lock(mu_);
  Stmt stmt(db_,
            "INSERT INTO sessions(token, user_id, expires_at) "
            "VALUES(?, ?, ?);");
  stmt.bindText(1, token);
  stmt.bindInt64(2, userId);
  stmt.bindInt64(3, expires);
  if (stmt.step() != SQLITE_DONE) {
    throw std::runtime_error(std::string("failed to create session: ") +
                             sqlite3_errmsg(db_));
  }
  return token;
}

SessionInfo UserDb::lookupSession(const std::string& token) {
  SessionInfo info;
  if (token.empty()) {
    return info;
  }
  int64_t now = static_cast<int64_t>(std::time(nullptr));

  std::lock_guard<std::mutex> lock(mu_);
  Stmt stmt(db_,
            "SELECT u.id, u.username FROM sessions s "
            "JOIN users u ON u.id = s.user_id "
            "WHERE s.token = ? AND s.expires_at > ?;");
  stmt.bindText(1, token);
  stmt.bindInt64(2, now);

  if (stmt.step() == SQLITE_ROW) {
    info.found = true;
    info.userId = stmt.columnInt64(0);
    info.username = stmt.columnText(1);
  }
  return info;
}

void UserDb::deleteSession(const std::string& token) {
  if (token.empty()) {
    return;
  }
  std::lock_guard<std::mutex> lock(mu_);
  Stmt stmt(db_, "DELETE FROM sessions WHERE token = ?;");
  stmt.bindText(1, token);
  stmt.step();
}

} // namespace app
