// language: Objective-C, file: ZyncAds.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Advertisement visibility management.
//
// Layer 1 (requests): handled by ZyncURIFilter.m — ad endpoints verified in the
//   binary: %@/zpads/inboxnative/getads, /v1/user/core/get/ads(_out_stream|_boost|v2),
//   /v1/ads/impression, https://ads.platform.zalo.me/
// Layer 2 (views): every Zalo.app view class carrying an ad marker in its name
//   (e.g. ZInstantFeedAdsView, LocationOAAdsCell — both present in the dumps)
//   is neutralized on insertion: didMoveToSuperview forces hidden, and
//   setHidden: is pinned to YES while the toggle is on. Turning the toggle off
//   restores normal behaviour on the next call.

#import "Zync.h"

typedef void (*ZyncV0)(id, SEL);
typedef void (*ZyncV1Bool)(id, SEL, BOOL);

static BOOL ZyncAdsClassNameMatches(Class cls) {
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)].lowercaseString;
    if ([name containsString:@"adsview"]) return YES;
    if ([name containsString:@"adscell"]) return YES;
    if ([name containsString:@"adsbanner"]) return YES;
    if ([name containsString:@"advert"]) return YES;
    if ([name containsString:@"promoted"]) return YES;
    return NO;
}

static BOOL ZyncAdsClassIsView(Class cls) {
    Class cursor = cls;
    while (cursor) {
        if (cursor == [UIView class]) return YES;
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static void ZyncAdsHardenViews(void) {
    SEL didMoveSel = sel_registerName("didMoveToSuperview");
    SEL setHiddenSel = sel_registerName("setHidden:");

    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncAdsClassIsView(cls)) return;
        if (!ZyncAdsClassNameMatches(cls)) return;

        if (ZyncClassHasInstanceMethod(cls, didMoveSel)) {
            IMP original = class_getMethodImplementation(cls, didMoveSel);
            ZyncReplaceMethod(cls, didMoveSel, 0, "v", ^(id self) {
                ((ZyncV0)original)(self, didMoveSel);
                if ([[ZyncPreferences shared] boolForKey:kZyncHideAds]) {
                    ((void (*)(id, SEL, BOOL))class_getMethodImplementation([UIView class], setHiddenSel))(self, setHiddenSel, YES);
                }
            });
        }

        if (ZyncClassHasInstanceMethod(cls, setHiddenSel)) {
            IMP original = class_getMethodImplementation(cls, setHiddenSel);
            ZyncReplaceMethod(cls, setHiddenSel, 1, "v", ^(id self, BOOL hidden) {
                BOOL force = [[ZyncPreferences shared] boolForKey:kZyncHideAds];
                ((ZyncV1Bool)original)(self, setHiddenSel, force ? YES : hidden);
            });
        }
    });
}

void ZyncAdsInstall(void) {
    ZyncAdsHardenViews();
    ZYNC_LOG(@"ads module installed");
}
