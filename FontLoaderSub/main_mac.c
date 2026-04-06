/* main_mac.c — macOS CLI entry point for FontLoaderSub
 *
 * Usage: fontloadersub <subtitle-path> <font-dir>
 *
 *   <subtitle-path>  ASS/SSA subtitle file or directory to scan
 *   <font-dir>       Directory containing font files (TTF/OTF/TTC)
 *
 * The tool loads the fonts required by the subtitle(s) at User scope
 * so they are visible to all applications on the current user session.
 * Press Enter or send SIGINT (Ctrl-C) to unload the fonts and exit.
 *
 * Cache: a font index cache is saved as fc-subs.db in <font-dir> and
 * reused on the next run, matching the Windows version behaviour.
 */

#include "font_loader.h"
#include "font_set.h"
#include "util.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define kCacheFile      L"fc-subs.db"
#define kCacheFile_utf8  "fc-subs.db"
#define kBlackFile      L"fc-ignore.txt"

/* Forward declarations of UTF helpers defined in util_posix.c */
extern int fl_wchar_to_utf8(const wchar_t *w, char *buf, size_t sz);

/* ------------------------------------------------------------------ */
/*  Allocator                                                           */
/* ------------------------------------------------------------------ */

static void *mac_realloc(void *existing, size_t size, void *arg) {
  (void)arg;
  if (size == 0) {
    free(existing);
    return NULL;
  }
  return realloc(existing, size);
}

/* ------------------------------------------------------------------ */
/*  SIGINT handler                                                      */
/* ------------------------------------------------------------------ */

static volatile int g_interrupted = 0;
static FL_LoaderCtx *g_ctx = NULL;

static void on_sigint(int sig) {
  (void)sig;
  g_interrupted = 1;
  if (g_ctx)
    fl_cancel(g_ctx);
}

/* ------------------------------------------------------------------ */
/*  argv → wchar_t helper (ASCII/Latin-1 byte copy; paths on macOS    */
/*  are normalised NFC UTF-8, but we handle the full range via the    */
/*  byte-copy approach since our internal format is UTF-16).           */
/* ------------------------------------------------------------------ */

static wchar_t *argv_to_wchar(const char *arg, allocator_t *alloc) {
  size_t n = strlen(arg);
  wchar_t *buf =
      (wchar_t *)alloc->alloc(NULL, (n + 1) * sizeof(wchar_t), alloc->arg);
  if (!buf)
    return NULL;
  /* Full UTF-8 → UTF-16 conversion */
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

/* ------------------------------------------------------------------ */
/*  Print a wchar_t string to stdout via UTF-8 conversion              */
/* ------------------------------------------------------------------ */

static void print_wstr(const wchar_t *ws) {
  if (!ws)
    return;
  char buf[1024];
  fl_wchar_to_utf8(ws, buf, sizeof buf);
  fputs(buf, stdout);
}

/* ------------------------------------------------------------------ */
/*  Main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[]) {
  if (argc < 3) {
    fprintf(stderr,
            "Usage: %s <subtitle-path> <font-dir>\n\n"
            "  <subtitle-path>  ASS/SSA file or directory\n"
            "  <font-dir>       Directory containing TTF/OTF/TTC fonts\n\n"
            "Loads required fonts at user scope.  Press Enter or Ctrl-C to "
            "unload and exit.\n"
            "Font index is cached in <font-dir>/" kCacheFile_utf8
            " for faster startup.\n",
            argv[0]);
    return 1;
  }

  const char *sub_path  = argv[1];
  const char *font_path = argv[2];

  /* Set up allocator */
  allocator_t alloc = {.alloc = mac_realloc, .arg = NULL};

  /* Convert CLI arguments to wchar_t */
  wchar_t *sub_w  = argv_to_wchar(sub_path, &alloc);
  wchar_t *font_w = argv_to_wchar(font_path, &alloc);
  if (!sub_w || !font_w) {
    fprintf(stderr, "Out of memory\n");
    return 1;
  }

  /* Initialise loader */
  FL_LoaderCtx ctx;
  int r = fl_init(&ctx, &alloc);
  if (r != FL_OK) {
    fprintf(stderr, "Failed to initialise font loader (%d)\n", r);
    return 1;
  }
  g_ctx = &ctx;
  signal(SIGINT, on_sigint);

  /* --- Step 1: parse subtitles --- */
  printf("Scanning subtitles: %s\n", sub_path);
  r = fl_add_subs(&ctx, sub_w);
  if (r != FL_OK && r != FL_OS_ERROR) {
    fprintf(stderr, "Error scanning subtitles (%d)\n", r);
    goto cleanup;
  }
  printf("  Found %u subtitle(s), %u font reference(s)\n",
         ctx.num_sub, ctx.num_sub_font);

  if (ctx.num_sub_font == 0) {
    printf("No fonts needed — nothing to do.\n");
    goto cleanup;
  }

  /* --- Step 2: load font index (try cache first) --- */
  printf("Loading font index from: %s\n", font_path);
  r = fl_scan_fonts(&ctx, font_w, kCacheFile, kBlackFile);

  {
    FS_Stat stat = {0};
    if (ctx.font_set)
      fs_stat(ctx.font_set, &stat);

    if (stat.num_face == 0) {
      /* Cache miss (file absent, stale, or empty) — full scan */
      printf("  Cache miss — scanning font files...\n");
      r = fl_scan_fonts(&ctx, font_w, NULL, kBlackFile);
      if (r == FL_OK) {
        fs_stat(ctx.font_set, &stat);
        printf("  Indexed %u file(s) / %u face(s)",
               stat.num_file, stat.num_face);
        /* Save the cache for next time */
        if (fl_save_cache(&ctx, kCacheFile) == FL_OK) {
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

  /* --- Step 3: load fonts --- */
  printf("Loading fonts...\n");
  r = fl_load_fonts(&ctx);
  if (r != FL_OK) {
    fprintf(stderr, "Error loading fonts (%d)\n", r);
    goto cleanup;
  }

  /* --- Step 4: report --- */
  printf("\nResults:\n");
  FL_FontMatch *data = ctx.loaded_font.data;
  for (size_t i = 0; i != ctx.loaded_font.n; i++) {
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

  printf("\nLoaded: %u  Failed: %u  Missing: %u\n",
         ctx.num_font_loaded, ctx.num_font_failed, ctx.num_font_unmatched);

  if (ctx.num_font_loaded == 0) {
    printf("No fonts were loaded (all already in system or none matched).\n");
    goto cleanup;
  }

  /* --- Step 5: wait --- */
  printf("\nFonts are loaded.  Press Enter to unload and exit...\n");
  if (!g_interrupted) {
    getchar();
  }

  /* --- Step 6: unload --- */
  printf("Unloading fonts...\n");
  fl_unload_fonts(&ctx);
  printf("Done.\n");

cleanup:
  fl_free(&ctx);
  alloc.alloc(sub_w, 0, alloc.arg);
  alloc.alloc(font_w, 0, alloc.arg);
  return (r == FL_OK || r == FL_OS_ERROR) ? 0 : 1;
}

