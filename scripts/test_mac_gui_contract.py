from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_DELEGATE = ROOT / "FontLoaderSub" / "mac_gui" / "AppDelegate.m"
FL_MANAGER_H = ROOT / "FontLoaderSub" / "mac_gui" / "FLManager.h"
FL_MANAGER_M = ROOT / "FontLoaderSub" / "mac_gui" / "FLManager.m"
MAC_GUI_RESOURCES = ROOT / "FontLoaderSub" / "mac_gui" / "Resources"
CMAKE_LISTS = ROOT / "CMakeLists.txt"


def read(path):
    return path.read_text(encoding="utf-8")


def read_bundle_string_keys(path):
    keys = set()
    for line in read(path).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("/*") or stripped.startswith("//"):
            continue
        if stripped.startswith('"') and '" =' in stripped:
            keys.add(stripped.split('"', 2)[1])
    return keys


class MacGuiContractTests(unittest.TestCase):
    def test_mac_status_menu_exposes_windows_parity_actions(self):
        app = read(APP_DELEGATE)

        expected_menu_actions = {
            'FLLocalized(@"menu.cancel_loading")': "@selector(cancelLoading:)",
            'FLLocalized(@"menu.load_details")': "@selector(showLoadDetails:)",
            'FLLocalized(@"menu.export_loaded_fonts")': "@selector(exportLoadedFonts:)",
            'FLLocalized(@"menu.rebuild_font_index")': "@selector(rebuildFontIndex:)",
            'FLLocalized(@"menu.help")': "@selector(showHelp:)",
        }

        for title_lookup, selector in expected_menu_actions.items():
            self.assertIn(title_lookup, app)
            self.assertIn(selector, app)

    def test_mac_export_uses_loaded_font_paths_from_manager(self):
        header = read(FL_MANAGER_H)
        manager = read(FL_MANAGER_M)
        app = read(APP_DELEGATE)

        self.assertIn("loadedFontRelativePaths", header)
        self.assertIn("loadedFontRelativePaths", manager)
        self.assertIn("loadedFontRelativePaths", app)
        self.assertIn(" <- ", manager)

    def test_rebuild_reuses_last_subtitle_selection_when_available(self):
        app = read(APP_DELEGATE)

        self.assertIn("_lastSubtitlePaths", app)
        self.assertIn("_lastFontDirectory", app)
        self.assertIn("fc-subs.db", app)
        self.assertIn("subtitlePaths = [[_lastSubtitlePaths copy] autorelease]", app)
        self.assertIn("startLoadingSubtitlePaths:subtitlePaths", app)

    def test_mac_gui_localization_resources_cover_supported_languages(self):
        expected_localizable_keys = {
            "menu.load_fonts",
            "menu.cancel_loading",
            "menu.export_loaded_fonts",
            "menu.quit",
            "status.idle",
            "status.loaded_summary",
            "font_directory.not_set",
            "alert.ok",
            "help.body",
            "service.error.no_font_directory",
        }
        expected_info_keys = {"Load Fonts for Subtitles"}

        for language in ("en", "zh-Hans", "zh-Hant"):
            language_dir = MAC_GUI_RESOURCES / f"{language}.lproj"
            localizable = language_dir / "Localizable.strings"
            info_plist = language_dir / "InfoPlist.strings"

            self.assertTrue(language_dir.is_dir(), language)
            self.assertTrue(localizable.is_file(), language)
            self.assertTrue(info_plist.is_file(), language)
            self.assertTrue(
                expected_localizable_keys.issubset(read_bundle_string_keys(localizable)),
                language,
            )
            self.assertTrue(
                expected_info_keys.issubset(read_bundle_string_keys(info_plist)),
                language,
            )

    def test_mac_gui_uses_native_localization_resources(self):
        app = read(APP_DELEGATE)
        cmake = read(CMAKE_LISTS)

        self.assertIn("NSLocalizedString", app)
        self.assertIn("Localizable.strings", cmake)
        self.assertIn("InfoPlist.strings", cmake)
        self.assertIn("zh-Hans.lproj", cmake)
        self.assertIn("zh-Hant.lproj", cmake)
        self.assertNotIn('initWithTitle:@"Load Fonts…"', app)
        self.assertNotIn('initWithTitle:@"Help"', app)


if __name__ == "__main__":
    unittest.main()
