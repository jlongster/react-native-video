#import <React/RCTConvert.h>
#import "RCTVideo.h"
#import "RCTVideoLoader.h"
#import <React/RCTBridgeModule.h>
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath = @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const playbackBufferFullKeyPath = @"playbackBufferFull";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";
static NSString *const timedMetadata = @"timedMetadata";

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserversSet;
  BOOL _playerBufferEmpty;
  BOOL _loaded;
  AVPlayerLayer *_playerLayer;
  AVPlayerViewController *_playerViewController;
  NSURL *_videoURL;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;
  BOOL _playbackRateObserverRegistered;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
  BOOL _controls;
  id _timeObserver;

  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _repeat;
  BOOL _playbackStalled;
  BOOL _playInBackground;
  BOOL _playWhenInactive;
  NSString * _ignoreSilentSwitch;
  BOOL _fullscreenPlayerPresented;
  UIViewController * _presentingViewController;

  NSMutableDictionary *_playerItemCache;
}

- (NSMutableDictionary*)playerItemCache {
    if(_playerItemCache == nil) {
        _playerItemCache = [NSMutableDictionary dictionary];
    }
    return _playerItemCache;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    _playbackRateObserverRegistered = NO;
    _playbackStalled = NO;
    _rate = 1.0;
    _volume = 1.0;
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _progressUpdateInterval = 250;
    _controls = NO;
    _playerBufferEmpty = YES;
    _playInBackground = false;
    _playWhenInactive = false;
    _ignoreSilentSwitch = @"inherit";

    [[RCTVideoLoader sharedInstance] setEventDispatcher:eventDispatcher];
 
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
  }

  return self;
}

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
    RCTVideoPlayerViewController* playerLayer= [[RCTVideoPlayerViewController alloc] init];
    playerLayer.showsPlaybackControls = NO;
    playerLayer.rctDelegate = self;
    playerLayer.view.frame = self.bounds;
    playerLayer.player = _player;
    playerLayer.view.frame = self.bounds;
    return playerLayer;
}

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return([playerItem duration]);
    }

    return(kCMTimeInvalid);
}

- (CMTimeRange)playerItemSeekableTimeRange
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return [playerItem seekableTimeRanges].firstObject.CMTimeRangeValue;
    }
    
    return (kCMTimeRangeZero);
}


/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
    if (_timeObserver)
    {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark - Progress

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self removePlayerItemObservers];
  [self removePlayerLayer];
  [_player removeObserver:self forKeyPath:playbackRate context:nil];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  [self applyModifiers];
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
   AVPlayerItem *video = [_player currentItem];
   if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
     return;
   }

   CMTime playerDuration = [self playerItemDuration];
   if (CMTIME_IS_INVALID(playerDuration)) {
      return;
   }

   CMTime currentTime = _player.currentTime;
   const Float64 duration = CMTimeGetSeconds(playerDuration);
   const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);
   if( currentTimeSecs >= 0 && self.onVideoProgress) {
      self.onVideoProgress(@{
                             @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)_playerItem.asset).URL].absoluteString,
                             @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                             @"duration": [NSNumber numberWithFloat:duration],
                             @"playableDuration": [self calculatePlayableDuration],
                             @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                             @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                             @"target": self.reactTag
                            });
   }
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration
{
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block CMTimeRange effectiveTimeRange;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
        effectiveTimeRange = timeRange;
        *stop = YES;
      }
    }];
    Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
    if (playableDuration > 0) {
      return [NSNumber numberWithFloat:playableDuration];
    }
  }
  return [NSNumber numberWithInteger:0];
}

- (void)addPlayerItemObservers
{
  [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackBufferEmptyKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackBufferFullKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:timedMetadata options:NSKeyValueObservingOptionNew context:nil];
  [_playerItem addObserver:self
               forKeyPath:@"loadedTimeRanges"
               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
               context:nil];
  _playerItemObserversSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObservers
{
  if (_playerItemObserversSet) {
    [_playerItem removeObserver:self forKeyPath:statusKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackBufferEmptyKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackBufferFullKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath];
    [_playerItem removeObserver:self forKeyPath:timedMetadata];
    [_playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    _playerItemObserversSet = NO;
  }
}

- (void)applyAudioCategory {
    if([_ignoreSilentSwitch isEqualToString:@"ignore"]) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    } else if([_ignoreSilentSwitch isEqualToString:@"obey"]) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    }
}

- (void)applyModifiers
{
    if (_muted) {
        [_player setVolume:0];
        [_player setMuted:YES];
    } else {
        [_player setVolume:_volume];
        [_player setMuted:NO];
    }

 if (_paused) {
    [_player pause];
  } else {
    [self applyAudioCategory];
    [_player play];
  }    
}

#pragma mark - Player and source

+ (AVPlayerItem *)makePlayerItem:(NSString *)uri dispatcher:(RCTEventDispatcher*)dispatcher {
    NSURL *url = [NSURL URLWithString:uri];
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.scheme isEqualToString:@"file"]) {
        // For our delegate to be called, we need to specify a custom protocol
        components.scheme = [@"custom-" stringByAppendingString:components.scheme];
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:components.URL options:nil];
    [asset.resourceLoader setDelegate:[RCTVideoLoader sharedInstance] queue:dispatch_get_main_queue()];

    // Start loading the resource immediately
    [dispatcher sendAppEventWithName:@"preloadStatus" body:@{@"status": @"start", @"uri": uri}];
    [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^() {
      [dispatcher sendAppEventWithName:@"preloadStatus" body:@{@"status": @"finish", @"uri": uri}];
    }];

    return [AVPlayerItem playerItemWithAsset:asset];
}

- (void)setPreload:(NSString *)url {
    if(![self.playerItemCache objectForKey:url]) {
        AVPlayerItem *item = [RCTVideo makePlayerItem:url dispatcher:_eventDispatcher];
        [self.playerItemCache setObject:item forKey:url];
    }
}

- (void)setSrc:(NSDictionary *)source {    
    NSString *uri = [source objectForKey:@"uri"];
    
    // Don't render any video
    if([uri length] == 0) {
        AVPlayerItem *prevItem = _player.currentItem;
        [_player replaceCurrentItemWithPlayerItem:nil];
        [self _setPlayerItem:nil];
        [prevItem seekToTime:kCMTimeZero];
        [self removePlayerTimeObserver];
        [self _disappear];
        return;
    }

    _loaded = NO;
    AVPlayerItem *cachedItem = [self.playerItemCache objectForKey:uri];
    AVPlayerItem *item;

    if(cachedItem) {
        item = cachedItem;
        [self _setPlayerItem:item];
    }
    else {
        item = [RCTVideo makePlayerItem:uri dispatcher:_eventDispatcher];
        [self _setPlayerItem:item];
        [self.playerItemCache setObject:item forKey:uri];
    }

    if(![self usePlayerLayer:item]) {
        AVPlayerItem *prevItem = _player.currentItem;
        [_player replaceCurrentItemWithPlayerItem:item];
        [prevItem seekToTime:kCMTimeZero];
    }

    [self addPlayerTimeObservers];

    dispatch_async(dispatch_get_main_queue(), ^{
      // Perform on next run loop, otherwise onVideoLoadStart is nil
      if(self.onVideoLoadStart) {
        id uri = [source objectForKey:@"uri"];
        id type = [source objectForKey:@"type"];
        self.onVideoLoadStart(@{@"src": @{
                                          @"uri": uri ? uri : [NSNull null],
                                          @"type": type ? type : [NSNull null],
                                          @"isNetwork": [NSNumber numberWithBool:(bool)[source objectForKey:@"isNetwork"]]},
                                          @"target": self.reactTag
                                          });
      }
    });

    if (item.playbackLikelyToKeepUp) {
        // The onLoad property may not be set yet, as we are in
        // the `source` setter here. Wait for one tick to dispatch
        // the load event.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self emitLoadEvent];
        });
    }
    else {
        [self _disappear];
    }
}

- (void)_setPlayerItem:(AVPlayerItem *)item
{
    [self removePlayerItemObservers];
    _playerItem = item;

    if(item != nil) {
        [self addPlayerItemObservers];
    }
}

- (void)addPlayerTimeObservers
{
  if(_timeObserver == nil) {
      const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
      // @see endScrubbing in AVPlayerDemoPlaybackViewController.m of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
      __weak RCTVideo *weakSelf = self;
      _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC)
                                                            queue:NULL
                                                       usingBlock:^(CMTime time) { [weakSelf sendProgressUpdate]; }
                       ];
  }
}

- (AVPlayer *)_makePlayerWithItem:(AVPlayerItem *)item
{
  AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
  player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  return player;
}

- (void)_disappear {
  [CATransaction begin];
  [CATransaction setAnimationDuration:0];
  _playerLayer.hidden = YES;
  [CATransaction commit];
}

- (void)_appear {
  [CATransaction begin];
  [CATransaction setAnimationDuration:0];
  _playerLayer.hidden = NO;
  [CATransaction commit];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
   if (object == _playerItem) {

    // When timeMetadata is read the event onTimedMetadata is triggered
    if ([keyPath isEqualToString: timedMetadata])
    {
        NSArray<AVMetadataItem *> *items = [change objectForKey:@"new"];
        if (items && ![items isEqual:[NSNull null]] && items.count > 0) {
            
            NSMutableArray *array = [NSMutableArray new];
            for (AVMetadataItem *item in items) {
                
                NSString *value = item.value;
                NSString *identifier = item.identifier;
                
                if (![value isEqual: [NSNull null]]) {
                    NSDictionary *dictionary = [[NSDictionary alloc] initWithObjects:@[value, identifier] forKeys:@[@"value", @"identifier"]];
                    
                    [array addObject:dictionary];
                }
            }
            
            self.onTimedMetadata(@{
                                   @"target": self.reactTag,
                                   @"metadata": array
                                   });
        }
    }

    if ([keyPath isEqualToString:statusKeyPath]) {
        if(_playerItem.status == AVPlayerItemStatusFailed && self.onVideoError) {
            self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: _playerItem.error.code],
                            @"domain": _playerItem.error.domain},
                        @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)_playerItem.asset).URL].absoluteString,
                        @"target": self.reactTag});
        }
    } else if ([keyPath isEqualToString:playbackBufferEmptyKeyPath]) {
      _playerBufferEmpty = YES;
      self.onVideoBuffer(@{@"isBuffering": @(YES), @"target": self.reactTag});
    } else if ([keyPath isEqualToString:playbackBufferFullKeyPath]) {
      self.onVideoBuffer(@{@"isBuffering": @(NO), @"target": self.reactTag});
      _playerBufferEmpty = NO;
    } else if([keyPath isEqualToString:@"loadedTimeRanges"]) {
        // for(id obj in _playerItem.loadedTimeRanges) {
        //     CMTimeRange range = [obj CMTimeRangeValue];
        //     double startTime = CMTimeGetSeconds(range.start);
        //     double loadedDuration = CMTimeGetSeconds(range.duration);
        //     NSLog(@"startTime: %f loadedDuration: %f", startTime, loadedDuration);
        // }
     } else if ([keyPath isEqualToString:playbackLikelyToKeepUpKeyPath]) {
        // NSLog(@"Keep up: %d Buffer full: %d", _playerItem.playbackLikelyToKeepUp, _playerItem.playbackBufferFull);
        if(_playerItem.playbackLikelyToKeepUp) {
            // NSLog(@"JWL Loaded (playbackLikelyToKeepUp)");
            [self emitLoadEvent];

            _playerBufferEmpty = NO;
            self.onVideoBuffer(@{@"isBuffering": @(NO), @"target": self.reactTag});
        }
    }
   } else if (object == _playerLayer) {
      if([keyPath isEqualToString:readyForDisplayKeyPath] && [change objectForKey:NSKeyValueChangeNewKey]) {
        if([change objectForKey:NSKeyValueChangeNewKey] && self.onReadyForDisplay) {
            self.onReadyForDisplay(@{@"target": self.reactTag});
        }
    }
  } else if (object == _player) {
      if([keyPath isEqualToString:playbackRate]) {
          if(self.onPlaybackRateChange) {
              self.onPlaybackRateChange(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                          @"target": self.reactTag});
          }
          if(_playbackStalled && _player.rate > 0) {
              if(self.onPlaybackResume) {
                  self.onPlaybackResume(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                          @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)_playerItem.asset).URL].absoluteString,
                                          @"target": self.reactTag});
              }
              _playbackStalled = NO;
          }
      }
  } else {
      [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)emitLoadEvent
{
    if(_loaded) {
        return;
    }
    _loaded = YES;
    float duration = CMTimeGetSeconds(_playerItem.asset.duration);

    if (isnan(duration)) {
        duration = 0.0;
    }

    NSObject *width = @"undefined";
    NSObject *height = @"undefined";
    NSString *orientation = @"undefined";

    if(self.onVideoLoad) {
        self.onVideoLoad(@{@"duration": [NSNumber numberWithFloat:duration],
                    @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
                    @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
                    @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
                    @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
                    @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
                    @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
                    @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
                    @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)_playerItem.asset).URL].absoluteString,
                    @"naturalSize": @{
                    @"width": width,
                        @"height": height,
                        @"orientation": orientation
                        },
                    @"target": self.reactTag});
    }

    [self attachListeners];
    [self applyModifiers];
    [self _appear];
}

- (void)attachListeners
{
  // Remove any existing observers
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                               name:AVPlayerItemPlaybackStalledNotification
                                             object:[_player currentItem]];

  // listen for end of file
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playbackStalled:)
                                               name:AVPlayerItemPlaybackStalledNotification
                                             object:nil];
}

- (void)playbackStalled:(NSNotification *)notification
{
  AVPlayerItem *item = [notification object];

  if(self.onPlaybackStalled) {
    self.onPlaybackStalled(@{
            @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)item.asset).URL].absoluteString,
            @"target": self.reactTag});
  }

  _playbackStalled = YES;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
  AVPlayerItem *item = [notification object];

  if(self.onVideoEnd) {
      self.onVideoEnd(@{
              @"url": [[RCTVideoLoader sharedInstance] removeCustomPrefix:((AVURLAsset*)item.asset).URL].absoluteString,
              @"target": self.reactTag});
  }

  if (_repeat) {
    [item seekToTime:kCMTimeZero];
  }
}

#pragma mark - Prop setters

- (void)setPlayInBackground:(BOOL)playInBackground
{
  _playInBackground = playInBackground;
}

- (void)setPlayWhenInactive:(BOOL)playWhenInactive
{
  _playWhenInactive = playWhenInactive;
}

- (void)setIgnoreSilentSwitch:(NSString *)ignoreSilentSwitch
{
  _ignoreSilentSwitch = ignoreSilentSwitch;
  [self applyModifiers];
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [_player pause];
  } else {
    [self applyAudioCategory];
    [_player play];
  }

  _paused = paused;
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;
}

- (void)setRestart:(BOOL)flag {
    [_player seekToTime:CMTimeMakeWithSeconds(0, 10000)];
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    [self applyModifiers];
}

- (void)setVolume:(float)volume
{
  _volume = volume;
  [self applyModifiers];
}

- (BOOL)getFullscreen
{
    return _fullscreenPlayerPresented;
}

- (void)setFullscreen:(BOOL)fullscreen
{
    if( fullscreen && !_fullscreenPlayerPresented )
    {
        // Ensure player view controller is not null
        if( !_playerViewController )
        {
            [self usePlayerViewController];
        }
        // Set presentation style to fullscreen
        [_playerViewController setModalPresentationStyle:UIModalPresentationFullScreen];

        // Find the nearest view controller
        UIViewController *viewController = [self firstAvailableUIViewController];
        if( !viewController )
        {
            UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
            viewController = keyWindow.rootViewController;
            if( viewController.childViewControllers.count > 0 )
            {
                viewController = viewController.childViewControllers.lastObject;
            }
        }
        if( viewController )
        {
            _presentingViewController = viewController;
            if(self.onVideoFullscreenPlayerWillPresent) {
                self.onVideoFullscreenPlayerWillPresent(@{@"target": self.reactTag});
            }
            [viewController presentViewController:_playerViewController animated:true completion:^{
                _playerViewController.showsPlaybackControls = YES;
                _fullscreenPlayerPresented = fullscreen;
                if(self.onVideoFullscreenPlayerDidPresent) {
                    self.onVideoFullscreenPlayerDidPresent(@{@"target": self.reactTag});
                }
            }];
        }
    }
    else if ( !fullscreen && _fullscreenPlayerPresented )
    {
        [self videoPlayerViewControllerWillDismiss:_playerViewController];
        [_presentingViewController dismissViewControllerAnimated:true completion:^{
            [self videoPlayerViewControllerDidDismiss:_playerViewController];
        }];
    }
}

- (void)usePlayerViewController
{
    if( _player )
    {
        _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
        // to prevent video from being animated when resizeMode is 'cover'
        // resize mode must be set before subview is added
        [self addSubview:_playerViewController.view];
    }
}

- (BOOL)usePlayerLayer:(AVPlayerItem *)initialItem
{
    if(_player == nil && _playerLayer == nil)
    {
      _player = [self _makePlayerWithItem:initialItem];
      _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
      _playerLayer.frame = self.bounds;
      _playerLayer.needsDisplayOnBoundsChange = YES;
      _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

      [_playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];

      [self.layer addSublayer:_playerLayer];
      self.layer.needsDisplayOnBoundsChange = YES;

      [self _disappear];
      return true;
    }
    return false;
}

- (void)setProgressUpdateInterval:(float)progressUpdateInterval
{
  _progressUpdateInterval = progressUpdateInterval;
}

- (void)removePlayerLayer
{
    [_playerLayer removeFromSuperlayer];
    [_playerLayer removeObserver:self forKeyPath:readyForDisplayKeyPath];
    _playerLayer = nil;
}

#pragma mark - RCTVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented && self.onVideoFullscreenPlayerWillDismiss)
    {
        self.onVideoFullscreenPlayerWillDismiss(@{@"target": self.reactTag});
    }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
    {
        _fullscreenPlayerPresented = false;
        _presentingViewController = nil;
        _playerViewController = nil;
        [self applyModifiers];
        if(self.onVideoFullscreenPlayerDidDismiss) {
            self.onVideoFullscreenPlayerDidDismiss(@{@"target": self.reactTag});
        }
    }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    RCTLogError(@"video cannot have any subviews");
}

- (void)removeReactSubview:(UIView *)subview
{
  if( _controls )
  {
      [subview removeFromSuperview];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setAnimationDuration:0];
  _playerLayer.frame = self.bounds;
  [CATransaction commit];
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [_player pause];
  if (_playbackRateObserverRegistered) {
    [_player removeObserver:self forKeyPath:playbackRate context:nil];
    _playbackRateObserverRegistered = NO;
  }
  [_player replaceCurrentItemWithPlayerItem:nil];
  _player = nil;

  [self removePlayerLayer];

  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];

  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  [super removeFromSuperview];
}

@end
