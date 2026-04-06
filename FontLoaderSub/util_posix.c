/* util_posix.c — POSIX implementations of util.h interfaces
 * Compiled only on non-Windows platforms (see CMakeLists.txt).
 * Requires -fshort-wchar so that sizeof(wchar_t) == 2 (UTF-16). */

#include "util.h"
#include "cstl.h"

#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/*  UTF-16 ↔ UTF-8 conversion                                          */
/* ------------------------------------------------------------------ */

/**
 * Convert a NUL-terminated UTF-16LE wchar_t string (wchar_t = 2 bytes,
 * requires -fshort-wchar) to a NUL-terminated UTF-8 char string.
 * Returns the number of bytes written (not counting the NUL).
 * buf is always NUL-terminated even on truncation.
 */
int fl_wchar_to_utf8(const wchar_t *wstr, char *buf, size_t bufsz) {
  if (bufsz == 0)
    return 0;
  char *out = buf;
  const char *out_end = buf + bufsz - 1; /* reserve space for NUL */

  while (*wstr && out < out_end) {
    uint32_t cp = (uint16_t)*wstr++;

    /* Handle surrogate pair (UTF-16) */
    if (cp >= 0xD800u && cp <= 0xDBFFu) {
      uint32_t lo = (uint16_t)*wstr;
      if (lo >= 0xDC00u && lo <= 0xDFFFu) {
        cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
        wstr++;
      }
    }

    if (cp < 0x80u) {
      *out++ = (char)cp;
    } else if (cp < 0x800u) {
      if (out + 1 > out_end)
        break;
      *out++ = (char)(0xC0u | (cp >> 6));
      *out++ = (char)(0x80u | (cp & 0x3Fu));
    } else if (cp < 0x10000u) {
      if (out + 2 > out_end)
        break;
      *out++ = (char)(0xE0u | (cp >> 12));
      *out++ = (char)(0x80u | ((cp >> 6) & 0x3Fu));
      *out++ = (char)(0x80u | (cp & 0x3Fu));
    } else {
      if (out + 3 > out_end)
        break;
      *out++ = (char)(0xF0u | (cp >> 18));
      *out++ = (char)(0x80u | ((cp >> 12) & 0x3Fu));
      *out++ = (char)(0x80u | ((cp >> 6) & 0x3Fu));
      *out++ = (char)(0x80u | (cp & 0x3Fu));
    }
  }
  *out = '\0';
  return (int)(out - buf);
}

/**
 * Convert a NUL-terminated UTF-8 string to UTF-16LE wchar_t and append
 * it to str_db *s.  Returns the pointer to the newly inserted string on
 * success, NULL on allocation failure.
 */
const wchar_t *
fl_utf8_to_str_db(const char *str, str_db_t *s, allocator_t *alloc) {
  /* First pass: measure output length */
  size_t out_len = 0;
  const unsigned char *p = (const unsigned char *)str;
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
    out_len += (cp >= 0x10000u) ? 2 : 1; /* surrogate pair or single unit */
  }

  /* Allocate in str_db */
  const size_t start = str_db_tell(s);
  if (vec_prealloc(&s->vec, out_len + 1) < out_len + 1)
    return NULL;
  wchar_t *ret = (wchar_t *)str_db_get(s, start);

  /* Second pass: encode */
  p = (const unsigned char *)str;
  wchar_t *w = ret;
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
  s->vec.n = start + out_len;
  return ret;
}

/* ------------------------------------------------------------------ */
/*  Memory mapping                                                      */
/* ------------------------------------------------------------------ */

int FlMemMap(const wchar_t *path, memmap_t *out) {
  out->data = NULL;
  out->size = 0;

  char utf8_path[PATH_MAX];
  fl_wchar_to_utf8(path, utf8_path, sizeof utf8_path);

  int fd = open(utf8_path, O_RDONLY);
  if (fd == -1)
    return 0;

  struct stat st;
  if (fstat(fd, &st) == -1 || st.st_size == 0) {
    close(fd);
    return 0;
  }

  out->size = (size_t)st.st_size;
  void *ptr = mmap(NULL, out->size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd); /* fd can be closed after mmap; mapping remains valid */

  if (ptr == MAP_FAILED) {
    out->data = NULL;
    out->size = 0;
    return 0;
  }
  out->data = ptr;
  return 0;
}

int FlMemUnmap(memmap_t *out) {
  if (out->data) {
    munmap(out->data, out->size);
    out->data = NULL;
    out->size = 0;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/*  Text decoding (shared logic; same as util.c on Windows)            */
/* ------------------------------------------------------------------ */

static int FlTestUtf8(const uint8_t *buffer, size_t size) {
  const uint8_t *p, *last;
  int rem = 0;
  for (p = buffer, last = buffer + size; p != last; p++) {
    if (rem) {
      if ((*p & 0xc0) == 0x80) {
        --rem;
      } else {
        return 0;
      }
    } else if ((*p & 0x80) == 0) {
      /* rem = 0; */
    } else if ((*p & 0xe0) == 0xc0) {
      rem = 1;
    } else if ((*p & 0xf0) == 0xe0) {
      rem = 2;
    } else if ((*p & 0xf8) == 0xf0) {
      rem = 3;
    } else {
      return 0;
    }
  }
  return rem == 0;
}

/* Decode a multi-byte string (UTF-8 or system codepage) into a
 * newly allocated wchar_t (UTF-16 with -fshort-wchar) buffer. */
static wchar_t *FlDecodeUtf8(
    const uint8_t *mstr,
    size_t bytes,
    size_t *cch,
    allocator_t *alloc) {
  /* First pass: count output code units */
  const uint8_t *p = mstr;
  const uint8_t *end = mstr + bytes;
  size_t n = 0;
  while (p < end) {
    uint32_t cp;
    if (*p < 0x80u) {
      cp = *p++;
    } else if ((*p & 0xE0u) == 0xC0u && p + 1 < end) {
      cp = (*p++ & 0x1Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else if ((*p & 0xF0u) == 0xE0u && p + 2 < end) {
      cp = (*p++ & 0x0Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else if ((*p & 0xF8u) == 0xF0u && p + 3 < end) {
      cp = (*p++ & 0x07u) << 18;
      cp |= (*p++ & 0x3Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else {
      /* Invalid byte — replace with U+FFFD */
      cp = 0xFFFDu;
      p++;
    }
    n += (cp >= 0x10000u) ? 2 : 1;
  }

  wchar_t *buf = (wchar_t *)alloc->alloc(NULL, (n + 1) * sizeof(wchar_t), alloc->arg);
  if (!buf)
    return NULL;

  /* Second pass: encode */
  p = mstr;
  wchar_t *w = buf;
  while (p < end) {
    uint32_t cp;
    if (*p < 0x80u) {
      cp = *p++;
    } else if ((*p & 0xE0u) == 0xC0u && p + 1 < end) {
      cp = (*p++ & 0x1Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else if ((*p & 0xF0u) == 0xE0u && p + 2 < end) {
      cp = (*p++ & 0x0Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else if ((*p & 0xF8u) == 0xF0u && p + 3 < end) {
      cp = (*p++ & 0x07u) << 18;
      cp |= (*p++ & 0x3Fu) << 12;
      cp |= (*p++ & 0x3Fu) << 6;
      cp |= (*p++ & 0x3Fu);
    } else {
      cp = 0xFFFDu;
      p++;
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
  *cch = n;
  return buf;
}

static wchar_t *FlTextDecodeUtf16(
    int big_endian,
    const uint8_t *mstr,
    size_t bytes,
    size_t *cch,
    allocator_t *alloc) {
  const uint16_t *src = (const uint16_t *)mstr;
  const size_t r = *cch = bytes / 2;
  wchar_t *buf = (wchar_t *)alloc->alloc(NULL, (r + 1) * sizeof(wchar_t), alloc->arg);
  if (!buf)
    return NULL;
  for (size_t i = 0; i != r; i++)
    buf[i] = big_endian ? be16(src[i]) : src[i];
  buf[r] = 0;
  return buf;
}

wchar_t *FlTextDecode(
    const uint8_t *buf,
    size_t bytes,
    size_t *cch,
    allocator_t *alloc) {
  wchar_t *res = NULL;
  if (bytes < 4)
    return res;

  /* Detect BOM */
  if (buf[0] == 0xef && buf[1] == 0xbb && buf[2] == 0xbf) {
    res = FlDecodeUtf8(buf + 3, bytes - 3, cch, alloc);
  } else if (buf[0] == 0xff && buf[1] == 0xfe) {
    res = FlTextDecodeUtf16(0, buf + 2, bytes - 2, cch, alloc);
  } else if (buf[0] == 0xfe && buf[1] == 0xff) {
    res = FlTextDecodeUtf16(1, buf + 2, bytes - 2, cch, alloc);
  }

  if (!res && FlTestUtf8(buf, bytes)) {
    res = FlDecodeUtf8(buf, bytes, cch, alloc);
  }
  /* Last resort: treat as Latin-1 */
  if (!res) {
    wchar_t *fb = (wchar_t *)alloc->alloc(NULL, (bytes + 1) * sizeof(wchar_t), alloc->arg);
    if (fb) {
      for (size_t i = 0; i < bytes; i++)
        fb[i] = buf[i];
      fb[bytes] = 0;
      *cch = bytes;
      res = fb;
    }
  }
  return res;
}

/* ------------------------------------------------------------------ */
/*  String utilities                                                    */
/* ------------------------------------------------------------------ */

int FlVersionCmp(const wchar_t *a, const wchar_t *b) {
  /* Reimplementation without Windows headers */
  if (b == NULL)
    return 1;
  if (a == NULL)
    return -1;

  while (*a && *b) {
    /* If both are digits, compare numerically */
    if (*a >= L'0' && *a <= L'9' && *b >= L'0' && *b <= L'9') {
      const wchar_t *sa = a, *sb = b;
      while (*a >= L'0' && *a <= L'9')
        a++;
      while (*b >= L'0' && *b <= L'9')
        b++;
      /* Compare from right */
      const wchar_t *da = a, *db = b;
      int cmp = 0;
      while (da != sa && db != sb) {
        da--; db--;
        if (!cmp)
          cmp = *da - *db;
      }
      /* Strip leading zeros */
      while (da != sa && da[-1] == L'0')
        da--;
      while (db != sb && db[-1] == L'0')
        db--;
      if (da != sa)
        return 1;
      if (db != sb)
        return -1;
      if (cmp)
        return cmp;
      continue;
    }
    if (*a != *b)
      return *a - *b;
    a++; b++;
  }
  if (*a)
    return 1;
  if (*b)
    return -1;
  return 0;
}

int FlStrCmpIW(const wchar_t *a, const wchar_t *b) {
  /* Case-insensitive compare for ASCII range; fonts only use ASCII names */
  while (*a && *b) {
    wchar_t ca = *a >= L'A' && *a <= L'Z' ? *a - L'A' + L'a' : *a;
    wchar_t cb = *b >= L'A' && *b <= L'Z' ? *b - L'A' + L'a' : *b;
    if (ca != cb)
      return ca - cb;
    a++; b++;
  }
  return (int)(uint16_t)*a - (int)(uint16_t)*b;
}

/* ------------------------------------------------------------------ */
/*  Portable memory operations (no MSVC intrinsics)                    */
/* ------------------------------------------------------------------ */

void *zmemset(void *dest, int ch, size_t count) {
  return memset(dest, ch, count);
}

void *zmemcpy(void *dest, const void *src, size_t count) {
  return memcpy(dest, src, count);
}
