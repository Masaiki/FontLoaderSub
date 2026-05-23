#include "font_loader.h"
#include "font_set.h"

#include <Windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define MAKE_TAG(a, b, c, d)                                             \
  ((uint32_t)(((uint8_t)(d) << 24)) | (uint32_t)(((uint8_t)(c) << 16)) | \
   (uint32_t)(((uint8_t)(b) << 8)) | (uint32_t)(((uint8_t)(a))))

typedef struct {
  uint32_t magic;
  FS_Stat stat;
  uint32_t size;
} TestCacheHeader;

static void *test_realloc(void *existing, size_t size, void *arg) {
  HANDLE heap = (HANDLE)arg;
  if (size == 0) {
    HeapFree(heap, 0, existing);
    return NULL;
  }
  if (existing == NULL)
    return HeapAlloc(heap, HEAP_ZERO_MEMORY, size);
  return HeapReAlloc(heap, HEAP_ZERO_MEMORY, existing, size);
}

static int append_wstr(wchar_t *buf, size_t *pos, const wchar_t *str) {
  while (*str) {
    buf[(*pos)++] = *str++;
  }
  buf[(*pos)++] = 0;
  buf[(*pos)++] = L'\n';
  return 1;
}

static int write_stale_cache(const wchar_t *path) {
  wchar_t payload[128];
  size_t pos = 0;
  append_wstr(payload, &pos, L"old.ttf");
  append_wstr(payload, &pos, L"\tt:ttf");
  append_wstr(payload, &pos, L"\tv:1.0");
  append_wstr(payload, &pos, L"Old Face");
  append_wstr(payload, &pos, L"");

  TestCacheHeader head = {
      .magic = MAKE_TAG('f', 'l', 'd', 'd'),
      .stat = {.num_file = 1, .num_face = 1},
      .size = (uint32_t)(sizeof head + pos * sizeof payload[0])};

  HANDLE f = CreateFileW(
      path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE)
    return 0;
  DWORD written = 0;
  int ok = WriteFile(f, &head, sizeof head, &written, NULL) &&
           WriteFile(f, payload, pos * sizeof payload[0], &written, NULL);
  CloseHandle(f);
  return ok;
}

int wmain(void) {
  wchar_t temp[MAX_PATH];
  wchar_t dir[MAX_PATH];
  wchar_t cache[MAX_PATH];
  wchar_t font[MAX_PATH];
  if (!GetTempPathW(_countof(temp), temp)) {
    fwprintf(stderr, L"GetTempPathW failed\n");
    return 2;
  }
  if (!GetTempFileNameW(temp, L"fls", 0, dir)) {
    fwprintf(stderr, L"GetTempFileNameW failed\n");
    return 2;
  }
  DeleteFileW(dir);
  if (!CreateDirectoryW(dir, NULL)) {
    fwprintf(stderr, L"CreateDirectoryW failed: %lu\n", GetLastError());
    return 2;
  }

  wsprintfW(cache, L"%s\\fc-subs.db", dir);
  wsprintfW(font, L"%s\\new.ttf", dir);

  HANDLE f = CreateFileW(
      font, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) {
    fwprintf(stderr, L"Create fake font failed: %lu\n", GetLastError());
    return 2;
  }
  DWORD written = 0;
  WriteFile(f, "fake", 4, &written, NULL);
  CloseHandle(f);

  if (!write_stale_cache(cache)) {
    fwprintf(stderr, L"write_stale_cache failed\n");
    return 2;
  }

  HANDLE heap = HeapCreate(0, 0, 0);
  allocator_t alloc = {.alloc = test_realloc, .arg = heap};
  FL_LoaderCtx ctx;
  int r = fl_init(&ctx, &alloc);
  if (r != FL_OK) {
    fwprintf(stderr, L"fl_init failed: %d\n", r);
    return 2;
  }

  r = fl_scan_fonts(&ctx, dir, L"fc-subs.db", NULL);
  FS_Stat stat = {0};
  if (ctx.font_set)
    fs_stat(ctx.font_set, &stat);

  fl_free(&ctx);
  HeapDestroy(heap);
  DeleteFileW(font);
  DeleteFileW(cache);
  RemoveDirectoryW(dir);

  if (r == FL_OK || stat.num_face != 0) {
    fwprintf(
        stderr,
        L"stale cache was accepted: r=%d files=%u faces=%u\n",
        r,
        stat.num_file,
        stat.num_face);
    return 1;
  }
  return 0;
}
