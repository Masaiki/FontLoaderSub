#import "AppDelegate.h"

#import "FLManager.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const FLDefaultFontDirectoryKey = @"defaultFontDirectory";
static NSString *const FLCacheFileName = @"fc-subs.db";

@interface AppDelegate () {
    NSStatusItem *_statusItem;
    NSMenu *_menu;
    NSMenuItem *_statusMenuItem;
    NSMenuItem *_logMenuItem;
    NSMenuItem *_loadMenuItem;
    NSMenuItem *_cancelMenuItem;
    NSMenuItem *_unloadMenuItem;
    NSMenuItem *_detailsMenuItem;
    NSMenuItem *_exportMenuItem;
    NSMenuItem *_rebuildIndexMenuItem;
    NSMenuItem *_fontDirectoryMenuItem;
    NSMenuItem *_helpMenuItem;
    FLManager *_manager;
    NSPanel *_detailPanel;
    NSPanel *_logPanel;
    NSArray<NSString *> *_lastSubtitlePaths;
    NSString *_lastFontDirectory;
}
@end

@implementation AppDelegate

- (void)dealloc {
    [_detailPanel release];
    [_logPanel release];
    [_statusItem release];
    [_menu release];
    [_statusMenuItem release];
    [_logMenuItem release];
    [_loadMenuItem release];
    [_cancelMenuItem release];
    [_unloadMenuItem release];
    [_detailsMenuItem release];
    [_exportMenuItem release];
    [_rebuildIndexMenuItem release];
    [_fontDirectoryMenuItem release];
    [_helpMenuItem release];
    [_manager release];
    [_lastSubtitlePaths release];
    [_lastFontDirectory release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    _manager = [[FLManager alloc] init];
    [self buildMenu];
    [self updateMenuForStatus:@"Idle"];

    [NSApp setServicesProvider:self];
    [NSApp registerServicesMenuSendTypes:@[NSPasteboardTypeFileURL] returnTypes:@[]];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    [_manager unloadFonts];
    return NSTerminateNow;
}

- (void)buildMenu {
    _statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    if ([_statusItem respondsToSelector:@selector(button)] && _statusItem.button != nil) {
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"MenuBarIconTemplate" ofType:@"png"];
        NSImage *image = iconPath.length > 0
            ? [[[NSImage alloc] initWithContentsOfFile:iconPath] autorelease]
            : nil;
        if (image == nil) {
            if (@available(macOS 11.0, *)) {
                image = [NSImage imageWithSystemSymbolName:@"textformat" accessibilityDescription:@"FontLoaderSub"];
            }
        }
        if (image == nil) {
            image = [NSImage imageNamed:NSImageNameActionTemplate];
        }
        image.template = YES;
        image.size = NSMakeSize(18, 18);
        _statusItem.button.image = image;
        _statusItem.button.title = @"";
    }

    _menu = [[NSMenu alloc] initWithTitle:@"FontLoaderSub"];

    NSMenuItem *titleItem = [[[NSMenuItem alloc] initWithTitle:@"FontLoaderSub" action:nil keyEquivalent:@""] autorelease];
    titleItem.enabled = NO;
    [_menu addItem:titleItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    _statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Idle" action:nil keyEquivalent:@""];
    _statusMenuItem.enabled = NO;
    [_menu addItem:_statusMenuItem];

    [_menu addItem:[NSMenuItem separatorItem]];

    _loadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Load Fonts…" action:@selector(loadFontsFromMenu:) keyEquivalent:@""];
    _loadMenuItem.target = self;
    [_menu addItem:_loadMenuItem];

    _cancelMenuItem = [[NSMenuItem alloc] initWithTitle:@"Cancel Loading" action:@selector(cancelLoading:) keyEquivalent:@""];
    _cancelMenuItem.target = self;
    [_menu addItem:_cancelMenuItem];

    _unloadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Unload Fonts" action:@selector(unloadFontsFromMenu:) keyEquivalent:@""];
    _unloadMenuItem.target = self;
    [_menu addItem:_unloadMenuItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    _detailsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Load Details…" action:@selector(showLoadDetails:) keyEquivalent:@""];
    _detailsMenuItem.target = self;
    [_menu addItem:_detailsMenuItem];

    _exportMenuItem = [[NSMenuItem alloc] initWithTitle:@"Export Loaded Fonts…" action:@selector(exportLoadedFonts:) keyEquivalent:@""];
    _exportMenuItem.target = self;
    [_menu addItem:_exportMenuItem];

    _logMenuItem = [[NSMenuItem alloc] initWithTitle:@"View Log…" action:@selector(showLog:) keyEquivalent:@""];
    _logMenuItem.target = self;
    [_menu addItem:_logMenuItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    _rebuildIndexMenuItem = [[NSMenuItem alloc] initWithTitle:@"Rebuild Font Index" action:@selector(rebuildFontIndex:) keyEquivalent:@""];
    _rebuildIndexMenuItem.target = self;
    [_menu addItem:_rebuildIndexMenuItem];

    NSMenuItem *setFontDirItem = [[[NSMenuItem alloc] initWithTitle:@"Set Font Directory…" action:@selector(setFontDirectoryFromMenu:) keyEquivalent:@""] autorelease];
    setFontDirItem.target = self;
    [_menu addItem:setFontDirItem];

    _fontDirectoryMenuItem = [[NSMenuItem alloc] initWithTitle:@"Font Directory: Not Set" action:nil keyEquivalent:@""];
    _fontDirectoryMenuItem.enabled = NO;
    [_menu addItem:_fontDirectoryMenuItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    _helpMenuItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:@selector(showHelp:) keyEquivalent:@""];
    _helpMenuItem.target = self;
    [_menu addItem:_helpMenuItem];

    NSMenuItem *quitItem = [[[NSMenuItem alloc] initWithTitle:@"Quit FontLoaderSub" action:@selector(quitApp:) keyEquivalent:@""] autorelease];
    quitItem.target = self;
    [_menu addItem:quitItem];

    _statusItem.menu = _menu;
}

- (NSString *)defaultFontDirectory {
    return [[NSUserDefaults standardUserDefaults] stringForKey:FLDefaultFontDirectoryKey];
}

- (void)setDefaultFontDirectory:(NSString *)path {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (path.length > 0) {
        [defaults setObject:path forKey:FLDefaultFontDirectoryKey];
    } else {
        [defaults removeObjectForKey:FLDefaultFontDirectoryKey];
    }
}

- (void)updateMenuForStatus:(NSString *)statusText {
    _statusMenuItem.title = [NSString stringWithFormat:@"Status: %@", statusText ?: @"Idle"];
    BOOL loading = (_manager.state == FLManagerStateLoading);
    BOOL loaded = (_manager.state == FLManagerStateLoaded);
    BOOL hasDetails = (_manager.detailLines.count > 0);
    BOOL hasLoadedFonts = (_manager.loadedFontRelativePaths.count > 0);
    _loadMenuItem.enabled = !loading;
    _cancelMenuItem.enabled = loading;
    _unloadMenuItem.enabled = loaded;
    _detailsMenuItem.enabled = hasDetails;
    _exportMenuItem.enabled = loaded && hasLoadedFonts;
    _rebuildIndexMenuItem.enabled = !loading;
    _statusMenuItem.enabled = NO;

    NSString *fontDir = [self defaultFontDirectory];
    if (fontDir.length > 0) {
        NSString *displayName = fontDir.lastPathComponent.length > 0 ? fontDir.lastPathComponent : fontDir;
        _fontDirectoryMenuItem.title = [NSString stringWithFormat:@"Font Directory: %@", displayName];
        _fontDirectoryMenuItem.toolTip = fontDir;
    } else {
        _fontDirectoryMenuItem.title = @"Font Directory: Not Set";
        _fontDirectoryMenuItem.toolTip = nil;
    }
}

- (NSArray<NSString *> *)subtitlePathsFromPasteboard:(NSPasteboard *)pboard {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray<NSURL *> *urls = [pboard readObjectsForClasses:@[[NSURL class]] options:options];
    for (NSURL *url in urls) {
        if (url.isFileURL) {
            [paths addObject:url.path];
        }
    }

    NSMutableArray<NSString *> *acceptedPaths = [NSMutableArray array];
    for (NSString *path in paths) {
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            [acceptedPaths addObject:path];
            continue;
        }

        NSString *extension = path.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"ass"] || [extension isEqualToString:@"ssa"]) {
            [acceptedPaths addObject:path];
        }
    }

    return acceptedPaths;
}

- (void)startLoadingSubtitlePaths:(NSArray<NSString *> *)subtitlePaths fontDirectory:(NSString *)fontDirectory {
    if (subtitlePaths.count == 0) {
        [self updateMenuForStatus:@"No subtitle files"];
        return;
    }

    [_lastSubtitlePaths release];
    _lastSubtitlePaths = [subtitlePaths copy];
    [_lastFontDirectory release];
    _lastFontDirectory = [fontDirectory copy];

    [self updateMenuForStatus:@"Loading…"];
    [_manager loadFontsForSubtitles:subtitlePaths
                            fontDir:fontDirectory
                           progress:^(NSString *message) {
                               [self updateMenuForStatus:message];
                           }
                         completion:^(FLManagerState state, NSError *error) {
                             if (state == FLManagerStateLoaded) {
                                 NSString *status = [NSString stringWithFormat:@"Loaded %lu / Failed %lu / Missing %lu",
                                                     (unsigned long)self->_manager.numLoaded,
                                                     (unsigned long)self->_manager.numFailed,
                                                     (unsigned long)self->_manager.numUnmatched];
                                 [self updateMenuForStatus:status];
                             } else {
                                 [self updateMenuForStatus:error.localizedDescription ?: @"Failed"];
                             }
                         }];
}

- (IBAction)loadFontsFromMenu:(id)sender {
    (void)sender;

    NSOpenPanel *subtitlePanel = [NSOpenPanel openPanel];
    subtitlePanel.canChooseFiles = YES;
    subtitlePanel.canChooseDirectories = YES;
    subtitlePanel.allowsMultipleSelection = YES;
    subtitlePanel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"ass"],
        [UTType typeWithFilenameExtension:@"ssa"],
    ];

    if ([subtitlePanel runModal] != NSModalResponseOK) {
        return;
    }

    NSMutableArray<NSString *> *subtitlePaths = [NSMutableArray array];
    for (NSURL *url in subtitlePanel.URLs) {
        if (url.isFileURL) {
            [subtitlePaths addObject:url.path];
        }
    }

    NSString *fontDirectory = [self defaultFontDirectory];
    if (fontDirectory.length == 0) {
        fontDirectory = [self chooseFontDirectory];
        if (fontDirectory.length == 0) {
            return;
        }
        [self setDefaultFontDirectory:fontDirectory];
    }

    [self startLoadingSubtitlePaths:subtitlePaths fontDirectory:fontDirectory];
}

- (NSString *)chooseFontDirectory {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;

    if ([panel runModal] != NSModalResponseOK) {
        return nil;
    }
    return panel.URL.path;
}

- (IBAction)setFontDirectoryFromMenu:(id)sender {
    (void)sender;

    NSString *fontDirectory = [self chooseFontDirectory];
    if (fontDirectory.length == 0) {
        return;
    }

    [self setDefaultFontDirectory:fontDirectory];
    [self updateMenuForStatus:@"Idle"];
}

- (IBAction)unloadFontsFromMenu:(id)sender {
    (void)sender;
    [_manager unloadFonts];
    [self updateMenuForStatus:@"Idle"];
}

- (IBAction)cancelLoading:(id)sender {
    (void)sender;
    [_manager cancel];
    [self updateMenuForStatus:@"Cancelled"];
}

- (IBAction)quitApp:(id)sender {
    (void)sender;
    [_manager unloadFonts];
    [NSApp terminate:nil];
}

- (NSString *)uniqueDestinationPathForFilename:(NSString *)filename inDirectory:(NSString *)directory {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *baseName = filename.stringByDeletingPathExtension;
    NSString *extension = filename.pathExtension;
    NSString *candidate = [directory stringByAppendingPathComponent:filename];
    NSUInteger suffix = 2;

    while ([fileManager fileExistsAtPath:candidate]) {
        NSString *numberedName;
        if (extension.length > 0) {
            numberedName = [NSString stringWithFormat:@"%@ %lu.%@",
                                                       baseName,
                                                       (unsigned long)suffix,
                                                       extension];
        } else {
            numberedName = [NSString stringWithFormat:@"%@ %lu",
                                                       baseName,
                                                       (unsigned long)suffix];
        }
        candidate = [directory stringByAppendingPathComponent:numberedName];
        suffix++;
    }
    return candidate;
}

- (void)showMessage:(NSString *)message informativeText:(NSString *)informativeText {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = message ?: @"FontLoaderSub";
    alert.informativeText = informativeText ?: @"";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (IBAction)exportLoadedFonts:(id)sender {
    (void)sender;

    NSArray<NSString *> *relativePaths = _manager.loadedFontRelativePaths;
    NSString *fontDirectory = _lastFontDirectory ?: [self defaultFontDirectory];
    if (relativePaths.count == 0 || fontDirectory.length == 0) {
        [self showMessage:@"No loaded font files to export."
          informativeText:@"Load subtitles first, then export the loaded font files."];
        return;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Export";
    panel.message = @"Choose a folder for the loaded font files.";
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NSString *destinationDirectory = panel.URL.path;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSUInteger copied = 0;
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (NSString *relativePath in relativePaths) {
        NSString *sourcePath = [fontDirectory stringByAppendingPathComponent:relativePath];
        NSString *destinationPath = [self uniqueDestinationPathForFilename:sourcePath.lastPathComponent
                                                               inDirectory:destinationDirectory];
        NSError *error = nil;
        if ([fileManager copyItemAtPath:sourcePath toPath:destinationPath error:&error]) {
            copied++;
        } else {
            [failed addObject:sourcePath.lastPathComponent ?: relativePath];
        }
    }

    NSString *message = [NSString stringWithFormat:@"Exported %lu font file%@.",
                                                   (unsigned long)copied,
                                                   copied == 1 ? @"" : @"s"];
    NSString *detail = failed.count == 0
        ? destinationDirectory
        : [NSString stringWithFormat:@"Failed: %@", [failed componentsJoinedByString:@", "]];
    [self showMessage:message informativeText:detail];
}

- (IBAction)rebuildFontIndex:(id)sender {
    (void)sender;

    NSString *fontDirectory = [self defaultFontDirectory];
    if (fontDirectory.length == 0) {
        fontDirectory = [self chooseFontDirectory];
        if (fontDirectory.length == 0) {
            return;
        }
        [self setDefaultFontDirectory:fontDirectory];
    }

    NSString *cachePath = [fontDirectory stringByAppendingPathComponent:FLCacheFileName];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    if ([fileManager fileExistsAtPath:cachePath] &&
        ![fileManager removeItemAtPath:cachePath error:&error]) {
        [self showMessage:@"Could not remove the font index."
          informativeText:error.localizedDescription ?: cachePath];
        return;
    }

    if (_lastSubtitlePaths.count > 0) {
        NSArray<NSString *> *subtitlePaths = [[_lastSubtitlePaths copy] autorelease];
        [_manager unloadFonts];
        [self updateMenuForStatus:@"Rebuilding index…"];
        [self startLoadingSubtitlePaths:subtitlePaths fontDirectory:fontDirectory];
    } else {
        [self updateMenuForStatus:@"Index removed"];
        [self showMessage:@"Font index removed."
          informativeText:@"The next load will rebuild the index for this font directory."];
    }
}

- (IBAction)showHelp:(id)sender {
    (void)sender;
    [self showMessage:@"FontLoaderSub"
      informativeText:@"1. Set the font directory.\n2. Load ASS/SSA subtitle files or folders.\n3. Keep FontLoaderSub running while watching.\n4. Rebuild the font index after changing fonts."];
}

- (IBAction)showLoadDetails:(id)sender {
    (void)sender;
    NSArray<NSString *> *lines = _manager.detailLines;
    if (lines.count == 0) {
        return;
    }

    if (_detailPanel == nil) {
        NSRect frame = NSMakeRect(0, 0, 560, 400);
        _detailPanel = [[NSPanel alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
        _detailPanel.title = @"Font Load Details";
        _detailPanel.releasedWhenClosed = NO;
        [_detailPanel center];

        NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
        scrollView.hasVerticalScroller = YES;
        scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSTextView *textView = [[[NSTextView alloc] initWithFrame:scrollView.contentView.bounds] autorelease];
        textView.editable = NO;
        textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        textView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        textView.textContainerInset = NSMakeSize(8, 8);

        scrollView.documentView = textView;
        _detailPanel.contentView = scrollView;
    }

    NSTextView *textView = (NSTextView *)((NSScrollView *)_detailPanel.contentView).documentView;
    [textView.textStorage setAttributedString:[[[NSAttributedString alloc]
        initWithString:[lines componentsJoinedByString:@"\n"]
            attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
            }] autorelease]];

    [_detailPanel makeKeyAndOrderFront:nil];
    [NSApp activate];
}

- (IBAction)showLog:(id)sender {
    (void)sender;

    if (_logPanel == nil) {
        NSRect frame = NSMakeRect(0, 0, 600, 450);
        _logPanel = [[NSPanel alloc] initWithContentRect:frame
                                               styleMask:(NSWindowStyleMaskTitled |
                                                          NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskResizable)
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
        _logPanel.title = @"Load Log";
        _logPanel.releasedWhenClosed = NO;
        [_logPanel center];

        NSButton *clearButton = [[[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)] autorelease];
        clearButton.title = @"Clear Log";
        clearButton.bezelStyle = NSBezelStyleRounded;
        clearButton.target = self;
        clearButton.action = @selector(clearLog:);
        clearButton.translatesAutoresizingMaskIntoConstraints = NO;

        NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
        scrollView.hasVerticalScroller = YES;
        scrollView.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextView *textView = [[[NSTextView alloc] initWithFrame:scrollView.contentView.bounds] autorelease];
        textView.editable = NO;
        textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        textView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        textView.textContainerInset = NSMakeSize(8, 8);
        scrollView.documentView = textView;

        NSView *contentView = [[[NSView alloc] initWithFrame:frame] autorelease];
        [contentView addSubview:scrollView];
        [contentView addSubview:clearButton];
        _logPanel.contentView = contentView;

        [NSLayoutConstraint activateConstraints:@[
            [clearButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-8],
            [clearButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-8],
            [scrollView.topAnchor constraintEqualToAnchor:contentView.topAnchor],
            [scrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
            [scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
            [scrollView.bottomAnchor constraintEqualToAnchor:clearButton.topAnchor constant:-8],
        ]];
    }

    NSScrollView *scrollView = nil;
    for (NSView *subview in _logPanel.contentView.subviews) {
        if ([subview isKindOfClass:[NSScrollView class]]) {
            scrollView = (NSScrollView *)subview;
            break;
        }
    }
    NSTextView *textView = (NSTextView *)scrollView.documentView;
    NSString *log = _manager.logText ?: @"";
    [textView.textStorage setAttributedString:[[[NSAttributedString alloc]
        initWithString:log
            attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
            }] autorelease]];

    [_logPanel makeKeyAndOrderFront:nil];
    [NSApp activate];
}

- (IBAction)clearLog:(id)sender {
    (void)sender;
    [_manager clearLog];

    if (_logPanel != nil) {
        NSScrollView *scrollView = nil;
        for (NSView *subview in _logPanel.contentView.subviews) {
            if ([subview isKindOfClass:[NSScrollView class]]) {
                scrollView = (NSScrollView *)subview;
                break;
            }
        }
        NSTextView *textView = (NSTextView *)scrollView.documentView;
        [textView.textStorage setAttributedString:[[[NSAttributedString alloc]
            initWithString:@""
                attributes:@{
                    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
                }] autorelease]];
    }
}

- (void)loadFontsFromService:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
    (void)userData;

    NSString *fontDirectory = [self defaultFontDirectory];
    if (fontDirectory.length == 0) {
        if (error != NULL) {
            *error = @"Set a default font directory first from the menu bar app.";
        }
        return;
    }

    NSArray<NSString *> *subtitlePaths = [self subtitlePathsFromPasteboard:pboard];
    if (subtitlePaths.count == 0) {
        if (error != NULL) {
            *error = @"No .ass/.ssa files or folders were provided.";
        }
        return;
    }

    [NSApp activate];
    [self startLoadingSubtitlePaths:subtitlePaths fontDirectory:fontDirectory];
}

@end
