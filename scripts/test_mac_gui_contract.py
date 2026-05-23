from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_DELEGATE = ROOT / "FontLoaderSub" / "mac_gui" / "AppDelegate.m"
FL_MANAGER_H = ROOT / "FontLoaderSub" / "mac_gui" / "FLManager.h"
FL_MANAGER_M = ROOT / "FontLoaderSub" / "mac_gui" / "FLManager.m"


def read(path):
    return path.read_text(encoding="utf-8")


class MacGuiContractTests(unittest.TestCase):
    def test_mac_status_menu_exposes_windows_parity_actions(self):
        app = read(APP_DELEGATE)

        expected_menu_actions = {
            "Cancel Loading": "@selector(cancelLoading:)",
            "Load Details": "@selector(showLoadDetails:)",
            "Export Loaded Fonts": "@selector(exportLoadedFonts:)",
            "Rebuild Font Index": "@selector(rebuildFontIndex:)",
            "Help": "@selector(showHelp:)",
        }

        for title, selector in expected_menu_actions.items():
            self.assertIn(title, app)
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


if __name__ == "__main__":
    unittest.main()
