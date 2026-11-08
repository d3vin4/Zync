// language: Objective-C, file: ZyncCore.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Initialization and lifecycle. Loaded via LC_LOAD_DYLIB; boots once, on the
// main queue, after the host has created its first runloop turn. Each module
// install is isolated: a failure in one module never blocks the others.

#import "Zync.h"

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

    ZYNC_LOG(@"booting v%@ (%@) on %@", ZYNC_VERSION, ZYNC_BUILD, [ZyncCompatibility hostVersion]);
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

__attribute__((constructor))
static void ZyncEntry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            ZyncBoot();
        } @catch (NSException *exception) {
            ZYNC_LOG(@"boot failed: %@", exception.reason);
        }
    });
}
