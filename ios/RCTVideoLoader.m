//
//  HudlHlsAvPlayerCache.m
//  Hudl
//
//  Created by Brian Clymer on 3/6/15.
//  Copyright (c) 2015 Agile Sports Technologies, Inc. All rights reserved.
//

#import "RCTVideoLoader.h"

@interface RCTVideoLoader ()

@property (nonatomic, strong) NSMapTable *pendingRequests; // Dictionary of NSURLConnections to RCTAssetResponses
@property (nonatomic, strong) NSMutableSet *cachedFragments; // Set of NSStrings (file paths)
@property (nonatomic, strong) NSMutableArray *memoryCache;
@property (nonatomic, copy) NSString *cachePath;

@end

@implementation RCTVideoLoader

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
        _sharedInstance.pendingRequests = [NSMapTable new];
        _sharedInstance.memoryCache = [NSMutableArray new];
    });
    return _sharedInstance;
}

- (NSString *)localStringFromRemoteString:(NSString *)string
{
    NSCharacterSet* invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>"];
    return [[string componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"------"];
}

#pragma mark - NSURLConnection delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    RCTAssetResponse *assetResponse = [self.pendingRequests objectForKey:connection.originalRequest];
    assetResponse.response = response;
    assetResponse.loadingRequest.response = response;
    [self fillInContentInformation:assetResponse.loadingRequest.contentInformationRequest response:assetResponse.response];
    [self processPendingRequestsForResponse:assetResponse request:connection.originalRequest];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    RCTAssetResponse *assetResponse = [self.pendingRequests objectForKey:connection.originalRequest];
    [assetResponse.data appendData:data];
    [self processPendingRequestsForResponse:assetResponse request:connection.originalRequest];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSData *)data
{
    NSLog(@"RCTVideoLoader: Request failed");
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    RCTAssetResponse *assetResponse = [self.pendingRequests objectForKey:connection.originalRequest];
    assetResponse.finished = YES;
    [self processPendingRequestsForResponse:assetResponse request:connection.originalRequest];

    NSString *url = assetResponse.loadingRequest.request.URL.absoluteString;
    NSString *localName = [self localStringFromRemoteString:url];
    NSString *cachedFilePath = [self.cachePath stringByAppendingPathComponent:localName];
    // Write to disk cache
    [self.cachedFragments addObject:localName];
    [assetResponse.data writeToFile:cachedFilePath atomically:YES];
    // Add to memory cache
    [self addToMemoryCache:assetResponse.data url:url];
}

- (void)addToMemoryCache:(NSData *)data url:(NSString *)url
{
    if([self.memoryCache count] > 4) {
        [self.memoryCache removeObjectAtIndex: 0];
    }
    [self.memoryCache addObject:@{@"data": data, @"url": url}];
}

#pragma mark - AVURLAsset resource loading

- (void)processPendingRequestsForResponse:(RCTAssetResponse *)assetResponse request:(NSURLRequest *)request
{
    BOOL didRespondCompletely = [self respondWithDataForRequest:assetResponse];

    if (didRespondCompletely)
    {
        // NSLog(@"Completed %@", request.URL.absoluteString);
        [assetResponse.loadingRequest finishLoading];
        [self.pendingRequests removeObjectForKey:request];
    }
}

- (void)fillInContentInformation:(AVAssetResourceLoadingContentInformationRequest *)contentInformationRequest response:(NSURLResponse *)response
{
    if (contentInformationRequest == nil || response == nil)
    {
        return;
    }

    contentInformationRequest.byteRangeAccessSupported = NO;
    contentInformationRequest.contentType = [response MIMEType];
    contentInformationRequest.contentLength = [response expectedContentLength];
}

- (BOOL)respondWithDataForRequest:(RCTAssetResponse *)assetResponse
{
    AVAssetResourceLoadingDataRequest *dataRequest = assetResponse.loadingRequest.dataRequest;
    long long startOffset = dataRequest.requestedOffset;
    if (dataRequest.currentOffset != 0)
    {
        startOffset = dataRequest.currentOffset;
    }

    // Don't have any data at all for this request
    if (assetResponse.data.length < startOffset)
    {
        return NO;
    }
    if (!assetResponse.finished)
    {
        return NO;
    }

    // This is the total data we have from startOffset to whatever has been downloaded so far
    NSUInteger unreadBytes = assetResponse.data.length - (NSUInteger)startOffset;

    // Respond with whatever is available if we can't satisfy the request fully yet
    NSUInteger numberOfBytesToRespondWith = MIN((NSUInteger)dataRequest.requestedLength, unreadBytes);

    [dataRequest respondWithData:[assetResponse.data subdataWithRange:NSMakeRange((NSUInteger)startOffset, numberOfBytesToRespondWith)]];

    long long endOffset = startOffset + dataRequest.requestedLength;
    BOOL didRespondFully = assetResponse.data.length >= endOffset;

    return didRespondFully || assetResponse.finished;
}


- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{
    // NSLog(@"shouldWaitForLoadingOfRequestedResource %@ %d %d", loadingRequest.request.URL.absoluteString, loadingRequest.dataRequest.requestedOffset, loadingRequest.dataRequest.requestedLength);
    // start downloading the fragment.
    NSURL *interceptedURL = loadingRequest.request.URL;

    NSURLComponents *actualURLComponents = [[NSURLComponents alloc] initWithURL:interceptedURL resolvingAgainstBaseURL:NO];
    actualURLComponents.scheme = [actualURLComponents.scheme stringByReplacingOccurrencesOfString:@"custom-" withString:@""];
    NSString *absoluteURL = actualURLComponents.URL.absoluteString;

    NSString *localFile = [self localStringFromRemoteString:absoluteURL];

    for(NSDictionary *dict in self.memoryCache) {
        if([[dict objectForKey:@"url"] isEqualToString:interceptedURL.absoluteString]) {
            NSData *data = [dict objectForKey:@"data"];
            loadingRequest.contentInformationRequest.contentLength = data.length;
            loadingRequest.contentInformationRequest.contentType = @"video/mpegts";
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
            [loadingRequest.dataRequest respondWithData:[data subdataWithRange:NSMakeRange(loadingRequest.dataRequest.requestedOffset, MIN(loadingRequest.dataRequest.requestedLength, data.length))]];
            [loadingRequest finishLoading];
            // NSLog(@"Responded with memory cached data for %@", interceptedURL.absoluteString);
            return YES;
        }
    }
    
    if ([self.cachedFragments containsObject:localFile] && ![localFile hasSuffix:@".ts"])
    {
        NSData *fileData = [[NSFileManager defaultManager] contentsAtPath:[self.cachePath stringByAppendingPathComponent:localFile]];
        loadingRequest.contentInformationRequest.contentLength = fileData.length;
        loadingRequest.contentInformationRequest.contentType = @"video/mpegts";
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
        [loadingRequest.dataRequest respondWithData:[fileData subdataWithRange:NSMakeRange(loadingRequest.dataRequest.requestedOffset, MIN(loadingRequest.dataRequest.requestedLength, fileData.length))]];
        [loadingRequest finishLoading];
        [self addToMemoryCache:fileData url: interceptedURL.absoluteString];

        // NSLog(@"Responded with cached data for %@", interceptedURL.absoluteString);
        return YES;
    }

    // This is a memory leak
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:absoluteURL]];
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [connection setDelegateQueue:[NSOperationQueue mainQueue]];
    [connection start];

    RCTAssetResponse *assetResponse = [RCTAssetResponse new];
    assetResponse.data = [NSMutableData new];
    assetResponse.loadingRequest = loadingRequest;

    [self.pendingRequests setObject:assetResponse forKey:request];

    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest
{
    // NSLog(@"shouldWaitForRenewalOfRequestedResource %@", renewalRequest.request.URL.absoluteString);
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
    // NSLog(@"Resource request cancelled for %@", loadingRequest.request.URL.absoluteString);
    NSURLConnection *connectionForRequest = nil;
    NSEnumerator *enumerator = self.pendingRequests.keyEnumerator;
    BOOL found = NO;
    while ((connectionForRequest = [enumerator nextObject]) && !found)
    {
        RCTAssetResponse *assetResponse = [self.pendingRequests objectForKey:connectionForRequest];
        if (assetResponse.loadingRequest == loadingRequest)
        {
            [connectionForRequest cancel];
            found = YES;
        }
    }
    if (found)
    {
        [self.pendingRequests removeObjectForKey:connectionForRequest];
    }
}

@end

@implementation RCTAssetResponse

@end
