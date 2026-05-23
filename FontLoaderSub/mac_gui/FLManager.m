#import "FLManager.h"

#import <dispatch/dispatch.h>

#include <errno.h>
#include <signal.h>

static NSString *const FLManagerErrorDomain = @"com.fontloadersub.manager";
static NSString *const FLReadyPrefix = @"FLS_READY ";
static NSTimeInterval const FLHelperGracefulShutdownTimeout = 5.0;

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
    NSMutableArray<NSString *> *_detailLines;
    NSMutableArray<NSString *> *_loadedFontRelativePaths;
    NSMutableString *_logText;
}
@end

@implementation FLManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.fontloadersub.worker", DISPATCH_QUEUE_SERIAL);
        _state = FLManagerStateIdle;
        _logText = [[NSMutableString alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self unloadFonts];
    [_detailLines release];
    [_loadedFontRelativePaths release];
    [_logText release];
    [_task release];
    [_stdinPipe release];
    [_stdoutPipe release];
    [_stderrPipe release];
    [_stdoutBuffer release];
    [_stderrBuffer release];
    [super dealloc];
}

- (FLManagerState)state {
    @synchronized (self) {
        return _state;
    }
}

- (NSUInteger)numLoaded {
    @synchronized (self) {
        return _numLoaded;
    }
}

- (NSUInteger)numFailed {
    @synchronized (self) {
        return _numFailed;
    }
}

- (NSUInteger)numUnmatched {
    @synchronized (self) {
        return _numUnmatched;
    }
}

- (NSArray<NSString *> *)detailLines {
    @synchronized (self) {
        return [[_detailLines copy] autorelease];
    }
}

- (NSArray<NSString *> *)loadedFontRelativePaths {
    @synchronized (self) {
        return [[_loadedFontRelativePaths copy] autorelease];
    }
}

- (NSString *)logText {
    @synchronized (self) {
        return [[_logText copy] autorelease];
    }
}

- (void)clearLog {
    @synchronized (self) {
        [_logText setString:@""];
    }
}

- (void)appendLog:(NSString *)line {
    @synchronized (self) {
        [_logText appendString:line ?: @""];
        [_logText appendString:@"\n"];
    }
}

- (NSUInteger)advanceGeneration {
    @synchronized (self) {
        _generation++;
        return _generation;
    }
}

- (BOOL)isCurrentGeneration:(NSUInteger)generation {
    @synchronized (self) {
        return generation == _generation;
    }
}

- (void)setVisibleState:(FLManagerState)state
              numLoaded:(NSUInteger)numLoaded
              numFailed:(NSUInteger)numFailed
           numUnmatched:(NSUInteger)numUnmatched {
    @synchronized (self) {
        _state = state;
        _numLoaded = numLoaded;
        _numFailed = numFailed;
        _numUnmatched = numUnmatched;
    }
}

- (void)resetPublicResults {
    @synchronized (self) {
        _numLoaded = 0;
        _numFailed = 0;
        _numUnmatched = 0;
        [_detailLines release];
        _detailLines = nil;
        [_loadedFontRelativePaths release];
        _loadedFontRelativePaths = nil;
    }
}

- (void)beginPublicLoadState {
    @synchronized (self) {
        _state = FLManagerStateLoading;
        _numLoaded = 0;
        _numFailed = 0;
        _numUnmatched = 0;
        [_detailLines release];
        _detailLines = [[NSMutableArray alloc] init];
        [_loadedFontRelativePaths release];
        _loadedFontRelativePaths = [[NSMutableArray alloc] init];
    }
}

- (void)addDetailLine:(NSString *)line loadedFontRelativePath:(NSString *)relativePath {
    @synchronized (self) {
        if (_detailLines == nil) {
            _detailLines = [[NSMutableArray alloc] init];
        }
        [_detailLines addObject:line];
        if (relativePath.length > 0) {
            if (_loadedFontRelativePaths == nil) {
                _loadedFontRelativePaths = [[NSMutableArray alloc] init];
            }
            if (![_loadedFontRelativePaths containsObject:relativePath]) {
                [_loadedFontRelativePaths addObject:relativePath];
            }
        }
    }
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
    void (^handlerCopy)(NSString *) = [handler copy];
    NSString *messageCopy = [message copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentGeneration:generation]) {
            [handlerCopy release];
            [messageCopy release];
            return;
        }
        handlerCopy(messageCopy);
        [handlerCopy release];
        [messageCopy release];
    });
}

- (void)finishWithState:(FLManagerState)state
             generation:(NSUInteger)generation
              numLoaded:(NSUInteger)numLoaded
              numFailed:(NSUInteger)numFailed
           numUnmatched:(NSUInteger)numUnmatched
                  error:(NSError *)error
             completion:(void(^)(FLManagerState, NSError *))completion {
    if (state != FLManagerStateLoaded) {
        [self appendLog:[NSString stringWithFormat:@"Error: %@", error.localizedDescription ?: @"Failed"]];
    }
    [self appendLog:@""];
    void (^completionCopy)(FLManagerState, NSError *) = [completion copy];
    NSError *errorCopy = [error retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentGeneration:generation]) {
            [completionCopy release];
            [errorCopy release];
            return;
        }
        [self setVisibleState:state
                    numLoaded:numLoaded
                    numFailed:numFailed
                 numUnmatched:numUnmatched];
        if (completionCopy != nil) {
            completionCopy(state, errorCopy);
        }
        [completionCopy release];
        [errorCopy release];
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

- (void)terminateTaskLocked {
    if (_stdinPipe != nil) {
        [self closeFileHandle:_stdinPipe.fileHandleForWriting];
    }
    if (_task != nil && _task.isRunning) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:FLHelperGracefulShutdownTimeout];
        while (_task.isRunning && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    if (_task != nil && _task.isRunning) {
        kill((pid_t)_task.processIdentifier, SIGTERM);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:FLHelperGracefulShutdownTimeout];
        while (_task.isRunning && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    if (_task != nil && _task.isRunning) {
        kill((pid_t)_task.processIdentifier, SIGKILL);
        [_task waitUntilExit];
    }
    [self clearTaskLocked];
}

- (NSString *)helperExecutablePath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/Helpers/FontLoaderSubHelper"];
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

- (NSUInteger)unsignedIntegerFromObject:(id)object {
    if ([object respondsToSelector:@selector(unsignedIntegerValue)]) {
        return [object unsignedIntegerValue];
    }
    return 0;
}

- (NSString *)detailLineForFontEvent:(NSDictionary *)event {
    NSString *status = event[@"status"];
    NSString *face = event[@"face"];
    NSString *path = event[@"path"];
    NSString *tag = @"[?]  ";

    if (![status isKindOfClass:[NSString class]]) {
        status = @"unknown";
    }
    if (![face isKindOfClass:[NSString class]]) {
        face = @"";
    }
    if (![path isKindOfClass:[NSString class]]) {
        path = nil;
    }

    if ([status isEqualToString:@"ok"]) {
        tag = @"[ok] ";
    } else if ([status isEqualToString:@"failed"]) {
        tag = @"[ X] ";
    } else if ([status isEqualToString:@"missing"]) {
        tag = @"[---] ";
    } else if ([status isEqualToString:@"system"]) {
        tag = @"[sys] ";
    } else if ([status isEqualToString:@"dup"]) {
        tag = @"[dup] ";
    }

    if (path.length > 0) {
        return [NSString stringWithFormat:@"%@%@ <- %@", tag, face, path];
    }
    return [NSString stringWithFormat:@"%@%@", tag, face];
}

- (BOOL)processJSONLine:(NSString *)line
             generation:(NSUInteger)generation
               progress:(void(^)(NSString *message))progress
              numLoaded:(NSUInteger *)numLoaded
              numFailed:(NSUInteger *)numFailed
           numUnmatched:(NSUInteger *)numUnmatched
            onReadyLine:(void(^)(void))onReadyLine {
    if (![line hasPrefix:@"{"]) {
        return NO;
    }

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return NO;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSDictionary *event = (NSDictionary *)object;
    NSString *eventName = event[@"event"];
    if (![eventName isKindOfClass:[NSString class]]) {
        return NO;
    }

    if ([eventName isEqualToString:@"ready"]) {
        if (numLoaded != NULL) {
            *numLoaded = [self unsignedIntegerFromObject:event[@"loaded"]];
        }
        if (numFailed != NULL) {
            *numFailed = [self unsignedIntegerFromObject:event[@"failed"]];
        }
        if (numUnmatched != NULL) {
            *numUnmatched = [self unsignedIntegerFromObject:event[@"missing"]];
        }
        _helperReady = YES;
        if (onReadyLine != nil) {
            onReadyLine();
        }
        return YES;
    }

    if ([eventName isEqualToString:@"log"]) {
        NSString *message = event[@"message"];
        if (![message isKindOfClass:[NSString class]]) {
            message = @"";
        }
        [self appendLog:message];
        [self publishProgress:message generation:generation handler:progress];
        return YES;
    }

    if ([eventName isEqualToString:@"font"]) {
        NSString *status = event[@"status"];
        NSString *path = event[@"path"];
        NSString *detailLine = [self detailLineForFontEvent:event];
        if (![status isKindOfClass:[NSString class]]) {
            status = @"unknown";
        }
        if (![path isKindOfClass:[NSString class]]) {
            path = nil;
        }
        NSString *loadedPath = [status isEqualToString:@"ok"] ? path : nil;

        [self appendLog:detailLine];
        [self addDetailLine:detailLine loadedFontRelativePath:loadedPath];

        if (numLoaded != NULL && [status isEqualToString:@"ok"]) {
            (*numLoaded)++;
        } else if (numFailed != NULL && [status isEqualToString:@"failed"]) {
            (*numFailed)++;
        } else if (numUnmatched != NULL && [status isEqualToString:@"missing"]) {
            (*numUnmatched)++;
        }

        [self publishProgress:detailLine generation:generation handler:progress];
        return YES;
    }

    return NO;
}

- (void)processOutputBuffer:(NSMutableData *)buffer
                 generation:(NSUInteger)generation
                   isStderr:(BOOL)isStderr
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

        if (!isStderr &&
            [self processJSONLine:line
                        generation:generation
                          progress:progress
                         numLoaded:numLoaded
                         numFailed:numFailed
                      numUnmatched:numUnmatched
                       onReadyLine:onReadyLine]) {
            continue;
        }

        if ([self parseReadyLine:line numLoaded:numLoaded numFailed:numFailed numUnmatched:numUnmatched]) {
            _helperReady = YES;
            if (onReadyLine != nil) {
                onReadyLine();
            }
            continue;
        }

        if (isStderr) {
            [self appendLog:[NSString stringWithFormat:@"[stderr] %@", line]];
        } else {
            [self appendLog:line];
        }

        if ([line hasPrefix:@"["]) {
            NSString *loadedPath = nil;
            if (numLoaded != NULL && [line hasPrefix:@"[ok]"]) {
                (*numLoaded)++;
                NSRange arrowRange = [line rangeOfString:@" <- "];
                if (arrowRange.location != NSNotFound) {
                    NSString *relativePath = [line substringFromIndex:NSMaxRange(arrowRange)];
                    loadedPath = relativePath;
                }
            } else if (numFailed != NULL && [line hasPrefix:@"[ X]"]) {
                (*numFailed)++;
            } else if (numUnmatched != NULL && [line hasPrefix:@"[---]"]) {
                (*numUnmatched)++;
            }
            [self addDetailLine:line loadedFontRelativePath:loadedPath];
        }

        [self publishProgress:line generation:generation handler:progress];
    }
}

- (void)appendData:(NSData *)data
          toBuffer:(NSMutableData *)buffer
        generation:(NSUInteger)generation
          isStderr:(BOOL)isStderr
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
                     isStderr:isStderr
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

    NSUInteger generation = [self advanceGeneration];
    [self beginPublicLoadState];

    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    [self appendLog:[NSString stringWithFormat:@"--- %@ ---", [fmt stringFromDate:[NSDate date]]]];
    for (NSString *path in subtitlePaths) {
        [self appendLog:[NSString stringWithFormat:@"Subtitle: %@", path]];
    }
    [self appendLog:[NSString stringWithFormat:@"Font dir: %@", fontDir]];

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
                if (![self isCurrentGeneration:generation] || self->_stdoutBuffer == nil) {
                    return;
                }
                [self appendData:data
                        toBuffer:self->_stdoutBuffer
                      generation:generation
                        isStderr:NO
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
                if (![self isCurrentGeneration:generation] || self->_stderrBuffer == nil) {
                    return;
                }
                [self appendData:data
                        toBuffer:self->_stderrBuffer
                      generation:generation
                        isStderr:YES
                        progress:progressCopy
                       numLoaded:NULL
                       numFailed:NULL
                    numUnmatched:NULL
                     onReadyLine:nil];
            });
        };

        _task.terminationHandler = ^(NSTask *task) {
            dispatch_async(self->_queue, ^{
                NSData *remainingOut;
                NSData *remainingErr;
                if (![self isCurrentGeneration:generation]) {
                    [subtitleCopy release];
                    [fontDirCopy release];
                    [progressCopy release];
                    [completionCopy release];
                    return;
                }
                self->_stdoutPipe.fileHandleForReading.readabilityHandler = nil;
                self->_stderrPipe.fileHandleForReading.readabilityHandler = nil;

                remainingOut = [self->_stdoutPipe.fileHandleForReading readDataToEndOfFile];
                remainingErr = [self->_stderrPipe.fileHandleForReading readDataToEndOfFile];
                [self appendData:remainingOut
                        toBuffer:self->_stdoutBuffer
                      generation:generation
                        isStderr:NO
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
                [self appendData:remainingErr
                        toBuffer:self->_stderrBuffer
                      generation:generation
                        isStderr:YES
                        progress:progressCopy
                       numLoaded:NULL
                       numFailed:NULL
                    numUnmatched:NULL
                     onReadyLine:nil];

                /* Drain: readabilityHandler blocks already dispatched to
                   _queue may contain the FLS_READY line.  Re-dispatch so
                   they execute first before we decide on failure. */
                dispatch_async(self->_queue, ^{
                    NSString *stderrText;
                    if (![self isCurrentGeneration:generation]) {
                        [subtitleCopy release];
                        [fontDirCopy release];
                        [progressCopy release];
                        [completionCopy release];
                        return;
                    }

                    /* Process any remaining data in stdout buffer (may lack
                       trailing newline). */
                    if (self->_stdoutBuffer.length > 0) {
                        [self->_stdoutBuffer appendBytes:"\n" length:1];
                        [self processOutputBuffer:self->_stdoutBuffer
                                       generation:generation
                                         isStderr:NO
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
                    }

                    if (!completionSent && !self->_helperReady) {
                        if (task.terminationStatus == 0) {
                            /* Helper exited successfully — treat as loaded
                               even if FLS_READY was not seen (e.g. no fonts
                               needed to be loaded). */
                            completionSent = YES;
                            [self finishWithState:FLManagerStateLoaded
                                       generation:generation
                                        numLoaded:numLoaded
                                        numFailed:numFailed
                                     numUnmatched:numUnmatched
                                            error:nil
                                       completion:completionCopy];
                        } else {
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
                    }
                    [self clearTaskLocked];
                    [subtitleCopy release];
                    [fontDirCopy release];
                    [progressCopy release];
                    [completionCopy release];
                });
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

- (void)resetStateLocked {
    [self resetPublicResults];
}

- (void)unloadFonts {
    [self advanceGeneration];
    dispatch_sync(_queue, ^{
        [self terminateTaskLocked];
        [self resetStateLocked];
    });
    [self setVisibleState:FLManagerStateIdle numLoaded:0 numFailed:0 numUnmatched:0];
}

- (void)cancel {
    [self advanceGeneration];
    dispatch_sync(_queue, ^{
        [self terminateTaskLocked];
        [self resetStateLocked];
    });
    [self setVisibleState:FLManagerStateIdle numLoaded:0 numFailed:0 numUnmatched:0];
}

@end
