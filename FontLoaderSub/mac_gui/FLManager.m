#import "FLManager.h"

#import <dispatch/dispatch.h>

#include <errno.h>

static NSString *const FLManagerErrorDomain = @"com.fontloadersub.manager";
static NSString *const FLReadyPrefix = @"FLS_READY ";

@interface FLManager () {
    dispatch_queue_t _queue;
    FLManagerState _state;
    NSUInteger _numLoaded;
    NSUInteger _numFailed;
    NSUInteger _numUnmatched;
    NSUInteger _generation;
    NSTask *_task;
    NSPipe *_stdinPipe;
    NSPipe *_stdoutPipe;
    NSPipe *_stderrPipe;
    NSMutableData *_stdoutBuffer;
    NSMutableData *_stderrBuffer;
    BOOL _helperReady;
}
@end

@implementation FLManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.fontloadersub.worker", DISPATCH_QUEUE_SERIAL);
        _state = FLManagerStateIdle;
    }
    return self;
}

- (void)dealloc {
    [self unloadFonts];
    [_task release];
    [_stdinPipe release];
    [_stdoutPipe release];
    [_stderrPipe release];
    [_stdoutBuffer release];
    [_stderrBuffer release];
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

- (void)closeFileHandle:(NSFileHandle *)fileHandle {
    @try {
        [fileHandle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

- (void)clearTaskLocked {
    if (_stdoutPipe != nil) {
        _stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    }
    if (_stderrPipe != nil) {
        _stderrPipe.fileHandleForReading.readabilityHandler = nil;
    }
    [_task release];
    _task = nil;
    [_stdinPipe release];
    _stdinPipe = nil;
    [_stdoutPipe release];
    _stdoutPipe = nil;
    [_stderrPipe release];
    _stderrPipe = nil;
    [_stdoutBuffer release];
    _stdoutBuffer = nil;
    [_stderrBuffer release];
    _stderrBuffer = nil;
    _helperReady = NO;
}

- (void)shutdownTaskLocked {
    if (_stdinPipe != nil) {
        [self closeFileHandle:_stdinPipe.fileHandleForWriting];
    }
    if (_task != nil && _task.isRunning) {
        [_task waitUntilExit];
    }
    [self clearTaskLocked];
}

- (void)terminateTaskLocked {
    if (_stdinPipe != nil) {
        [self closeFileHandle:_stdinPipe.fileHandleForWriting];
    }
    if (_task != nil && _task.isRunning) {
        [_task terminate];
        [_task waitUntilExit];
    }
    [self clearTaskLocked];
}

- (NSString *)helperExecutablePath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/Helpers/fontloadersub"];
}

- (BOOL)parseReadyLine:(NSString *)line
             numLoaded:(NSUInteger *)numLoaded
             numFailed:(NSUInteger *)numFailed
          numUnmatched:(NSUInteger *)numUnmatched {
    NSScanner *scanner;
    NSInteger loaded = 0;
    NSInteger failed = 0;
    NSInteger missing = 0;

    if (![line hasPrefix:FLReadyPrefix]) {
        return NO;
    }

    scanner = [NSScanner scannerWithString:[line substringFromIndex:FLReadyPrefix.length]];
    if (![scanner scanString:@"loaded=" intoString:NULL] || ![scanner scanInteger:&loaded]) {
        return NO;
    }
    if (![scanner scanString:@" failed=" intoString:NULL] || ![scanner scanInteger:&failed]) {
        return NO;
    }
    if (![scanner scanString:@" missing=" intoString:NULL] || ![scanner scanInteger:&missing]) {
        return NO;
    }

    if (numLoaded != NULL) {
        *numLoaded = (NSUInteger)MAX(loaded, 0);
    }
    if (numFailed != NULL) {
        *numFailed = (NSUInteger)MAX(failed, 0);
    }
    if (numUnmatched != NULL) {
        *numUnmatched = (NSUInteger)MAX(missing, 0);
    }
    return YES;
}

- (void)processOutputBuffer:(NSMutableData *)buffer
                 generation:(NSUInteger)generation
                   progress:(void(^)(NSString *message))progress
                  numLoaded:(NSUInteger *)numLoaded
                  numFailed:(NSUInteger *)numFailed
               numUnmatched:(NSUInteger *)numUnmatched
                onReadyLine:(void(^)(void))onReadyLine {
    while (YES) {
        const void *bytes = buffer.bytes;
        NSUInteger length = buffer.length;
        const void *newline = memchr(bytes, '\n', length);
        NSRange lineRange;
        NSData *lineData;
        NSString *line;

        if (newline == NULL) {
            break;
        }

        lineRange = NSMakeRange(0, (const char *)newline - (const char *)bytes);
        lineData = [buffer subdataWithRange:lineRange];
        [buffer replaceBytesInRange:NSMakeRange(0, lineRange.length + 1) withBytes:NULL length:0];

        line = [[[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding] autorelease];
        if (line == nil) {
            continue;
        }
        if ([line hasSuffix:@"\r"]) {
            line = [line substringToIndex:line.length - 1];
        }
        if (line.length == 0) {
            continue;
        }

        if ([self parseReadyLine:line numLoaded:numLoaded numFailed:numFailed numUnmatched:numUnmatched]) {
            _helperReady = YES;
            if (onReadyLine != nil) {
                onReadyLine();
            }
            continue;
        }

        [self publishProgress:line generation:generation handler:progress];
    }
}

- (void)appendData:(NSData *)data
          toBuffer:(NSMutableData *)buffer
        generation:(NSUInteger)generation
          progress:(void(^)(NSString *message))progress
         numLoaded:(NSUInteger *)numLoaded
         numFailed:(NSUInteger *)numFailed
      numUnmatched:(NSUInteger *)numUnmatched
       onReadyLine:(void(^)(void))onReadyLine {
    if (data.length == 0) {
        return;
    }
    [buffer appendData:data];
    [self processOutputBuffer:buffer
                   generation:generation
                     progress:progress
                    numLoaded:numLoaded
                    numFailed:numFailed
                 numUnmatched:numUnmatched
                  onReadyLine:onReadyLine];
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
        NSString *helperPath = [self helperExecutablePath];
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"--font-dir", fontDirCopy, nil];
        __block NSUInteger numLoaded = 0;
        __block NSUInteger numFailed = 0;
        __block NSUInteger numUnmatched = 0;
        __block BOOL completionSent = NO;
        NSError *error = nil;

        [self terminateTaskLocked];

        if (![[NSFileManager defaultManager] isExecutableFileAtPath:helperPath]) {
            error = [self errorWithCode:ENOENT description:@"Bundled CLI helper is missing."];
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
            [arguments addObject:@"--subtitle"];
            [arguments addObject:subtitlePath];
        }

        _task = [[NSTask alloc] init];
        _stdinPipe = [[NSPipe alloc] init];
        _stdoutPipe = [[NSPipe alloc] init];
        _stderrPipe = [[NSPipe alloc] init];
        _stdoutBuffer = [[NSMutableData alloc] init];
        _stderrBuffer = [[NSMutableData alloc] init];
        _helperReady = NO;

        _task.launchPath = helperPath;
        _task.arguments = arguments;
        _task.standardInput = _stdinPipe;
        _task.standardOutput = _stdoutPipe;
        _task.standardError = _stderrPipe;

        _stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fileHandle) {
            NSData *data = [fileHandle availableData];
            dispatch_async(self->_queue, ^{
                if (generation != self->_generation || self->_stdoutBuffer == nil) {
                    return;
                }
                [self appendData:data
                        toBuffer:self->_stdoutBuffer
                      generation:generation
                        progress:progressCopy
                       numLoaded:&numLoaded
                       numFailed:&numFailed
                    numUnmatched:&numUnmatched
                     onReadyLine:^{
                         if (!completionSent) {
                             completionSent = YES;
                             [self finishWithState:FLManagerStateLoaded
                                        generation:generation
                                         numLoaded:numLoaded
                                         numFailed:numFailed
                                      numUnmatched:numUnmatched
                                             error:nil
                                        completion:completionCopy];
                         }
                     }];
            });
        };

        _stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fileHandle) {
            NSData *data = [fileHandle availableData];
            dispatch_async(self->_queue, ^{
                if (generation != self->_generation || self->_stderrBuffer == nil) {
                    return;
                }
                [self appendData:data
                        toBuffer:self->_stderrBuffer
                      generation:generation
                        progress:progressCopy
                       numLoaded:NULL
                       numFailed:NULL
                    numUnmatched:NULL
                     onReadyLine:nil];
            });
        };

        _task.terminationHandler = ^(NSTask *task) {
            dispatch_async(self->_queue, ^{
                NSString *stderrText;
                if (generation != self->_generation) {
                    return;
                }
                self->_stdoutPipe.fileHandleForReading.readabilityHandler = nil;
                self->_stderrPipe.fileHandleForReading.readabilityHandler = nil;
                if (!completionSent && !self->_helperReady) {
                    stderrText = [[[NSString alloc] initWithData:self->_stderrBuffer encoding:NSUTF8StringEncoding] autorelease];
                    if (stderrText.length == 0) {
                        stderrText = @"Failed to load fonts.";
                    }
                    completionSent = YES;
                    [self finishWithState:FLManagerStateFailed
                               generation:generation
                                numLoaded:0
                                numFailed:0
                             numUnmatched:0
                                    error:[self errorWithCode:task.terminationStatus description:stderrText]
                               completion:completionCopy];
                }
                [self clearTaskLocked];
                [subtitleCopy release];
                [fontDirCopy release];
                [progressCopy release];
                [completionCopy release];
            });
        };

        @try {
            [_task launch];
        } @catch (NSException *exception) {
            error = [self errorWithCode:EIO description:exception.reason ?: @"Failed to start bundled CLI helper."];
            [self clearTaskLocked];
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
        }
    });
}

- (void)unloadFonts {
    _generation++;
    dispatch_sync(_queue, ^{
        [self shutdownTaskLocked];
    });
    _state = FLManagerStateIdle;
    _numLoaded = 0;
    _numFailed = 0;
    _numUnmatched = 0;
}

- (void)cancel {
    _generation++;
    dispatch_async(_queue, ^{
        [self terminateTaskLocked];
    });
    _state = FLManagerStateIdle;
    _numLoaded = 0;
    _numFailed = 0;
    _numUnmatched = 0;
}

@end
