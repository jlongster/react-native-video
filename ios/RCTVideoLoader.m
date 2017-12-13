//
//  HudlHlsAvPlayerCache.m
//  Hudl
//
//  Created by Brian Clymer on 3/6/15.
//  Copyright (c) 2015 Agile Sports Technologies, Inc. All rights reserved.
//

#import "RCTVideoLoader.h"
#import <React/RCTEventDispatcher.h>

@interface RCTVideoLoader ()

@property (nonatomic, strong) NSMutableDictionary *blockedLoadingRequests;
@property (nonatomic, strong) NSMutableDictionary *memoryCache;
@property (nonatomic, copy) NSString *cachePath;
@property (nonatomic, strong) NSMutableSet *cachedFragments; // Set of NSStrings (file paths)

@end

@implementation RCTVideoLoader
{
  RCTEventDispatcher *_eventDispatcher;
}

+ (instancetype)sharedInstance
{
    static RCTVideoLoader *_sharedInstance = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _sharedInstance = [RCTVideoLoader new];
        _sharedInstance.cachePath = ^NSString*() {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            NSString *basePath = [paths objectAtIndex:0];

            NSString *iden = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"];
            basePath = [basePath stringByAppendingPathComponent:iden];
            basePath = [basePath stringByAppendingPathComponent:@"hlsFragmentCache"];

            if (![[NSFileManager defaultManager] fileExistsAtPath:basePath])
            {
                [[NSFileManager defaultManager] createDirectoryAtPath:basePath withIntermediateDirectories:YES attributes:nil error:NULL];
            }
            return basePath;
        }();
        _sharedInstance.cachedFragments = [NSMutableSet setWithArray:[[NSFileManager defaultManager] contentsOfDirectoryAtPath:_sharedInstance.cachePath error:nil]];
        _sharedInstance.memoryCache = [NSMutableDictionary new];
        _sharedInstance.blockedLoadingRequests = [NSMutableDictionary new];
    });
    return _sharedInstance;
}

- (void)setEventDispatcher:(RCTEventDispatcher *)eventDispatcher {
    self->_eventDispatcher = eventDispatcher;
}

// NSURLConnection delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    NSString *url = [[connection currentRequest] URL].absoluteString;
    RCTCachedAsset *cachedAsset = self.memoryCache[url];
    cachedAsset.contentType = [response MIMEType];
    cachedAsset.contentLength = [response expectedContentLength];

    NSMutableArray *blockedRequests = self.blockedLoadingRequests[url];
    NSMutableArray *finishedRequests = [NSMutableArray new]; 
    [blockedRequests enumerateObjectsUsingBlock:^(AVAssetResourceLoadingRequest* loadingRequest, NSUInteger idx, BOOL *stop) {
        if(loadingRequest.contentInformationRequest != nil) {
           loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
           loadingRequest.contentInformationRequest.contentType = cachedAsset.contentType;
           loadingRequest.contentInformationRequest.contentLength = cachedAsset.contentLength;
           [loadingRequest finishLoading];
           [finishedRequests addObject:loadingRequest];
        }
    }];
    [blockedRequests removeObjectsInArray:finishedRequests];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    NSString *url = [[connection currentRequest] URL].absoluteString;
    RCTCachedAsset *cachedAsset = self.memoryCache[url];

    [cachedAsset.data appendData:data];
    
    NSMutableArray *blockedRequests = self.blockedLoadingRequests[url];
    NSMutableArray *finishedRequests = [NSMutableArray new];
    [blockedRequests enumerateObjectsUsingBlock:^(AVAssetResourceLoadingRequest* loadingRequest, NSUInteger idx, BOOL *stop) {
        if(loadingRequest.contentInformationRequest == nil) {
            if([self sendAvailableBytes:loadingRequest cachedAsset:cachedAsset]) {
                [finishedRequests addObject:loadingRequest];
            }
        }
    }];

    [blockedRequests removeObjectsInArray:finishedRequests];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    NSString *url = [[connection currentRequest] URL].absoluteString;
    self.memoryCache[url] = nil;

    NSMutableArray *blockedRequests = self.blockedLoadingRequests[url];
    [blockedRequests enumerateObjectsUsingBlock:^(AVAssetResourceLoadingRequest* loadingRequest, NSUInteger idx, BOOL *stop) {
        [loadingRequest finishLoadingWithError:error];
    }];
    [blockedRequests removeAllObjects];

}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    NSString *url = [[connection currentRequest] URL].absoluteString;
    // Nothing to do yet
}

- (BOOL)sendAvailableBytes:(AVAssetResourceLoadingRequest *)loadingRequest cachedAsset:(RCTCachedAsset *)cachedAsset {
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if(dataRequest.currentOffset < cachedAsset.data.length - 1) {
        long long totalLength = dataRequest.requestedOffset + dataRequest.requestedLength;
        long long neededBytes = totalLength - dataRequest.currentOffset;
        long long availableBytes = cachedAsset.data.length - dataRequest.currentOffset;

        [dataRequest respondWithData:
          [cachedAsset.data subdataWithRange: NSMakeRange(dataRequest.currentOffset, MIN(neededBytes, availableBytes))]
        ];

        if(neededBytes <= availableBytes) {
            [loadingRequest finishLoading];
            return YES;
        }
    }

    return NO;
}

// Fetching

- (void)fetch:(NSString *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:60];
    // NSString *bytesString = [NSString stringWithFormat:@"bytes=%lli-%lli",lowerBound,upperBound];
    // [request addValue:bytesString forHTTPHeaderField:@"Range"];

    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [connection setDelegateQueue:[NSOperationQueue mainQueue]];
    [connection start];
   
    RCTCachedAsset *cachedAsset = [RCTCachedAsset new];
    cachedAsset.data = [NSMutableData new];
    cachedAsset.contentType = nil;
    cachedAsset.contentLength = 0;
    self.memoryCache[url] = cachedAsset;
}

// AVURLAsset resource loading

- (NSString *)getRequestURL:(AVAssetResourceLoadingRequest *)loadingRequest {
    return [self removeCustomPrefix:loadingRequest.request.URL].absoluteString;
}

- (NSURL*)removeCustomPrefix:(NSURL*)url {
  NSURLComponents *comps = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
  comps.scheme = [comps.scheme stringByReplacingOccurrencesOfString:@"custom-" withString:@""];
  return comps.URL;
}

- (void)addBlockedLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSString *url = [self getRequestURL:loadingRequest];
    if(self.blockedLoadingRequests[url] == nil) {
        self.blockedLoadingRequests[url] = [NSMutableArray new];
    }

    NSMutableArray *arr = self.blockedLoadingRequests[url];
    
    [arr addObject:loadingRequest];
}

- (BOOL)handleRequestFromMemory:(AVAssetResourceLoadingRequest *)loadingRequest {
    RCTCachedAsset *cachedAsset = self.memoryCache[[self getRequestURL:loadingRequest]];
    if(cachedAsset == nil) {
        return NO;
    }

    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    long long offset = dataRequest.requestedOffset;
    long long length = dataRequest.requestedLength;

    // Respond immediately to either a content information request or
    // data request, or block until the existing network fetches have
    // the data we need.
    if(loadingRequest.contentInformationRequest != nil && cachedAsset.contentType != nil) {
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
        loadingRequest.contentInformationRequest.contentType = cachedAsset.contentType;
        loadingRequest.contentInformationRequest.contentLength = cachedAsset.contentLength;
        [loadingRequest finishLoading];
    }
    else if(![self sendAvailableBytes:loadingRequest cachedAsset:cachedAsset]) {
        [self addBlockedLoadingRequest:loadingRequest];
    }
    
    return YES;
}

- (BOOL)handleRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    if(loadingRequest.request.URL == nil) {
        return NO;
    }

    // Check the in-memory cache first
    if([self handleRequestFromMemory:loadingRequest]) {
        return YES;
    }

    [self fetch:[self getRequestURL:loadingRequest]];
    [self addBlockedLoadingRequest:loadingRequest];

    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{
    NSURL *interceptedURL = loadingRequest.request.URL;

    // Use the following code to log messages in the frontend to debug
    // issues. Copy this around to wherever you need to log and change
    // the params.
    //
    // [_eventDispatcher sendAppEventWithName:@"video-log" body:@{
    //            @"msg": [NSString stringWithFormat:@"AVAsset request, offset: %lli length: %lli",
    //                              loadingRequest.dataRequest.requestedOffset,
    //                              loadingRequest.dataRequest.requestedLength],
    //       @"url": [self getRequestURL:loadingRequest]
    //     }];

    if(loadingRequest.contentInformationRequest != nil || loadingRequest.dataRequest != nil) {
        return [self handleRequest:loadingRequest];
    }
    return NO;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest
{
    [NSException raise:@"NotImplemented" format:@"Videos asset handler does not support authenticated resources"];
    return NO;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
    NSString *url = [self getRequestURL:loadingRequest];
    NSMutableArray *blockedRequests = self.blockedLoadingRequests[url];
    [blockedRequests removeObject:loadingRequest];
}

@end

@implementation RCTCachedAsset
@end
