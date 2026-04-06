/* font_load_mac.c — macOS font registration via CoreText
 * Compiled only on Apple platforms (see CMakeLists.txt).
 * Requires -fshort-wchar so that sizeof(wchar_t) == 2 (UTF-16). */

#include "util.h"
#include "ass_string.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <limits.h>

/* Forward declaration of the UTF helper defined in util_posix.c */
extern int fl_wchar_to_utf8(const wchar_t *w, char *buf, size_t sz);

/* ------------------------------------------------------------------ */
/*  Internal helpers                                                    */
/* ------------------------------------------------------------------ */

static CFURLRef url_from_wpath(const wchar_t *path) {
  char utf8_path[PATH_MAX];
  fl_wchar_to_utf8(path, utf8_path, sizeof utf8_path);
  return CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8 *)utf8_path, (CFIndex)strlen(utf8_path),
      false /* not a directory */);
}

/* ------------------------------------------------------------------ */
/*  OsFontLoad                                                          */
/* ------------------------------------------------------------------ */

int OsFontLoad(const wchar_t *path) {
  CFURLRef url = url_from_wpath(path);
  if (!url)
    return FL_OS_ERROR;

  CFErrorRef err = NULL;
  Boolean ok = CTFontManagerRegisterFontsForURL(
      url, kCTFontManagerScopeSession, &err);
  if (!ok && err) {
    CFRelease(err);
  }
  CFRelease(url);
  return ok ? FL_OK : FL_OS_ERROR;
}

/* ------------------------------------------------------------------ */
/*  OsFontUnload                                                        */
/* ------------------------------------------------------------------ */

int OsFontUnload(const wchar_t *path) {
  CFURLRef url = url_from_wpath(path);
  if (!url)
    return FL_OS_ERROR;

  CFErrorRef err = NULL;
  Boolean ok = CTFontManagerUnregisterFontsForURL(
      url, kCTFontManagerScopeSession, &err);
  if (!ok && err) {
    CFRelease(err);
  }
  CFRelease(url);
  return ok ? FL_OK : FL_OS_ERROR;
}

/* ------------------------------------------------------------------ */
/*  OsFontIsInstalled                                                   */
/* ------------------------------------------------------------------ */

int OsFontIsInstalled(const wchar_t *face) {
  /* Build the face name as a CFString from our UTF-16 wchar_t.
   * With -fshort-wchar, wchar_t == uint16_t == UniChar. */
  CFStringRef name = CFStringCreateWithCharacters(
      kCFAllocatorDefault, (const UniChar *)face,
      (CFIndex)ass_strlen(face));
  if (!name)
    return 0;

  /* Use font descriptor matching to check whether the font family is
   * available.  We query by family name to be consistent with how
   * Windows EnumFontFamilies works. */
  CFDictionaryRef attrs = CFDictionaryCreate(
      kCFAllocatorDefault,
      (const void *[]){kCTFontFamilyNameAttribute},
      (const void *[]){name},
      1,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(name);
  if (!attrs)
    return 0;

  CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
  CFRelease(attrs);
  if (!desc)
    return 0;

  CFArrayRef arr = CTFontDescriptorCreateMatchingFontDescriptors(desc, NULL);
  CFRelease(desc);

  int found = 0;
  if (arr) {
    found = (CFArrayGetCount(arr) > 0);
    CFRelease(arr);
  }
  return found;
}
