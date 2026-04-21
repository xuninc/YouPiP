// DebugLogger.x — passive observer embedded inside YouPiP.
//
// Self-contained ring-buffer + os_log pipe. Passive %orig hooks on keychain/SSO/AVPiP —
// each one chains to the real implementation, only observing the return. No HUD, no
// overlay button, no new settings section. The user-facing controls ("Enable Debug
// Logging" + "Share Debug Log") are added to YouPiP's existing Settings.x section, not
// here.
//
// Why inside YouPiP? Dayanch's build workflow always pulls YouPiP (when enable_youpip
// is true — the default), so our logger ships as part of an expected dylib instead of a
// new-looking one. Safe to pair with closed-source tweaks that hook the same classes;
// our hooks just observe whatever value they return.

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

#pragma mark - Log ring buffer

NSString *const kYPDLEnabledKey = @"ypdl_enabled";

static NSMutableArray<NSString *> *ypdl_ring(void) {
    static NSMutableArray *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [NSMutableArray arrayWithCapacity:2048]; });
    return r;
}

static dispatch_queue_t ypdl_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("i.am.kain.ypdl.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static NSDateFormatter *ypdl_fmt(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
    });
    return f;
}

BOOL ypdl_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kYPDLEnabledKey];
}

static void ypdl_append(NSString *category, NSString *line) {
    if (!ypdl_enabled()) return;
    NSString *stamp = [ypdl_fmt() stringFromDate:[NSDate date]];
    NSString *full = [NSString stringWithFormat:@"%@ [%@] %@", stamp, category ?: @"log", line];
    os_log(OS_LOG_DEFAULT, "[ypdl] %{public}s", full.UTF8String);
    dispatch_async(ypdl_queue(), ^{
        NSMutableArray *buf = ypdl_ring();
        [buf addObject:full];
        while (buf.count > 2048) [buf removeObjectAtIndex:0];
    });
}

#define ypdl(cat, ...) ypdl_append(cat, [NSString stringWithFormat:__VA_ARGS__])

// Public — called from Settings.x to build the "Share Debug Log" pasteboard payload
NSString *ypdl_snapshot_string(void) {
    __block NSArray *copy;
    dispatch_sync(ypdl_queue(), ^{ copy = [ypdl_ring() copy]; });
    return copy.count ? [copy componentsJoinedByString:@"\n"] : @"";
}

// Public — called from Settings.x to wipe the buffer
void ypdl_clear(void) {
    dispatch_async(ypdl_queue(), ^{ [ypdl_ring() removeAllObjects]; });
}

#pragma mark - Passive hooks: keychain / SSO

%hook SSOKeychainHelper
+ (NSString *)accessGroup {
    NSString *g = %orig;
    ypdl(@"keychain", @"SSOKeychainHelper.accessGroup -> %@", g ?: @"(nil)");
    return g;
}
+ (NSString *)sharedAccessGroup {
    NSString *g = %orig;
    ypdl(@"keychain", @"SSOKeychainHelper.sharedAccessGroup -> %@", g ?: @"(nil)");
    return g;
}
%end

%hook SSOKeychainCore
+ (NSString *)accessGroup {
    NSString *g = %orig;
    ypdl(@"keychain", @"SSOKeychainCore.accessGroup -> %@", g ?: @"(nil)");
    return g;
}
+ (NSString *)sharedAccessGroup {
    NSString *g = %orig;
    ypdl(@"keychain", @"SSOKeychainCore.sharedAccessGroup -> %@", g ?: @"(nil)");
    return g;
}
%end

#pragma mark - Passive hooks: AVPiP

@interface MLPIPController : NSObject
@end

%hook AVPictureInPictureController
- (instancetype)initWithPlayerLayer:(AVPlayerLayer *)playerLayer {
    AVPictureInPictureController *r = %orig;
    ypdl(@"avpip", @"init(PlayerLayer=%p) -> %p", playerLayer, r);
    return r;
}
- (instancetype)initWithContentSource:(id)contentSource {
    AVPictureInPictureController *r = %orig;
    ypdl(@"avpip", @"init(ContentSource=%p) -> %p", contentSource, r);
    return r;
}
- (void)startPictureInPicture {
    ypdl(@"avpip", @"startPictureInPicture self=%p active=%@", self, self.pictureInPictureActive ? @"YES" : @"NO");
    %orig;
}
- (void)stopPictureInPicture {
    ypdl(@"avpip", @"stopPictureInPicture self=%p", self);
    %orig;
}
%end

%hook MLPIPController
- (void)setPictureInPictureController:(id)controller {
    ypdl(@"mlpip", @"setPictureInPictureController self=%p avpip=%p", self, controller);
    %orig;
}
%end
