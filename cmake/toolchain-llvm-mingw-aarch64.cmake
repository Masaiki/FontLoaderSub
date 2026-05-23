# Cross-compilation toolchain: macOS -> Windows ARM64 via llvm-mingw
#
# Prerequisites:
#   Download llvm-mingw from https://github.com/mstorsjo/llvm-mingw/releases
#   Extract to ~/llvm-mingw (or set LLVM_MINGW_PREFIX)
#
# Usage:
#   cmake -B build-win-arm64 -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-llvm-mingw-aarch64.cmake
#   cmake --build build-win-arm64

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Allow override via -DLLVM_MINGW_PREFIX=...
if(NOT DEFINED LLVM_MINGW_PREFIX)
    set(LLVM_MINGW_PREFIX "$ENV{HOME}/llvm-mingw")
endif()

if(NOT EXISTS "${LLVM_MINGW_PREFIX}/bin/aarch64-w64-mingw32-clang")
    message(FATAL_ERROR
        "aarch64-w64-mingw32-clang not found at ${LLVM_MINGW_PREFIX}/bin.\n"
        "Download llvm-mingw from https://github.com/mstorsjo/llvm-mingw/releases\n"
        "and extract to ~/llvm-mingw, or pass -DLLVM_MINGW_PREFIX=<path>")
endif()

set(TOOLCHAIN_PREFIX aarch64-w64-mingw32)

set(CMAKE_C_COMPILER   "${LLVM_MINGW_PREFIX}/bin/${TOOLCHAIN_PREFIX}-clang")
set(CMAKE_CXX_COMPILER "${LLVM_MINGW_PREFIX}/bin/${TOOLCHAIN_PREFIX}-clang++")
set(CMAKE_RC_COMPILER  "${LLVM_MINGW_PREFIX}/bin/${TOOLCHAIN_PREFIX}-windres")

# Static linking so the .exe is self-contained
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")

set(CMAKE_FIND_ROOT_PATH "${LLVM_MINGW_PREFIX}/${TOOLCHAIN_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
