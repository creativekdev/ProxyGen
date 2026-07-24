// Proxygen request handlers and the routing factory that wires them up.
#pragma once

#include <proxygen/httpserver/RequestHandler.h>
#include <proxygen/httpserver/RequestHandlerFactory.h>

#include <memory>
#include <string>

namespace app {

class UserDb;

// Creates a RequestHandler per incoming request, routed by method + path.
class AuthHandlerFactory : public proxygen::RequestHandlerFactory {
 public:
  AuthHandlerFactory(std::shared_ptr<UserDb> db, std::string staticDir);

  void onServerStart(folly::EventBase*) noexcept override {}
  void onServerStop() noexcept override {}

  proxygen::RequestHandler* onRequest(
      proxygen::RequestHandler*,
      proxygen::HTTPMessage*) noexcept override;

 private:
  std::shared_ptr<UserDb> db_;
  std::string staticDir_;
};

} // namespace app
