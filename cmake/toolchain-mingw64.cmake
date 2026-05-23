# Cross-compilation toolchain: macOS -> Windows (x86_64) via MinGW-w64
#
# Usage:
#   brew install mingw-w64
#   cmake -B build-win -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mingw64.cmake
#   cmake --build build-win

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Find the MinGW prefix - Homebrew may install to different locations
find_program(_MINGW_GCC x86_64-w64-mingw32-gcc)
if(NOT _MINGW_GCC)
    message(FATAL_ERROR
        "x86_64-w64-mingw32-gcc not found. Install with: brew install mingw-w64")
endif()
get_filename_component(_MINGW_BIN_DIR "${_MINGW_GCC}" DIRECTORY)

set(CMAKE_C_COMPILER   x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  x86_64-w64-mingw32-windres)

# Static linking so the .exe doesn't need MinGW runtime DLLs
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")

# Search paths: only look in MinGW sysroot for libs/headers
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
