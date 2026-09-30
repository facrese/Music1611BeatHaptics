#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreHaptics/CoreHaptics.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <stdlib.h>
#import <float.h>

// This dylib deliberately contains no account credentials. It borrows only
// request headers created by the logged-in Music process, in memory.
@interface BHController : NSObject
@property (nonatomic, copy) NSString *songID;
@property (nonatomic, copy) NSString *storefront;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSNumber *> *beats;
@property (nonatomic, copy) NSArray<NSNumber *> *bars;
@property (nonatomic, strong) CHHapticEngine *engine;
@property (nonatomic, strong) id<CHHapticAdvancedPatternPlayer> player;
@property (nonatomic) NSTimeInterval anchorPosition;
@property (nonatomic) CFTimeInterval anchorTime;
@property (nonatomic) BOOL fetching;
@property (nonatomic) BOOL playing;
@property (nonatomic) CFTimeInterval nextFetchTime;
+ (instancetype)shared;
- (void)observeRequest:(NSURLRequest *)request;
- (void)tick;
@end

static NSString *BHHeader(NSDictionary *headers, NSString *key) {
    for (NSString *name in headers) {
        if ([name caseInsensitiveCompare:key] == NSOrderedSame) {
            id value = headers[name];
            return [value isKindOfClass:NSString.class] ? value : nil;
        }
    }
    return nil;
}

static BOOL BHValidSongID(NSString *identifier) {
    if (identifier.length == 0 || identifier.length > 20) return NO;
    return [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static NSArray<NSNumber *> *BHMilliseconds(id candidate) {
    if (![candidate isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSNumber *> *result = NSMutableArray.array;
    NSInteger previous = -1;
    for (id value in candidate) {
        if (![value isKindOfClass:NSNumber.class]) continue;
        NSInteger ms = [value integerValue];
        if (ms < 0 || ms > 36000000 || ms <= previous) continue;
        [result addObject:@(ms)];
        previous = ms;
    }
    return result;
}

static NSDictionary *BHFindBeats(id node, NSUInteger depth) {
    if (depth > 9) return nil;
    if ([node isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = node;
        if ([dictionary[@"beatsInMilliseconds"] isKindOfClass:NSArray.class]) return dictionary;
        for (id value in dictionary.allValues) {
            NSDictionary *found = BHFindBeats(value, depth + 1);
            if (found) return found;
        }
    } else if ([node isKindOfClass:NSArray.class]) {
        for (id value in node) {
            NSDictionary *found = BHFindBeats(value, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

@implementation BHController

+ (instancetype)shared {
    static BHController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [BHController new]; });
    return controller;
}

- (void)observeRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (![url.host.lowercaseString isEqualToString:@"amp-api.music.apple.com"] ||
        [url.query containsString:@"audio-analysis"]) return;
    NSString *authorization = BHHeader(request.allHTTPHeaderFields, @"Authorization");
    if (authorization.length == 0) return;
    NSMutableDictionary *headers = NSMutableDictionary.dictionary;
    for (NSString *name in @[@"Authorization", @"media-user-token", @"Cookie",
                              @"x-apple-client-version", @"X-Apple-Store-Front"]) {
        NSString *value = BHHeader(request.allHTTPHeaderFields, name);
        if (value.length) headers[name] = value;
    }
    NSArray *components = url.pathComponents;
    NSUInteger index = [components indexOfObject:@"catalog"];
    NSString *storefront = index != NSNotFound && index + 1 < components.count ? components[index + 1] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.requestHeaders = headers;
        if (storefront.length == 2) self.storefront = storefront;
        if (self.songID.length && !self.beats.count && !self.fetching &&
            CACurrentMediaTime() >= self.nextFetchTime) [self fetchBeats];
    });
}

- (void)ensureEngine {
    if (self.engine || !CHHapticEngine.capabilitiesForHardware.supportsHaptics) return;
    NSError *error = nil;
    self.engine = [[CHHapticEngine alloc] initWithAudioSession:nil error:&error];
    if (error) NSLog(@"[BeatHaptics] Engine creation failed: %@", error);
    self.engine.playsHapticsOnly = YES;
    self.engine.autoShutdownEnabled = NO;
    __weak BHController *weakSelf = self;
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        NSLog(@"[BeatHaptics] Engine stopped: %ld", (long)reason);
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.player = nil;
            weakSelf.playing = NO;
            if (reason != CHHapticEngineStoppedReasonApplicationSuspended) {
                [weakSelf performSelector:@selector(tick) withObject:nil afterDelay:0.5];
            }
        });
    };
    self.engine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.player = nil;
            weakSelf.playing = NO;
            [weakSelf performSelector:@selector(tick) withObject:nil afterDelay:0.5];
        });
    };
}

- (void)stopPlayback {
    if (self.player) [self.player stopAtTime:CHHapticTimeImmediate error:nil];
    self.player = nil;
    self.playing = NO;
}

- (void)fetchBeats {
    if (!BHValidSongID(self.songID) || self.fetching || !self.requestHeaders[@"Authorization"] ||
        CACurrentMediaTime() < self.nextFetchTime) return;
    self.fetching = YES;
    self.nextFetchTime = CACurrentMediaTime() + 20;
    NSString *songID = self.songID;
    NSString *storefront = self.storefront.length ? self.storefront : @"us";
    NSString *urlString = [NSString stringWithFormat:
        @"https://amp-api.music.apple.com/v1/catalog/%@/songs/%@?include=audio-analysis", storefront, songID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    for (NSString *key in self.requestHeaders) [request setValue:self.requestHeaders[key] forHTTPHeaderField:key];
    if (!self.requestHeaders[@"Cookie"]) {
        NSArray *cookies = [NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:request.URL];
        NSDictionary *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies ?: @[]];
        if (cookieHeaders[@"Cookie"]) [request setValue:cookieHeaders[@"Cookie"] forHTTPHeaderField:@"Cookie"];
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *beatObject = BHFindBeats(json, 0);
        NSArray *beats = BHMilliseconds(beatObject[@"beatsInMilliseconds"]);
        NSArray *bars = BHMilliseconds(beatObject[@"barsInMilliseconds"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.fetching = NO;
            if (![self.songID isEqualToString:songID]) return;
            NSLog(@"[BeatHaptics] Analysis HTTP %ld; beats=%lu bars=%lu error=%@",
                  (long)status, (unsigned long)beats.count, (unsigned long)bars.count, error);
            self.beats = beats;
            self.bars = bars;
            if (beats.count) self.nextFetchTime = DBL_MAX;
            [self tick];
        });
    }] resume];
}

- (void)preparePlayer {
    if (self.player || self.beats.count == 0) return;
    [self ensureEngine];
    if (!self.engine) return;
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        NSLog(@"[BeatHaptics] Engine start failed: %@", error);
        return;
    }
    NSMutableArray<CHHapticEvent *> *events = NSMutableArray.array;
    NSSet *barTimes = [NSSet setWithArray:self.bars ?: @[]];
    for (NSNumber *time in self.beats) {
        BOOL bar = [barTimes containsObject:time];
        float intensity = bar ? 0.72f : 0.38f;
        float sharpness = bar ? 0.62f : 0.46f;
        NSArray *parameters = @[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness]
        ];
        [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                parameters:parameters relativeTime:time.doubleValue / 1000.0]];
    }
    for (NSNumber *time in self.bars) {
        BOOL coincides = NO;
        for (NSNumber *beat in self.beats) {
            if (labs(beat.longValue - time.longValue) <= 55) { coincides = YES; break; }
            if (beat.longValue > time.longValue + 55) break;
        }
        if (!coincides) {
            CHHapticEventParameter *strength = [[CHHapticEventParameter alloc]
                initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.72f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                    parameters:@[strength] relativeTime:time.doubleValue / 1000.0]];
        }
    }
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:events parameterCurves:@[] error:&error];
    if (!pattern) { NSLog(@"[BeatHaptics] Pattern failed: %@", error); return; }
    self.player = [self.engine createAdvancedPlayerWithPattern:pattern error:&error];
    if (!self.player) NSLog(@"[BeatHaptics] Player failed: %@", error);
}

- (void)tick {
    MPMusicPlayerController *music = MPMusicPlayerController.systemMusicPlayer;
    NSString *songID = music.nowPlayingItem.playbackStoreID;
    if (!BHValidSongID(songID)) songID = nil;
    if (![songID isEqualToString:self.songID]) {
        [self stopPlayback];
        self.songID = songID;
        self.beats = nil;
        self.bars = nil;
        self.fetching = NO;
        self.nextFetchTime = 0;
        if (songID) [self fetchBeats];
    }
    if (music.playbackState != MPMusicPlaybackStatePlaying || !songID) {
        [self stopPlayback];
        return;
    }
    if (!self.beats.count) {
        if (!self.fetching && self.requestHeaders[@"Authorization"] &&
            CACurrentMediaTime() >= self.nextFetchTime) [self fetchBeats];
        return;
    }
    NSTimeInterval position = MAX(0, music.currentPlaybackTime);
    [self preparePlayer];
    if (!self.player) return;
    if (self.playing) {
        NSTimeInterval expected = self.anchorPosition + CACurrentMediaTime() - self.anchorTime;
        if (fabs(expected - position) < 0.6) return;
        [self stopPlayback];
        [self preparePlayer];
        if (!self.player) return;
    }
    NSError *error = nil;
    if (![self.player seekToOffset:position error:&error] ||
        ![self.player startAtTime:CHHapticTimeImmediate error:&error]) {
        NSLog(@"[BeatHaptics] Start/seek failed: %@", error);
        [self stopPlayback];
        return;
    }
    self.anchorPosition = position;
    self.anchorTime = CACurrentMediaTime();
    self.playing = YES;
}
@end

@interface NSURLSession (BHAuthenticationCapture)
- (NSURLSessionDataTask *)bh_dataTaskWithRequest:(NSURLRequest *)request
                              completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (NSURLSessionDataTask *)bh_dataTaskWithRequest:(NSURLRequest *)request;
@end

@implementation NSURLSession (BHAuthenticationCapture)
- (NSURLSessionDataTask *)bh_dataTaskWithRequest:(NSURLRequest *)request
                              completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    [[BHController shared] observeRequest:request];
    return [self bh_dataTaskWithRequest:request completionHandler:completion];
}
- (NSURLSessionDataTask *)bh_dataTaskWithRequest:(NSURLRequest *)request {
    [[BHController shared] observeRequest:request];
    return [self bh_dataTaskWithRequest:request];
}
@end

static void BHSwizzle(SEL original, SEL replacement) {
    Class target = NSURLSession.class;
    Method a = class_getInstanceMethod(target, original);
    Method b = class_getInstanceMethod(target, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

__attribute__((constructor)) static void BHStart(void) {
    BHSwizzle(@selector(dataTaskWithRequest:completionHandler:),
             @selector(bh_dataTaskWithRequest:completionHandler:));
    BHSwizzle(@selector(dataTaskWithRequest:), @selector(bh_dataTaskWithRequest:));
    dispatch_async(dispatch_get_main_queue(), ^{
        BHController *controller = [BHController shared];
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *ignored) {
            [controller tick];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [controller tick];
        NSLog(@"[BeatHaptics] Loaded; awaiting Music authentication and playback");
    });
}
