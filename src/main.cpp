// Entry point: configures and starts the Proxygen HTTP server.
#include <folly/SocketAddress.h>
#include <folly/init/Init.h>
#include <folly/portability/GFlags.h>
#include <glog/logging.h>
#include <proxygen/httpserver/HTTPServer.h>
#include <proxygen/httpserver/HTTPServerOptions.h>

#include <csignal>
#include <filesystem>
#include <thread>
#include <vector>

#include "Handlers.h"
#include "UserDb.h"

using namespace proxygen;

DEFINE_int32(port, 8080, "Port to listen on for HTTP");
DEFINE_string(host, "0.0.0.0", "Address to bind to");
DEFINE_int32(threads, 0, "Number of worker threads (0 = hardware concurrency)");
DEFINE_string(db, "data/users.db", "Path to the SQLite database file");
DEFINE_string(static_dir, "static", "Directory of static files to serve");

int main(int argc, char* argv[]) {
  folly::Init init(&argc, &argv, /*removeFlags=*/true);

  // Make sure the directory holding the SQLite file exists.
  try {
    std::filesystem::path dbPath(FLAGS_db);
    if (dbPath.has_parent_path()) {
      std::filesystem::create_directories(dbPath.parent_path());
    }
  } catch (const std::exception& e) {
    LOG(FATAL) << "cannot create database directory: " << e.what();
  }

  std::shared_ptr<app::UserDb> db;
  try {
    db = std::make_shared<app::UserDb>(FLAGS_db);
  } catch (const std::exception& e) {
    LOG(FATAL) << "failed to open database: " << e.what();
  }

  const int32_t threads =
      FLAGS_threads > 0
          ? FLAGS_threads
          : static_cast<int32_t>(std::max(1u, std::thread::hardware_concurrency()));

  std::vector<HTTPServer::IPConfig> IPs = {
      {folly::SocketAddress(FLAGS_host, FLAGS_port, /*allowNameLookup=*/true),
       HTTPServer::Protocol::HTTP},
  };

  HTTPServerOptions options;
  options.threads = static_cast<size_t>(threads);
  options.idleTimeout = std::chrono::milliseconds(60000);
  options.shutdownOn = {SIGINT, SIGTERM};
  options.enableContentCompression = false;
  options.handlerFactories =
      RequestHandlerChain()
          .addThen<app::AuthHandlerFactory>(db, FLAGS_static_dir)
          .build();

  HTTPServer server(std::move(options));
  server.bind(IPs);

  LOG(INFO) << "proxygen auth server listening on " << FLAGS_host << ":"
            << FLAGS_port << " (" << threads << " threads)";

  // start() blocks until the server is stopped via a shutdown signal.
  std::thread serverThread([&]() { server.start(); });
  serverThread.join();

  LOG(INFO) << "server stopped";
  return 0;
}
