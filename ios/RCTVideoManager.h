#import <React/RCTViewManager.h>

@interface RCTVideoManager : RCTViewManager

@property (class, nonatomic, assign, readonly) NSMutableDictionary* playerCache;

+ (void)preloadSrc:(NSDictionary *)source;

@end
