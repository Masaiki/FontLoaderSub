#import "FLManager.h"

#import <dispatch/dispatch.h>

#import "FLBridge.h"

#include "font_loader.h"
#include "font_set.h"
#include "util.h"

static NSString *const FLManagerErrorDomain = @"com.fontloadersub.manager";
static const wchar_t *kCacheFile = L"fc-subs.db";
static const wchar_t *kBlackFile = L"fc-ignore.txt";

static void *fl_manager_realloc(void *existing, size_t size, void *arg) {
    (void)arg;
    if (size == 0) {
        free(existing);
        return NULL;
    }
    return realloc(existing, size);
}

@interface FLManager () {
    dispatch_queue_t _queue;
    FL_LoaderCtx *_ctx;
    allocator_t _alloc;
    FLManagerState _state;
    NSUInteger _numLoaded;
    NSUInteger _numFailed;
    NSUInteger _numUnmatched;
    NSUInteger _generation;
}
@end

@implementation FLManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.fontloadersub.worker", DISPATCH_QUEUE_SERIAL);
        _alloc.alloc = fl_manager_realloc;
        _alloc.arg = NULL;
        _state = FLManagerStateIdle;
    }
    return self;
}

- (void)dealloc {
    [self unloadFonts];
    [super dealloc];
}

- (FLManagerState)state {
    return _state;
}

- (NSUInteger)numLoaded {
    return _numLoaded;
}

- (NSUInteger)numFailed {
    return _numFailed;
}

- (NSUInteger)numUnmatched {
    return _numUnmatched;
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:FLManagerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Operation failed."}];
}

- (void)publishProgress:(NSString *)message generation:(NSUInteger)generation handler:(void(^)(NSString *))handler {
    if (handler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation) {
            return;
        }
        handler(message);
    });
}

- (void)finishWithState:(FLManagerState)state
              generation:(NSUInteger)generation
               numLoaded:(NSUInteger)numLoaded
               numFailed:(NSUInteger)numFailed
            numUnmatched:(NSUInteger)numUnmatched
                   error:(NSError *)error
              completion:(void(^)(FLManagerState, NSError *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation) {
            return;
        }
        self->_state = state;
        self->_numLoaded = numLoaded;
        self->_numFailed = numFailed;
        self->_numUnmatched = numUnmatched;
        if (completion != nil) {
            completion(state, error);
        }
    });
}

- (void)resetContextLocked {
    if (_ctx == NULL) {
        return;
    }
    fl_unload_fonts(_ctx);
    fl_free(_ctx);
    free(_ctx);
    _ctx = NULL;
}

- (BOOL)prepareContextLocked:(NSError **)error {
    [self resetContextLocked];

    _ctx = calloc(1, sizeof(FL_LoaderCtx));
    if (_ctx == NULL) {
        if (error != NULL) {
            *error = [self errorWithCode:FL_OUT_OF_MEMORY description:@"Out of memory."];
        }
        return NO;
    }

    int result = fl_init(_ctx, &_alloc);
    if (result != FL_OK) {
        if (error != NULL) {
            *error = [self errorWithCode:result description:@"Failed to initialize font loader."];
        }
        free(_ctx);
        _ctx = NULL;
        return NO;
    }

    return YES;
}

- (void)loadFontsForSubtitles:(NSArray<NSString *> *)subtitlePaths
                      fontDir:(NSString *)fontDir
                     progress:(void(^)(NSString *message))progress
                   completion:(void(^)(FLManagerState state, NSError *error))completion {
    NSArray *subtitleCopy = [subtitlePaths copy];
    NSString *fontDirCopy = [fontDir copy];
    void (^progressCopy)(NSString *) = [progress copy];
    void (^completionCopy)(FLManagerState, NSError *) = [completion copy];

    NSUInteger generation = ++_generation;
    _state = FLManagerStateLoading;
    _numLoaded = 0;
    _numFailed = 0;
    _numUnmatched = 0;

    dispatch_async(_queue, ^{
        NSError *error = nil;
        FS_Stat stat = {0};
        int result = FL_OK;
        NSUInteger numLoaded = 0;
        NSUInteger numFailed = 0;
        NSUInteger numUnmatched = 0;

        [self publishProgress:@"Scanning subtitles…" generation:generation handler:progressCopy];

        if (![self prepareContextLocked:&error]) {
            [self finishWithState:FLManagerStateFailed
                        generation:generation
                         numLoaded:0
                         numFailed:0
                      numUnmatched:0
                             error:error
                        completion:completionCopy];
            [subtitleCopy release];
            [fontDirCopy release];
            [progressCopy release];
            [completionCopy release];
            return;
        }

        wchar_t *fontDirW = FLNSStringToWChar(fontDirCopy);
        if (fontDirW == NULL) {
            error = [self errorWithCode:FL_OUT_OF_MEMORY description:@"Failed to convert font directory path."];
            [self resetContextLocked];
            [self finishWithState:FLManagerStateFailed
                        generation:generation
                         numLoaded:0
                         numFailed:0
                      numUnmatched:0
                             error:error
                        completion:completionCopy];
            [subtitleCopy release];
            [fontDirCopy release];
            [progressCopy release];
            [completionCopy release];
            return;
        }

        for (NSString *subtitlePath in subtitleCopy) {
            wchar_t *subtitleW = FLNSStringToWChar(subtitlePath);
            if (subtitleW == NULL) {
                result = FL_OUT_OF_MEMORY;
                break;
            }
            result = fl_add_subs(_ctx, subtitleW);
            free(subtitleW);
            if (result != FL_OK && result != FL_OS_ERROR) {
                break;
            }
            result = FL_OK;
        }

        if (result == FL_OK) {
            [self publishProgress:@"Loading font cache…" generation:generation handler:progressCopy];
            result = fl_scan_fonts(_ctx, fontDirW, kCacheFile, kBlackFile);
            if (_ctx->font_set != NULL) {
                fs_stat(_ctx->font_set, &stat);
            }
        }

        if (result == FL_OK && stat.num_face == 0) {
            [self publishProgress:@"Scanning font files…" generation:generation handler:progressCopy];
            result = fl_scan_fonts(_ctx, fontDirW, NULL, kBlackFile);
            if (result == FL_OK) {
                fl_save_cache(_ctx, kCacheFile);
            }
        }

        if (result == FL_OK) {
            [self publishProgress:@"Loading fonts…" generation:generation handler:progressCopy];
            result = fl_load_fonts(_ctx);
        }

        free(fontDirW);

        if (result == FL_OK) {
            numLoaded = _ctx->num_font_loaded;
            numFailed = _ctx->num_font_failed;
            numUnmatched = _ctx->num_font_unmatched;
            [self publishProgress:@"Fonts loaded." generation:generation handler:progressCopy];
            [self finishWithState:FLManagerStateLoaded
                        generation:generation
                         numLoaded:numLoaded
                         numFailed:numFailed
                      numUnmatched:numUnmatched
                             error:nil
                        completion:completionCopy];
        } else {
            error = [self errorWithCode:result description:@"Failed to load fonts."];
            [self resetContextLocked];
            [self finishWithState:FLManagerStateFailed
                        generation:generation
                         numLoaded:0
                         numFailed:0
                      numUnmatched:0
                             error:error
                        completion:completionCopy];
        }

        [subtitleCopy release];
        [fontDirCopy release];
        [progressCopy release];
        [completionCopy release];
    });
}

- (void)unloadFonts {
    _generation++;
    dispatch_sync(_queue, ^{
        [self resetContextLocked];
    });
    _state = FLManagerStateIdle;
    _numLoaded = 0;
    _numFailed = 0;
    _numUnmatched = 0;
}

- (void)cancel {
    _generation++;
    _state = FLManagerStateIdle;
    _numLoaded = 0;
    _numFailed = 0;
    _numUnmatched = 0;
    dispatch_async(_queue, ^{
        if (self->_ctx != NULL) {
            fl_cancel(self->_ctx);
        }
    });
}

@end
