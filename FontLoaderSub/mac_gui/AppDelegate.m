#import "AppDelegate.h"

#import "FLManager.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const FLDefaultFontDirectoryKey = @"defaultFontDirectory";

@interface AppDelegate () {
    NSStatusItem *_statusItem;
    NSMenu *_menu;
    NSMenuItem *_statusMenuItem;
    NSMenuItem *_logMenuItem;
    NSMenuItem *_loadMenuItem;
    NSMenuItem *_unloadMenuItem;
    NSMenuItem *_fontDirectoryMenuItem;
    FLManager *_manager;
    NSPanel *_detailPanel;
    NSPanel *_logPanel;
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
    [_unloadMenuItem release];
    [_fontDirectoryMenuItem release];
    [_manager release];
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
        NSImage *image;
        if (@available(macOS 11.0, *)) {
            image = [NSImage imageWithSystemSymbolName:@"textformat" accessibilityDescription:@"FontLoaderSub"];
        } else {
            image = [NSImage imageNamed:NSImageNameActionTemplate];
        }
        image.template = YES;
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

    _logMenuItem = [[NSMenuItem alloc] initWithTitle:@"View Log…" action:@selector(showLog:) keyEquivalent:@""];
    _logMenuItem.target = self;
    [_menu addItem:_logMenuItem];

    [_menu addItem:[NSMenuItem separatorItem]];

    _loadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Load Fonts…" action:@selector(loadFontsFromMenu:) keyEquivalent:@""];
    _loadMenuItem.target = self;
    [_menu addItem:_loadMenuItem];

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
    BOOL loading = (_manager.state == FLManagerStateLoading);
    BOOL loaded = (_manager.state == FLManagerStateLoaded);
    _loadMenuItem.enabled = !loading;
    _unloadMenuItem.enabled = loaded;

    if (loaded && _manager.detailLines.count > 0) {
        _statusMenuItem.action = @selector(showLoadDetails:);
        _statusMenuItem.target = self;
        _statusMenuItem.enabled = YES;
    } else {
        _statusMenuItem.action = nil;
        _statusMenuItem.target = nil;
        _statusMenuItem.enabled = NO;
    }

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

- (IBAction)quitApp:(id)sender {
    (void)sender;
    [_manager unloadFonts];
    [NSApp terminate:nil];
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
