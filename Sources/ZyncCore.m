// language: Objective-C, file: ZyncCore.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Initialization and lifecycle. Loaded via LC_LOAD_DYLIB; raw constructor only
// logs immediately (stderr + NSLog) and registers a one-shot observer for
// UIApplicationDidFinishLaunchingNotification. Heavy installs run later on a
// global concurrent queue so the host's first draw is never blocked.
// Each module install is isolated: a failure in one module never blocks others.

#import "Zync.h"
#include <stdio.h>

static void ZyncRunInstaller(NSString *name, void (*installer)(void)) {
    @try {
        installer();
    } @catch (NSException *exception) {
        ZYNC_LOG(@"module %@ failed: %@", name, exception.reason);
    }
}

static void ZyncBoot(void) {
    if (![ZyncCompatibility hostSupported]) {
        ZYNC_LOG(@"host not supported (%@) — Zync idle", [ZyncCompatibility hostVersion]);
        return;
    }

    ZYNC_LOG(@"booting %@ (%@) on %@", ZYNC_VERSION, ZYNC_BUILD, [ZyncCompatibility hostVersion]);
    ZYNC_LOG(@"anchors: settings=%d tabbar=%d",
             [ZyncCompatibility anchorExists:@"SettingUI40TableViewController"],
             [ZyncCompatibility anchorExists:@"ZaloTabBarViewController"]);

    ZyncRunInstaller(@"URIFilter", ZyncURIFilterInstall);
    ZyncRunInstaller(@"Privacy", ZyncPrivacyInstall);
    ZyncRunInstaller(@"Ads", ZyncAdsInstall);
    ZyncRunInstaller(@"Features", ZyncFeaturesInstall);
    ZyncRunInstaller(@"Settings", ZyncSettingsInstall);
    ZyncRunInstaller(@"Glass", ZyncGlassInstall);

    ZYNC_LOG(@"boot complete");
}

static void ZyncScheduleBootAfterLaunch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
                         (void)note;
                         dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                             @try {
                                 ZyncBoot();
                             } @catch (NSException *exception) {
                                 ZYNC_LOG(@"boot failed: %@", exception.reason);
                             }
                         });
                     }];
    });
}

__attribute__((constructor))
static void ZyncEntry(void) {
    fprintf(stderr, "[Zync] loaded %s (%s)\n", [ZYNC_VERSION UTF8String], [ZYNC_BUILD UTF8String]);
    fflush(stderr);
    NSLog(@"[Zync] loaded %@ (%@)", ZYNC_VERSION, ZYNC_BUILD);
    ZyncScheduleBootAfterLaunch();
}
