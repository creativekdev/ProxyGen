cmake_minimum_required(VERSION 3.16)
project(proxygen_auth LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# --- Resolve getdeps' multi-prefix install layout ---------------------------
# getdeps installs each dependency into its OWN subdirectory of the prefix
# (e.g. <prefix>/folly, <prefix>/fizz, <prefix>/libsodium) rather than a single
# merged tree. So we must:
#   1. add every such subdirectory to CMAKE_PREFIX_PATH, so config packages AND
#      transitive find_library() calls (libsodium, zstd, …) resolve, and
#   2. put fizz's bundled FindSodium.cmake on CMAKE_MODULE_PATH, so the
#      transitive find_dependency(Sodium) from fizz-config.cmake succeeds.
set(_pg_roots ${CMAKE_PREFIX_PATH})
foreach(_root IN LISTS _pg_roots)
  file(GLOB _children LIST_DIRECTORIES true "${_root}/*")
  foreach(_child ${_children})
    if(IS_DIRECTORY "${_child}")
      list(APPEND CMAKE_PREFIX_PATH "${_child}")
    endif()
  endforeach()
  file(GLOB_RECURSE _find_sodium "${_root}/*FindSodium.cmake")
  foreach(_fs ${_find_sodium})
    get_filename_component(_fs_dir "${_fs}" DIRECTORY)
    list(APPEND CMAKE_MODULE_PATH "${_fs_dir}")
  endforeach()
endforeach()
if(CMAKE_PREFIX_PATH)
  list(REMOVE_DUPLICATES CMAKE_PREFIX_PATH)
endif()
if(CMAKE_MODULE_PATH)
  list(REMOVE_DUPLICATES CMAKE_MODULE_PATH)
endif()
message(STATUS "CMAKE_PREFIX_PATH = ${CMAKE_PREFIX_PATH}")
message(STATUS "CMAKE_MODULE_PATH = ${CMAKE_MODULE_PATH}")

# Proxygen's exported CMake config pulls in folly/wangle/fizz transitively.
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

# Embed an RPATH to the Proxygen install prefix so the binary finds its shared
# libraries without needing LD_LIBRARY_PATH set. Derived from CMAKE_PREFIX_PATH.
set(_rpaths "")
foreach(_p IN LISTS CMAKE_PREFIX_PATH)
  list(APPEND _rpaths "${_p}/lib" "${_p}/lib64")
endforeach()
if(_rpaths)
  set_target_properties(server PROPERTIES
    BUILD_RPATH "${_rpaths}"
    INSTALL_RPATH "${_rpaths}")
endif()

target_link_libraries(server PRIVATE
  proxygen::proxygenhttpserver
  proxygen::proxygen
  SQLite::SQLite3
  OpenSSL::SSL
  OpenSSL::Crypto
)

install(TARGETS server RUNTIME DESTINATION bin)
