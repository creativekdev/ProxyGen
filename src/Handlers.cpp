#include "Handlers.h"

#include <folly/Conv.h>
#include <folly/dynamic.h>
#include <folly/io/IOBuf.h>
#include <folly/io/IOBufQueue.h>
#include <folly/json.h>
#include <proxygen/httpserver/ResponseBuilder.h>
#include <proxygen/lib/http/HTTPMessage.h>
#include <proxygen/lib/http/HTTPMethod.h>

#include <fstream>
#include <sstream>
#include <utility>

#include "UserDb.h"

using proxygen::HTTPMessage;
using proxygen::HTTPMethod;
using proxygen::ProxygenError;
using proxygen::RequestHandler;
using proxygen::ResponseBuilder;
using proxygen::UpgradeProtocol;

namespace app {
namespace {

constexpr int64_t kSessionTtlSeconds = 7 * 24 * 60 * 60; // 7 days

// Base handler that buffers the request body and dispatches once complete.
// Subclasses implement handle(); helpers cover the JSON + cookie plumbing.
class BaseHandler : public RequestHandler {
 public:
  void onRequest(std::unique_ptr<HTTPMessage> headers) noexcept override {
    headers_ = std::move(headers);
  }
  void onBody(std::unique_ptr<folly::IOBuf> body) noexcept override {
    body_.append(std::move(body));
  }
  void onUpgrade(UpgradeProtocol) noexcept override {}
  void requestComplete() noexcept override { delete this; }
  void onError(ProxygenError) noexcept override { delete this; }

  void onEOM() noexcept override {
    try {
      handle();
    } catch (const std::exception&) {
      sendJson(500, folly::dynamic::object("error", "internal error"));
    }
  }

 protected:
  virtual void handle() = 0;

  std::string bodyString() {
    auto buf = body_.move();
    if (!buf) {
      return {};
    }
    // Coalesce the (possibly chained) IOBuf into a single std::string.
    return folly::to<std::string>(buf->moveToFbString());
  }

  std::string sessionCookie() const {
    auto c = headers_->getCookie("session");
    return c.str();
  }

  // Reads a string field from a JSON object, returning "" if missing/non-string.
  static std::string jsonStr(const folly::dynamic& obj, const char* key) {
    auto* p = obj.get_ptr(key);
    if (!p || !p->isString()) {
      return {};
    }
    return folly::to<std::string>(p->asString());
  }

  void sendJson(int status, const folly::dynamic& obj,
                const std::string& extraHeaderName = {},
                const std::string& extraHeaderValue = {}) {
    ResponseBuilder builder(downstream_);
    builder.status(status, status == 200 ? "OK" : "Error")
        .header("Content-Type", "application/json; charset=utf-8");
    if (!extraHeaderName.empty()) {
      builder.header(extraHeaderName, extraHeaderValue);
    }
    builder.body(folly::to<std::string>(folly::toJson(obj))).sendWithEOM();
  }

  // Parse the buffered body as a JSON object. Returns false and fills `err`
  // when the body is missing or not a JSON object.
  bool parseJsonBody(folly::dynamic& out, std::string& err) {
    std::string body = bodyString();
    if (body.empty()) {
      err = "request body is empty";
      return false;
    }
    try {
      out = folly::parseJson(body);
    } catch (const std::exception&) {
      err = "request body is not valid JSON";
      return false;
    }
    if (!out.isObject()) {
      err = "request body must be a JSON object";
      return false;
    }
    return true;
  }

  std::unique_ptr<HTTPMessage> headers_;
  folly::IOBufQueue body_{folly::IOBufQueue::cacheChainLength()};
};

std::string sessionSetCookie(const std::string& token, int64_t maxAgeSeconds) {
  std::ostringstream oss;
  oss << "session=" << token
      << "; HttpOnly; Path=/; SameSite=Lax; Max-Age=" << maxAgeSeconds;
  return oss.str();
}

std::string clearSessionCookie() {
  return "session=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0";
}

// ---- POST /api/signup ----
class SignupHandler : public BaseHandler {
 public:
  explicit SignupHandler(std::shared_ptr<UserDb> db) : db_(std::move(db)) {}

 protected:
  void handle() override {
    folly::dynamic json;
    std::string err;
    if (!parseJsonBody(json, err)) {
      sendJson(400, folly::dynamic::object("error", err));
      return;
    }
    std::string username = jsonStr(json, "username");
    std::string password = jsonStr(json, "password");

    auto res = db_->createUser(username, password);
    if (!res.ok) {
      sendJson(400, folly::dynamic::object("error", res.error));
      return;
    }
    auto token = db_->createSession(res.userId, kSessionTtlSeconds);
    sendJson(200,
             folly::dynamic::object("ok", true)("username", res.username),
             "Set-Cookie", sessionSetCookie(token, kSessionTtlSeconds));
  }

 private:
  std::shared_ptr<UserDb> db_;
};

// ---- POST /api/login ----
class LoginHandler : public BaseHandler {
 public:
  explicit LoginHandler(std::shared_ptr<UserDb> db) : db_(std::move(db)) {}

 protected:
  void handle() override {
    folly::dynamic json;
    std::string err;
    if (!parseJsonBody(json, err)) {
      sendJson(400, folly::dynamic::object("error", err));
      return;
    }
    std::string username = jsonStr(json, "username");
    std::string password = jsonStr(json, "password");

    auto res = db_->verifyUser(username, password);
    if (!res.ok) {
      sendJson(401, folly::dynamic::object("error", res.error));
      return;
    }
    auto token = db_->createSession(res.userId, kSessionTtlSeconds);
    sendJson(200,
             folly::dynamic::object("ok", true)("username", res.username),
             "Set-Cookie", sessionSetCookie(token, kSessionTtlSeconds));
  }

 private:
  std::shared_ptr<UserDb> db_;
};

// ---- POST /api/logout ----
class LogoutHandler : public BaseHandler {
 public:
  explicit LogoutHandler(std::shared_ptr<UserDb> db) : db_(std::move(db)) {}

 protected:
  void handle() override {
    db_->deleteSession(sessionCookie());
    sendJson(200, folly::dynamic::object("ok", true), "Set-Cookie",
             clearSessionCookie());
  }

 private:
  std::shared_ptr<UserDb> db_;
};

// ---- GET /api/me ----  (who am I / is my session valid)
class MeHandler : public BaseHandler {
 public:
  explicit MeHandler(std::shared_ptr<UserDb> db) : db_(std::move(db)) {}

 protected:
  void handle() override {
    auto info = db_->lookupSession(sessionCookie());
    if (!info.found) {
      sendJson(401, folly::dynamic::object("authenticated", false));
      return;
    }
    sendJson(200, folly::dynamic::object("authenticated", true)(
                      "username", info.username)("userId", info.userId));
  }

 private:
  std::shared_ptr<UserDb> db_;
};

// ---- Static files (GET) ----
class StaticHandler : public BaseHandler {
 public:
  StaticHandler(std::string staticDir, std::string path)
      : staticDir_(std::move(staticDir)), path_(std::move(path)) {}

 protected:
  void handle() override {
    // Normalize: "/" -> index.html, strip leading slash.
    std::string rel = path_;
    if (rel.empty() || rel == "/") {
      rel = "/index.html";
    }
    if (rel.front() == '/') {
      rel.erase(rel.begin());
    }
    // Reject path traversal outright.
    if (rel.find("..") != std::string::npos) {
      sendPlain(400, "text/plain", "bad request");
      return;
    }

    std::string full = staticDir_ + "/" + rel;
    std::ifstream in(full, std::ios::binary);
    if (!in) {
      sendPlain(404, "text/plain", "not found");
      return;
    }
    std::ostringstream ss;
    ss << in.rdbuf();

    ResponseBuilder(downstream_)
        .status(200, "OK")
        .header("Content-Type", contentType(rel))
        .body(ss.str())
        .sendWithEOM();
  }

 private:
  void sendPlain(int status, const std::string& ctype, const std::string& msg) {
    ResponseBuilder(downstream_)
        .status(status, status == 200 ? "OK" : "Error")
        .header("Content-Type", ctype)
        .body(msg)
        .sendWithEOM();
  }

  static std::string contentType(const std::string& name) {
    auto ends = [&](const char* ext) {
      size_t n = std::string(ext).size();
      return name.size() >= n && name.compare(name.size() - n, n, ext) == 0;
    };
    if (ends(".html")) return "text/html; charset=utf-8";
    if (ends(".css")) return "text/css; charset=utf-8";
    if (ends(".js")) return "application/javascript; charset=utf-8";
    if (ends(".json")) return "application/json; charset=utf-8";
    if (ends(".svg")) return "image/svg+xml";
    if (ends(".png")) return "image/png";
    if (ends(".ico")) return "image/x-icon";
    return "application/octet-stream";
  }

  std::string staticDir_;
  std::string path_;
};

// Simple fixed-response handler (used for 404 / 405).
class StatusHandler : public BaseHandler {
 public:
  StatusHandler(int status, std::string message)
      : status_(status), message_(std::move(message)) {}

 protected:
  void handle() override {
    sendJson(status_, folly::dynamic::object("error", message_));
  }

 private:
  int status_;
  std::string message_;
};

} // namespace

AuthHandlerFactory::AuthHandlerFactory(std::shared_ptr<UserDb> db,
                                       std::string staticDir)
    : db_(std::move(db)), staticDir_(std::move(staticDir)) {}

RequestHandler* AuthHandlerFactory::onRequest(
    RequestHandler*, HTTPMessage* msg) noexcept {
  const std::string path = msg->getPathAsStringPiece().str();
  const HTTPMethod method =
      msg->getMethod().value_or(HTTPMethod::GET);

  auto isPost = method == HTTPMethod::POST;
  auto isGet = method == HTTPMethod::GET;

  if (path == "/api/signup") {
    return isPost ? static_cast<RequestHandler*>(new SignupHandler(db_))
                  : new StatusHandler(405, "method not allowed");
  }
  if (path == "/api/login") {
    return isPost ? static_cast<RequestHandler*>(new LoginHandler(db_))
                  : new StatusHandler(405, "method not allowed");
  }
  if (path == "/api/logout") {
    return isPost ? static_cast<RequestHandler*>(new LogoutHandler(db_))
                  : new StatusHandler(405, "method not allowed");
  }
  if (path == "/api/me") {
    return isGet ? static_cast<RequestHandler*>(new MeHandler(db_))
                 : new StatusHandler(405, "method not allowed");
  }

  // Anything under /api/ that we didn't match is a 404 JSON.
  if (path.rfind("/api/", 0) == 0) {
    return new StatusHandler(404, "not found");
  }

  // Everything else is treated as a static-file GET request.
  if (!isGet) {
    return new StatusHandler(405, "method not allowed");
  }
  return new StaticHandler(staticDir_, path);
}

} // namespace app
