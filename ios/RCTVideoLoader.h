#import <AVFoundation/AVFoundation.h>

@class RCTEventDispatcher;
@class RCTVideoLoader;

@interface RCTVideoLoader : NSObject<AVAssetResourceLoaderDelegate, NSURLConnectionDataDelegate>
+ (instancetype)sharedInstance;
- (void)setEventDispatcher:(RCTEventDispatcher *)eventDispatcher;
- (void)prefetch:(NSURL *)url;
@end

/* @interface RCTCachedResponse : NSObject */
/* @property (readwrite) NSData* data; */
/* @property (readwrite) NSURLResponse* response; */
/* @end */

@interface RCTCachedAsset : NSObject
@property (readwrite) NSMutableData* data;
@property (readwrite) NSString* contentType;
@property (readwrite) long long contentLength;
@end
