#pragma once

#include "util.h"
#include "cstl.h"

/* Platform-neutral file information passed to the walk callback. */
typedef struct {
  uint64_t file_size;
  int is_regular_file; /* 1 = regular file, 0 = directory / device / other */
} FL_FileInfo;

int FlResolvePath(const wchar_t *path, str_db_t *s);

size_t FlPathParent(str_db_t *path);

typedef int (
    *FL_FileWalkCb)(const wchar_t *path, const FL_FileInfo *info, void *arg);

int FlWalkDir(
    const wchar_t *path,
    allocator_t *alloc,
    FL_FileWalkCb callback,
    void *arg);

int FlWalkDirStr(str_db_t *path, FL_FileWalkCb callback, void *arg);
