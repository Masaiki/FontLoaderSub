/* path_posix.c — POSIX directory walking and path resolution
 * Compiled only on non-Windows platforms (see CMakeLists.txt).
 * Requires -fshort-wchar so that sizeof(wchar_t) == 2. */

#include "path.h"
#include "ass_string.h"

#include <dirent.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* Forward declaration of the UTF helper defined in util_posix.c */
extern int fl_wchar_to_utf8(const wchar_t *w, char *buf, size_t sz);
extern const wchar_t *
fl_utf8_to_str_db(const char *str, str_db_t *s, allocator_t *alloc);

/* ------------------------------------------------------------------ */
/*  Path resolution                                                     */
/* ------------------------------------------------------------------ */

int FlResolvePath(const wchar_t *path, str_db_t *s) {
  char utf8_in[PATH_MAX];
  char utf8_out[PATH_MAX];

  fl_wchar_to_utf8(path, utf8_in, sizeof utf8_in);

  if (realpath(utf8_in, utf8_out) == NULL)
    return FL_OS_ERROR;

  str_db_seek(s, 0);
  if (fl_utf8_to_str_db(utf8_out, s, s->vec.alloc) == NULL)
    return FL_OUT_OF_MEMORY;

  return FL_OK;
}

/* ------------------------------------------------------------------ */
/*  FlPathParent                                                        */
/* ------------------------------------------------------------------ */

size_t FlPathParent(str_db_t *path) {
  size_t pos = str_db_tell(path);
  wchar_t *buf = (wchar_t *)str_db_get(path, 0);
  while (pos != 0 && buf[pos - 1] != OS_PATH_SEP_CHAR)
    pos--;
  buf[pos] = 0;
  str_db_seek(path, pos);
  return pos;
}

/* ------------------------------------------------------------------ */
/*  Directory walker (DFS)                                              */
/* ------------------------------------------------------------------ */

typedef struct {
  FL_FileWalkCb callback;
  void *arg;
  str_db_t path; /* holds the current wchar_t path */
  allocator_t *alloc;
} FL_WalkDirCtx;

static int WalkDirDfs(FL_WalkDirCtx *ctx) {
  /* Convert current wchar_t path to UTF-8 */
  char utf8_dir[PATH_MAX];
  fl_wchar_to_utf8(str_db_get(&ctx->path, 0), utf8_dir, sizeof utf8_dir);

  DIR *dir = opendir(utf8_dir);
  if (dir == NULL)
    return FL_OK; /* ignore errors (same as Windows version) */

  const size_t pos_root = str_db_tell(&ctx->path); /* end of "dir/" */
  int r = FL_OK;
  struct dirent *entry;

  while (r == FL_OK && (entry = readdir(dir)) != NULL) {
    /* Skip "." and ".." */
    if (entry->d_name[0] == '.' &&
        (entry->d_name[1] == '\0' ||
         (entry->d_name[1] == '.' && entry->d_name[2] == '\0'))) {
      continue;
    }

    /* Append entry name (UTF-8) to the wchar_t path */
    str_db_seek(&ctx->path, pos_root);
    if (fl_utf8_to_str_db(entry->d_name, &ctx->path, ctx->alloc) == NULL) {
      r = FL_OUT_OF_MEMORY;
      break;
    }

    /* Build the full UTF-8 path for stat */
    char full_utf8[PATH_MAX];
    fl_wchar_to_utf8(str_db_get(&ctx->path, 0), full_utf8, sizeof full_utf8);

    struct stat st;
    if (lstat(full_utf8, &st) != 0)
      continue;

    if (S_ISDIR(st.st_mode)) {
      /* Recurse: append "/" separator */
      if (str_db_push_u16_le(&ctx->path, OS_PATH_SEP, 1) == NULL) {
        r = FL_OUT_OF_MEMORY;
        break;
      }
      r = WalkDirDfs(ctx);
    } else if (S_ISREG(st.st_mode)) {
      FL_FileInfo info = {
          .file_size = (uint64_t)st.st_size,
          .is_regular_file = 1,
      };
      r = ctx->callback(str_db_get(&ctx->path, 0), &info, ctx->arg);
    }
    /* Other file types (symlinks, sockets, …) are silently skipped */
  }

  closedir(dir);
  str_db_seek(&ctx->path, pos_root);
  return r;
}

int FlWalkDir(
    const wchar_t *path,
    allocator_t *alloc,
    FL_FileWalkCb callback,
    void *arg) {
  FL_WalkDirCtx ctx = {.callback = callback, .arg = arg, .alloc = alloc};
  str_db_init(&ctx.path, alloc, 0, 0);

  int r = FL_OUT_OF_MEMORY;
  do {
    char utf8_root[PATH_MAX];
    fl_wchar_to_utf8(path, utf8_root, sizeof utf8_root);

    /* Seed str_db with root path */
    if (fl_utf8_to_str_db(utf8_root, &ctx.path, alloc) == NULL)
      break;

    struct stat st;
    if (lstat(utf8_root, &st) != 0) {
      r = FL_OK;
      break;
    }

    if (S_ISREG(st.st_mode)) {
      /* Single file — fire callback directly */
      FL_FileInfo info = {
          .file_size = (uint64_t)st.st_size, .is_regular_file = 1};
      r = callback(str_db_get(&ctx.path, 0), &info, arg);
    } else if (S_ISDIR(st.st_mode)) {
      /* Directory — append "/" and walk */
      if (str_db_push_u16_le(&ctx.path, OS_PATH_SEP, 1) == NULL) {
        r = FL_OUT_OF_MEMORY;
        break;
      }
      r = WalkDirDfs(&ctx);
    } else {
      r = FL_OK;
    }
  } while (0);

  str_db_free(&ctx.path);
  return r;
}

int FlWalkDirStr(str_db_t *path, FL_FileWalkCb callback, void *arg) {
  char utf8_path[PATH_MAX];
  fl_wchar_to_utf8(str_db_get(path, 0), utf8_path, sizeof utf8_path);

  struct stat st;
  if (lstat(utf8_path, &st) != 0)
    return FL_OK; /* path doesn't exist — ignore silently */

  if (S_ISREG(st.st_mode)) {
    /* Single file — fire callback directly without touching *path */
    FL_FileInfo info = {
        .file_size = (uint64_t)st.st_size, .is_regular_file = 1};
    return callback(str_db_get(path, 0), &info, arg);
  }

  if (S_ISDIR(st.st_mode)) {
    /* Directory — append "/" then walk recursively */
    if (str_db_push_u16_le(path, OS_PATH_SEP, 1) == NULL)
      return FL_OUT_OF_MEMORY;

    FL_WalkDirCtx ctx = {
        .callback = callback,
        .arg = arg,
        .path = *path,
        .alloc = path->vec.alloc};
    const int r = WalkDirDfs(&ctx);
    *path = ctx.path;
    return r;
  }

  return FL_OK;
}
