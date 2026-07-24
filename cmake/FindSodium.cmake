# Minimal FindSodium.cmake to satisfy fizz's transitive find_dependency(Sodium).
#
# fizz/mvfst/proxygen were built against libsodium, and their exported CMake
# config files call find_dependency(Sodium), which needs a FindSodium.cmake on
# CMAKE_MODULE_PATH that (a) sets Sodium_FOUND and (b) creates the imported
# target named `sodium` that fizz's targets link against.
#
# libsodium itself is located via CMAKE_PREFIX_PATH (getdeps installs it under
# <prefix>/libsodium, which the top-level CMakeLists adds to the prefix path).

include(FindPackageHandleStandardArgs)

find_path(sodium_INCLUDE_DIR
  NAMES sodium.h
  PATH_SUFFIXES include)

find_library(sodium_LIBRARY
  NAMES sodium libsodium
  PATH_SUFFIXES lib lib64)

# Package name here is "Sodium" (capital S) so that Sodium_FOUND is set, which is
# what find_dependency(Sodium) checks.
find_package_handle_standard_args(Sodium
  REQUIRED_VARS sodium_LIBRARY sodium_INCLUDE_DIR)

if(Sodium_FOUND)
  set(sodium_INCLUDE_DIRS "${sodium_INCLUDE_DIR}")
  set(sodium_LIBRARIES "${sodium_LIBRARY}")
  if(NOT TARGET sodium)
    add_library(sodium UNKNOWN IMPORTED)
    set_target_properties(sodium PROPERTIES
      IMPORTED_LOCATION "${sodium_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${sodium_INCLUDE_DIR}")
  endif()
endif()

mark_as_advanced(sodium_INCLUDE_DIR sodium_LIBRARY)
