#pragma once

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <Windows.h>
#  define OS_PATH_SEP      L"\\"
#  define OS_PATH_SEP_CHAR L'\\'
#else
#  include <stddef.h>
#  include <stdint.h>
#  include <stdlib.h>
// Use -fshort-wchar so that wchar_t is 2 bytes (UTF-16) on macOS,
// matching the Windows behaviour assumed throughout the code base.
#  define OS_PATH_SEP      L"/"
#  define OS_PATH_SEP_CHAR L'/'
#endif
