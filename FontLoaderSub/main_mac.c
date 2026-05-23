/* main_mac.c — macOS CLI entry point for FontLoaderSub
 *
 * Usage: FontLoaderSubHelper --font-dir <font-dir> --subtitle <path> [--subtitle <path> ...]
 *
 *   <font-dir>       Directory containing font files (TTF/OTF/TTC)
 *   <subtitle-path>  ASS/SSA subtitle file or directory to scan
 *
 * The tool loads the fonts required by the subtitle(s) at User scope
 * so they are visible to all applications on the current user session.
 * The process stays alive until stdin closes or it receives SIGINT/SIGTERM,
 * then unloads the fonts and exits.
 *
 * Cache: a font index cache is saved as fc-subs.db in <font-dir> and
 * reused on the next run, matching the Windows version behaviour.
 */

#include "font_loader.h"
#include "font_set.h"
#include "util.h"

#import <Foundation/Foundation.h>

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

#define kCacheFile      L"fc-subs.db"
#define kCacheFile_utf8  "fc-subs.db"
#define kBlackFile      L"fc-ignore.txt"

/* Forward declarations of UTF helpers defined in util_posix.c */
extern int fl_wchar_to_utf8(const wchar_t *w, char *buf, size_t sz);

static void *mac_realloc(void *existing, size_t size, void *arg) {
  (void)arg;
  if (size == 0) {
    free(existing);
    return NULL;
  }
  return realloc(existing, size);
}

static volatile sig_atomic_t g_interrupted = 0;
static FL_LoaderCtx *g_ctx = NULL;

static void on_signal(int sig) {
  (void)sig;
  g_interrupted = 1;
  if (g_ctx && g_ctx->event_cancel)
    *(volatile sig_atomic_t *)g_ctx->event_cancel = 1;
}

static int check_interrupted(FL_LoaderCtx *ctx) {
  if (!g_interrupted)
    return FL_OK;
  if (ctx)
    fl_cancel(ctx);
  return FL_OS_ERROR;
}

static wchar_t *argv_to_wchar(const char *arg, allocator_t *alloc) {
  size_t n = strlen(arg);
  wchar_t *buf =
      (wchar_t *)alloc->alloc(NULL, (n + 1) * sizeof(wchar_t), alloc->arg);
  if (!buf)
    return NULL;
  const unsigned char *p = (const unsigned char *)arg;
  wchar_t *w = buf;
  while (*p) {
    uint32_t cp;
    if (*p < 0x80u) {
      cp = *p++;
    } else if ((*p & 0xE0u) == 0xC0u) {
      cp = (*p++ & 0x1Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else if ((*p & 0xF0u) == 0xE0u) {
      cp = (*p++ & 0x0Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else {
      cp = (*p++ & 0x07u) << 18;
      cp |= (*p++ & 0x3Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    }
    if (cp >= 0x10000u) {
      cp -= 0x10000u;
      *w++ = (wchar_t)(0xD800u + (cp >> 10));
      *w++ = (wchar_t)(0xDC00u + (cp & 0x3FFu));
    } else {
      *w++ = (wchar_t)cp;
    }
  }
  *w = 0;
  return buf;
}

static char *wstr_to_utf8_alloc(const wchar_t *ws) {
  if (!ws)
    return NULL;
  size_t cap = 256;
  for (;;) {
    char *buf = (char *)malloc(cap);
    if (!buf)
      return NULL;
    int n = fl_wchar_to_utf8(ws, buf, cap);
    if ((size_t)n < cap - 1)
      return buf;
    free(buf);
    if (cap > (SIZE_MAX / 2))
      return NULL;
    cap *= 2;
  }
}

static NSString *nsstr_from_utf8(const char *s) {
  if (!s)
    return @"";
  NSString *str = [NSString stringWithUTF8String:s];
  return str ? str : @"";
}

static void json_emit(NSDictionary *event) {
  @autoreleasepool {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event
                                                   options:0
                                                     error:&error];
    if (!data)
      return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
  }
}

static void json_event_log(const char *message) {
  @autoreleasepool {
    json_emit(@{
        @"event": @"log",
        @"message": nsstr_from_utf8(message),
    });
  }
}

static void json_event_logf(const char *fmt, ...) {
  va_list ap;
  va_list ap2;
  int n;
  char stack_buf[512];
  char *buf = stack_buf;

  va_start(ap, fmt);
  va_copy(ap2, ap);
  n = vsnprintf(stack_buf, sizeof stack_buf, fmt, ap);
  va_end(ap);
  if (n < 0) {
    va_end(ap2);
    return;
  }
  if ((size_t)n >= sizeof stack_buf) {
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) {
      va_end(ap2);
      return;
    }
    vsnprintf(buf, (size_t)n + 1, fmt, ap2);
  }
  va_end(ap2);

  json_event_log(buf);
  if (buf != stack_buf)
    free(buf);
}

static void json_event_font(const char *status, const wchar_t *face,
                            const wchar_t *filename) {
  char *face_utf8 = wstr_to_utf8_alloc(face);
  char *filename_utf8 = wstr_to_utf8_alloc(filename);

  @autoreleasepool {
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"font", @"event",
        nsstr_from_utf8(status), @"status",
        nsstr_from_utf8(face_utf8), @"face",
        nil];
    if (filename_utf8) {
      [event setObject:nsstr_from_utf8(filename_utf8) forKey:@"path"];
    }
    json_emit(event);
  }

  free(face_utf8);
  free(filename_utf8);
}

static void json_event_ready(uint32_t loaded, uint32_t failed,
                             uint32_t missing) {
  @autoreleasepool {
    json_emit(@{
        @"event": @"ready",
        @"loaded": [NSNumber numberWithUnsignedInt:loaded],
        @"failed": [NSNumber numberWithUnsignedInt:failed],
        @"missing": [NSNumber numberWithUnsignedInt:missing],
    });
  }
}

static void wait_for_shutdown(void) {
  while (!g_interrupted) {
    fd_set readfds;
    int r;

    FD_ZERO(&readfds);
    FD_SET(STDIN_FILENO, &readfds);

    r = select(STDIN_FILENO + 1, &readfds, NULL, NULL, NULL);
    if (r > 0 && FD_ISSET(STDIN_FILENO, &readfds)) {
      char buf[256];
      ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
      if (n == 0) {
        break;
      }
      if (n < 0 && errno == EINTR) {
        continue;
      }
    } else if (r < 0 && errno == EINTR) {
      continue;
    }
  }
}

static int add_subtitle(FL_LoaderCtx *ctx, allocator_t *alloc,
                        const char *subtitle_path) {
  wchar_t *subtitle_w = argv_to_wchar(subtitle_path, alloc);
  int r;
  if (!subtitle_w)
    return FL_OUT_OF_MEMORY;
  r = fl_add_subs(ctx, subtitle_w);
  alloc->alloc(subtitle_w, 0, alloc->arg);
  if (r == FL_OS_ERROR)
    return FL_OK;
  return r;
}

static int run_loader(FL_LoaderCtx *ctx, allocator_t *alloc,
                      const char **subtitle_paths, size_t subtitle_count,
                      const char *font_path) {
  wchar_t *font_w = NULL;
  int r = FL_OK;
  size_t i;

  font_w = argv_to_wchar(font_path, alloc);
  if (!font_w)
    return FL_OUT_OF_MEMORY;

  for (i = 0; i != subtitle_count; i++) {
    json_event_logf("Scanning subtitles: %s", subtitle_paths[i]);
    if ((r = check_interrupted(ctx)) != FL_OK)
      goto cleanup;
    r = add_subtitle(ctx, alloc, subtitle_paths[i]);
    if (r != FL_OK)
      goto cleanup;
  }

  json_event_logf("  Found %u subtitle(s), %u font reference(s)",
                  ctx->num_sub, ctx->num_sub_font);

  if (ctx->num_sub_font == 0) {
    json_event_log("No fonts needed - nothing to do.");
    json_event_ready(0, 0, 0);
    fflush(stdout);
    goto cleanup;
  }

  json_event_logf("Loading font index from: %s", font_path);
  if ((r = check_interrupted(ctx)) != FL_OK)
    goto cleanup;
  r = fl_scan_fonts(ctx, font_w, kCacheFile, kBlackFile);

  {
    FS_Stat stat = {0};
    if (ctx->font_set)
      fs_stat(ctx->font_set, &stat);

    if (stat.num_face == 0) {
      json_event_log("  Cache miss - scanning font files...");
      if ((r = check_interrupted(ctx)) != FL_OK)
        goto cleanup;
      r = fl_scan_fonts(ctx, font_w, NULL, kBlackFile);
      if (r == FL_OK) {
        char msg[160];
        fs_stat(ctx->font_set, &stat);
        snprintf(msg, sizeof msg, "  Indexed %u file(s) / %u face(s)",
                 stat.num_file, stat.num_face);
        if (fl_save_cache(ctx, kCacheFile) == FL_OK) {
          size_t len = strlen(msg);
          snprintf(msg + len, sizeof msg - len, " - cache saved");
        }
        json_event_log(msg);
      }
    } else {
      json_event_logf("  Loaded %u face(s) from cache", stat.num_face);
    }
  }

  if (r != FL_OK) {
    fprintf(stderr, "Error scanning font directory (%d)\n", r);
    goto cleanup;
  }

  json_event_log("Loading fonts...");
  if ((r = check_interrupted(ctx)) != FL_OK)
    goto cleanup;
  r = fl_load_fonts(ctx);
  if (r != FL_OK) {
    fprintf(stderr, "Error loading fonts (%d)\n", r);
    goto cleanup;
  }

  json_event_log("Results:");
  {
    FL_FontMatch *data = ctx->loaded_font.data;
    for (i = 0; i != ctx->loaded_font.n; i++) {
      FL_FontMatch *m = &data[i];
      const char *status;
      if (m->flag & FL_LOAD_DUP)
        status = "dup";
      else if (m->flag & FL_OS_LOADED)
        status = "system";
      else if (m->flag & FL_LOAD_OK)
        status = "ok";
      else if (m->flag & FL_LOAD_ERR)
        status = "failed";
      else if (m->flag & FL_LOAD_MISS)
        status = "missing";
      else
        status = "unknown";

      json_event_font(status, m->face,
                      (m->filename && !(m->flag & (FL_OS_LOADED | FL_LOAD_DUP)))
                          ? m->filename
                          : NULL);
    }
  }

  json_event_logf("Loaded: %u  Failed: %u  Missing: %u",
                  ctx->num_font_loaded, ctx->num_font_failed,
                  ctx->num_font_unmatched);
  json_event_ready(ctx->num_font_loaded, ctx->num_font_failed,
                   ctx->num_font_unmatched);
  fflush(stdout);

  if (ctx->num_font_loaded == 0) {
    json_event_log("No fonts were loaded (all already in system or none matched).");
    goto cleanup;
  }

  wait_for_shutdown();

  json_event_log("Unloading fonts...");
  fl_unload_fonts(ctx);
  json_event_log("Done.");

cleanup:
  if (ctx->loaded_font.n > 0)
    fl_unload_fonts(ctx);
  alloc->alloc(font_w, 0, alloc->arg);
  return r;
}

static void print_usage(const char *argv0) {
  fprintf(stderr,
          "Usage: %s --font-dir <font-dir> --subtitle <path> [--subtitle <path> ...]\n\n"
          "  <font-dir>       Directory containing TTF/OTF/TTC fonts\n"
          "  <subtitle-path>  ASS/SSA file or directory\n\n"
          "Loads required fonts at user scope until stdin closes or SIGINT/SIGTERM is received.\n"
          "Font index is cached in <font-dir>/" kCacheFile_utf8
          " for faster startup.\n",
          argv0);
}

int main(int argc, char *argv[]) {
  allocator_t alloc = {.alloc = mac_realloc, .arg = NULL};
  FL_LoaderCtx ctx;
  const char *font_path = NULL;
  const char **subtitle_paths = NULL;
  size_t subtitle_count = 0;
  size_t subtitle_cap = 0;
  int r;
  int i;

  if (argc < 4) {
    print_usage(argv[0]);
    return 1;
  }

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--font-dir") == 0) {
      if (i + 1 >= argc) {
        print_usage(argv[0]);
        free((void *)subtitle_paths);
        return 1;
      }
      font_path = argv[++i];
    } else if (strcmp(argv[i], "--subtitle") == 0) {
      const char **new_paths;
      if (i + 1 >= argc) {
        print_usage(argv[0]);
        free((void *)subtitle_paths);
        return 1;
      }
      if (subtitle_count == subtitle_cap) {
        size_t new_cap = subtitle_cap ? subtitle_cap * 2 : 4;
        new_paths = realloc((void *)subtitle_paths, new_cap * sizeof(*subtitle_paths));
        if (!new_paths) {
          fprintf(stderr, "Out of memory\n");
          free((void *)subtitle_paths);
          return 1;
        }
        subtitle_paths = new_paths;
        subtitle_cap = new_cap;
      }
      subtitle_paths[subtitle_count++] = argv[++i];
    } else {
      print_usage(argv[0]);
      free((void *)subtitle_paths);
      return 1;
    }
  }

  if (!font_path || subtitle_count == 0) {
    print_usage(argv[0]);
    free((void *)subtitle_paths);
    return 1;
  }

  r = fl_init(&ctx, &alloc);
  if (r != FL_OK) {
    fprintf(stderr, "Failed to initialise font loader (%d)\n", r);
    free((void *)subtitle_paths);
    return 1;
  }

  g_ctx = &ctx;
  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  r = run_loader(&ctx, &alloc, subtitle_paths, subtitle_count, font_path);

  fl_free(&ctx);
  free((void *)subtitle_paths);
  return (r == FL_OK || r == FL_OS_ERROR) ? 0 : 1;
}
