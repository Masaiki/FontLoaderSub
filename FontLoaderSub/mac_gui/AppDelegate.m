#import "AppDelegate.h"

#import "FLManager.h"

static NSString *const FLDefaultFontDirectoryKey = @"defaultFontDirectory";

@interface AppDelegate () {
    NSStatusItem *_statusItem;
    NSMenu *_menu;
    NSMenuItem *_statusMenuItem;
    NSMenuItem *_unloadMenuItem;
    NSMenuItem *_fontDirectoryMenuItem;
    FLManager *_manager;
}
@end

@implementation AppDelegate

- (void)dealloc {
    [_manager release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    _manager = [[FLManager alloc] init];
    [self buildMenu];
    [self updateMenuForStatus:@"Idle"];

    [NSApp setServicesProvider:self];
    [NSApp registerServicesMenuSendTypes:@[NSFilenamesPboardType, NSPasteboardTypeFileURL] returnTypes:@[]];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    [_manager unloadFonts];
    return NSTerminateNow;
}

- (void)buildMenu {
    _statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    if ([_statusItem respondsToSelector:@selector(button)] && _statusItem.button != nil) {
        NSImage *image;
        if (@available(macOS 11.0, *)) {
            image = [NSImage imageWithSystemSymbolName:@"textformat" accessibilityDescription:@"FontLoaderSub"];
        } else {
            image = [NSImage imageNamed:NSImageNameActionTemplate];
        }
        image.template = YES;
        _statusItem.button.image = image;
    } else {
        _statusItem.title = @"FLS";
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

    NSMenuItem *loadItem = [[[NSMenuItem alloc] initWithTitle:@"Load Fonts…" action:@selector(loadFontsFromMenu:) keyEquivalent:@""] autorelease];
    loadItem.target = self;
    [_menu addItem:loadItem];

    _unloadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Unload Fonts" action:@selector(unloadFontsFromMenu:) keyEquivalent:@""];
    _unloadMenuItem.target = self;
    [_menu addItem:_unloadMenuItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *setFontDirItem = [[[NSMenuItem alloc] initWithTitle:@"Set Font Directory…" action:@selector(setFontDirectoryFromMenu:) keyEquivalent:@""] autorelease];
    setFontDirItem.target = self;
    [_menu addItem:setFontDirItem];

    _fontDirectoryMenuItem = [[NSMenuItem alloc] initWithTitle:@"Font Directory: Not Set" action:nil keyEquivalent:@""];
    _fontDirectoryMenuItem.enabled = NO;
    [_menu addItem:_fontDirectoryMenuItem];
    [_menu addItem:[NSMenuItem separatorItem]];

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
    _unloadMenuItem.enabled = (_manager.state == FLManagerStateLoaded);

    NSString *fontDir = [self defaultFontDirectory];
    if (fontDir.length > 0) {
        _fontDirectoryMenuItem.title = [NSString stringWithFormat:@"Font Directory: %@", fontDir];
    } else {
        _fontDirectoryMenuItem.title = @"Font Directory: Not Set";
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

    if (paths.count == 0) {
        NSArray<NSString *> *fallback = [pboard propertyListForType:NSFilenamesPboardType];
        for (NSString *path in fallback) {
            [paths addObject:path];
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
    subtitlePanel.allowedFileTypes = @[@"ass", @"ssa"];
    subtitlePanel.allowsOtherFileTypes = NO;

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

- (IBAction)quitApp:(id)sender {
    (void)sender;
    [_manager unloadFonts];
    [NSApp terminate:nil];
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

    [NSApp activateIgnoringOtherApps:YES];
    [self startLoadingSubtitlePaths:subtitlePaths fontDirectory:fontDirectory];
}

@end
