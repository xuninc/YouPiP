// DebugLogger.x — passive observer embedded inside YouPiP.
//
// Self-contained: a small ring-buffer + os_log pipe, passive %orig hooks on keychain/SSO/AVPiP,
// and a "Copy Log" button registered via YTVideoOverlay that dumps the buffer to UIPasteboard.
//
// No HUD. No settings section. No behavioral modifications — every hook calls %orig and only
// observes the return value. Safe to pair with closed-source tweaks (YTLite) that already hook
// the same classes; our hooks chain after theirs and log whatever they return.
//
// Added as part of xuninc's YouPiP fork so the dayanch build workflow picks up the logger
// automatically when enable_youpip is true. No separate deb, no separate dylib — it travels
// inside YouPiP.dylib, which is an expected-looking framework in a YouTube Plus install.

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

#pragma mark - Ring-buffer logger

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

static void ypdl_append(NSString *category, NSString *line) {
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

static NSArray<NSString *> *ypdl_snapshot(void) {
    __block NSArray *copy;
    dispatch_sync(ypdl_queue(), ^{ copy = [ypdl_ring() copy]; });
    return copy;
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
    ypdl(@"avpip", @"startPictureInPicture self=%p active=%@",
         self, self.pictureInPictureActive ? @"YES" : @"NO");
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

#pragma mark - "Copy Log" overlay button (via YTVideoOverlay)

static NSString *const kLogTweakID = @"DebugLog";

@interface YTSettingsSectionItemManager : NSObject
+ (void)registerTweak:(NSString *)tweakId metadata:(NSDictionary *)metadata;
@end

@interface YTToastResponderEvent : NSObject
+ (instancetype)eventWithMessage:(NSString *)message firstResponder:(id)responder;
- (void)send;
@end

@class YTQTMButton;
@interface YTMainAppControlsOverlayView : UIView
@property (retain, nonatomic) NSMutableDictionary<NSString *, YTQTMButton *> *overlayButtons;
@end
@interface YTInlinePlayerBarContainerView : UIView
@property (retain, nonatomic) NSMutableDictionary<NSString *, YTQTMButton *> *overlayButtons;
@end

static UIImage *ypdl_icon(void) {
    static UIImage *img;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            UIImage *base = [UIImage systemImageNamed:@"doc.on.clipboard"];
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
            img = [base imageByApplyingSymbolConfiguration:cfg] ?: base;
        }
    });
    return img;
}

static void ypdl_copy(UIView *fromView) {
    NSArray *entries = ypdl_snapshot();
    NSString *body = entries.count ? [entries componentsJoinedByString:@"\n"] : @"(empty)";
    [UIPasteboard generalPasteboard].string = body;
    ypdl(@"ui", @"copied %lu lines (%lu chars) to pasteboard",
         (unsigned long)entries.count, (unsigned long)body.length);
    Class toast = NSClassFromString(@"YTToastResponderEvent");
    if (toast && fromView) {
        id e = [toast eventWithMessage:@"Debug log copied" firstResponder:fromView];
        [e send];
    }
}

%hook YTMainAppControlsOverlayView
- (UIImage *)buttonImage:(NSString *)tweakId {
    if ([tweakId isEqualToString:kLogTweakID]) return ypdl_icon();
    return %orig;
}
%new(v@:@)
- (void)didPressCopyLog:(id)arg { ypdl_copy(self); }
%end

%hook YTInlinePlayerBarContainerView
- (UIImage *)buttonImage:(NSString *)tweakId {
    if ([tweakId isEqualToString:kLogTweakID]) return ypdl_icon();
    return %orig;
}
%new(v@:@)
- (void)didPressCopyLog:(id)arg { ypdl_copy(self); }
%end

#pragma mark - Registration ctor

%ctor {
    ypdl(@"ctor", @"ypdl loaded in %@ (exe=%@)",
         [[NSBundle mainBundle] bundleIdentifier],
         [[NSBundle mainBundle] executablePath].lastPathComponent);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class mgr = NSClassFromString(@"YTSettingsSectionItemManager");
        if ([mgr respondsToSelector:@selector(registerTweak:metadata:)]) {
            [mgr registerTweak:kLogTweakID metadata:@{
                @"accessibilityLabel": @"Copy Log",
                @"selector": @"didPressCopyLog:",
            }];
            ypdl(@"ctor", @"registered CopyLog overlay button");
        } else {
            ypdl(@"ctor", @"YTVideoOverlay registerTweak: missing — button unavailable (use Console.app)");
        }
    });
}
