#import <AVFoundation/AVFoundation.h>

@class RCTEventDispatcher;
@class RCTVideoLoader;

@interface RCTVideoLoader : NSObject<AVAssetResourceLoaderDelegate, NSURLConnectionDataDelegate>
+ (instancetype)sharedInstance;
- (void)setEventDispatcher:(RCTEventDispatcher *)eventDispatcher;
@end

@interface RCTAssetResponse : NSObject
@property (readwrite) NSMutableData *data;
@property (readwrite) AVAssetResourceLoadingRequest *loadingRequest;
@property (readwrite) NSURLResponse* response;
@property (readwrite) BOOL finished;
@end
