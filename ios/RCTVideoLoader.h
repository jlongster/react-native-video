#import <AVFoundation/AVFoundation.h>

@class RCTVideoLoader;
@interface RCTVideoLoader : NSObject<AVAssetResourceLoaderDelegate, NSURLConnectionDataDelegate>
+ (instancetype)sharedInstance;
@end

@interface RCTAssetResponse : NSObject
@property (readwrite) NSMutableData *data;
@property (readwrite) AVAssetResourceLoadingRequest *loadingRequest;
@property (readwrite) NSURLResponse* response;
@property (readwrite) BOOL finished;
@end
