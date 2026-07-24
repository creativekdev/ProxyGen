cmake_minimum_required(VERSION 3.16)
project(proxygen_auth LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Proxygen's exported CMake config pulls in folly/wangle/fizz transitively.
# Point CMAKE_PREFIX_PATH at the install prefix (see Dockerfile: /opt/pg).
find_package(proxygen CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)

# SQLite3: prefer CMake's module; fall back to a plain library search.
find_package(SQLite3)
if(NOT SQLite3_FOUND)
  find_library(SQLITE3_LIB NAMES sqlite3)
  find_path(SQLITE3_INC NAMES sqlite3.h)
  if(NOT SQLITE3_LIB OR NOT SQLITE3_INC)
    message(FATAL_ERROR "sqlite3 not found")
  endif()
  add_library(SQLite::SQLite3 UNKNOWN IMPORTED)
  set_target_properties(SQLite::SQLite3 PROPERTIES
    IMPORTED_LOCATION "${SQLITE3_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${SQLITE3_INC}")
endif()

add_executable(server
  src/main.cpp
  src/Auth.cpp
  src/UserDb.cpp
  src/Handlers.cpp
)

target_include_directories(server PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)

target_link_libraries(server PRIVATE
  proxygen::proxygenhttpserver
  proxygen::proxygen
  SQLite::SQLite3
  OpenSSL::SSL
  OpenSSL::Crypto
)

install(TARGETS server RUNTIME DESTINATION bin)
