#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, FLManagerState) {
    FLManagerStateIdle,
    FLManagerStateLoading,
    FLManagerStateLoaded,
    FLManagerStateFailed,
};

@interface FLManager : NSObject
@property (readonly) FLManagerState state;
@property (readonly) NSUInteger numLoaded;
@property (readonly) NSUInteger numFailed;
@property (readonly) NSUInteger numUnmatched;

- (void)loadFontsForSubtitles:(NSArray<NSString *> *)subtitlePaths
                      fontDir:(NSString *)fontDir
                     progress:(void(^)(NSString *message))progress
                   completion:(void(^)(FLManagerState state, NSError *error))completion;
- (void)unloadFonts;
- (void)cancel;
@end
