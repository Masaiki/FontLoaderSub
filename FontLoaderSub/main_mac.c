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

#include <errno.h>
#include <signal.h>
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

static volatile int g_interrupted = 0;
static FL_LoaderCtx *g_ctx = NULL;

static void on_signal(int sig) {
  (void)sig;
  g_interrupted = 1;
  if (g_ctx)
    fl_cancel(g_ctx);
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

static void print_wstr(const wchar_t *ws) {
  if (!ws)
    return;
  char buf[1024];
  fl_wchar_to_utf8(ws, buf, sizeof buf);
  fputs(buf, stdout);
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
    printf("Scanning subtitles: %s\n", subtitle_paths[i]);
    r = add_subtitle(ctx, alloc, subtitle_paths[i]);
    if (r != FL_OK)
      goto cleanup;
  }

  printf("  Found %u subtitle(s), %u font reference(s)\n",
         ctx->num_sub, ctx->num_sub_font);

  if (ctx->num_sub_font == 0) {
    printf("No fonts needed — nothing to do.\n");
    goto cleanup;
  }

  printf("Loading font index from: %s\n", font_path);
  r = fl_scan_fonts(ctx, font_w, kCacheFile, kBlackFile);

  {
    FS_Stat stat = {0};
    if (ctx->font_set)
      fs_stat(ctx->font_set, &stat);

    if (stat.num_face == 0) {
      printf("  Cache miss — scanning font files...\n");
      r = fl_scan_fonts(ctx, font_w, NULL, kBlackFile);
      if (r == FL_OK) {
        fs_stat(ctx->font_set, &stat);
        printf("  Indexed %u file(s) / %u face(s)",
               stat.num_file, stat.num_face);
        if (fl_save_cache(ctx, kCacheFile) == FL_OK) {
          printf(" — cache saved");
        }
        printf("\n");
      }
    } else {
      printf("  Loaded %u face(s) from cache\n", stat.num_face);
    }
  }

  if (r != FL_OK) {
    fprintf(stderr, "Error scanning font directory (%d)\n", r);
    goto cleanup;
  }

  printf("Loading fonts...\n");
  r = fl_load_fonts(ctx);
  if (r != FL_OK) {
    fprintf(stderr, "Error loading fonts (%d)\n", r);
    goto cleanup;
  }

  printf("\nResults:\n");
  {
    FL_FontMatch *data = ctx->loaded_font.data;
    for (i = 0; i != ctx->loaded_font.n; i++) {
      FL_FontMatch *m = &data[i];
      const char *tag;
      if (m->flag & FL_LOAD_DUP)
        tag = "[dup] ";
      else if (m->flag & FL_OS_LOADED)
        tag = "[sys] ";
      else if (m->flag & FL_LOAD_OK)
        tag = "[ok]  ";
      else if (m->flag & FL_LOAD_ERR)
        tag = "[ X]  ";
      else if (m->flag & FL_LOAD_MISS)
        tag = "[---] ";
      else
        tag = "[?]   ";

      fputs(tag, stdout);
      print_wstr(m->face);
      if (m->filename && !(m->flag & (FL_OS_LOADED | FL_LOAD_DUP))) {
        fputs(" <- ", stdout);
        print_wstr(m->filename);
      }
      putchar('\n');
    }
  }

  printf("\nLoaded: %u  Failed: %u  Missing: %u\n",
         ctx->num_font_loaded, ctx->num_font_failed, ctx->num_font_unmatched);
  printf("FLS_READY loaded=%u failed=%u missing=%u\n",
         ctx->num_font_loaded, ctx->num_font_failed, ctx->num_font_unmatched);
  fflush(stdout);

  if (ctx->num_font_loaded == 0) {
    printf("No fonts were loaded (all already in system or none matched).\n");
    goto cleanup;
  }

  wait_for_shutdown();

  printf("Unloading fonts...\n");
  fl_unload_fonts(ctx);
  printf("Done.\n");

cleanup:
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

