// language: Objective-C, file: ZyncCore.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Initialization and lifecycle. Loaded via LC_LOAD_DYLIB; raw constructor only
// logs immediately (stderr + NSLog) and registers a one-shot observer for
// UIApplicationDidFinishLaunchingNotification. Heavy installs run later on the
// main queue so ObjC runtime lookups never race the host's runtime lock.
// Each module install is isolated: a failure in one module never blocks others.

#import "Zync.h"
#include <stdio.h>

// Block-observer token must stay alive for process lifetime — releasing it
// unregisters the observer (NSNotificationCenter docs). Held at file scope.
static id gZyncDidFinishToken = nil;

#pragma mark - Persistent file log

// ZYNC_LOG also appends to a plain-text file so the user can open the log in
// the Files app without Console. Writes go to <Documents>/Zync.log (or tmp
// when Documents is unavailable) and to the App Group container when present.
// A serial queue serializes appends; failures are swallowed so logging can
// never crash the host.

static dispatch_queue_t ZyncFileLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("zync.filelog", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSArray<NSURL *> *ZyncFileLogURLs(void) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *documents = nil;
    @try {
        NSArray<NSURL *> *found = [[NSFileManager defaultManager]
                                    URLsForDirectory:NSDocumentDirectory
                                            inDomains:NSUserDomainMask];
        documents = found.firstObject;
    } @catch (__unused NSException *e) { documents = nil; }
    if (documents) {
        [urls addObject:[documents URLByAppendingPathComponent:@"Zync.log"]];
    } else {
        NSString *tmpPath = NSTemporaryDirectory();
        if (tmpPath) {
            [urls addObject:[NSURL fileURLWithPath:[tmpPath stringByAppendingPathComponent:@"Zync.log"]]];
        }
    }
    @try {
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:@"group.zsettings.vn.com.vng.zingalo"];
        if (group) [urls addObject:[group URLByAppendingPathComponent:@"Zync.log"]];
    } @catch (__unused NSException *e) {}
    return urls;
}

void ZyncFileLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    dispatch_async(ZyncFileLogQueue(), ^{
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        for (NSURL *url in ZyncFileLogURLs()) {
            @try {
                NSFileManager *manager = [NSFileManager defaultManager];
                NSString *directory = url.URLByDeletingLastPathComponent.path;
                if (directory) {
                    [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
                }
                if (![manager fileExistsAtPath:url.path]) {
                    [data writeToURL:url options:NSDataWritingAtomic error:nil];
                } else {
                    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
                    if (handle) {
                        @try {
                            [handle seekToEndOfFile];
                            [handle writeData:data];
                        } @catch (__unused NSException *e) {}
                        @try { [handle closeFile]; } @catch (__unused NSException *e) {}
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    });
}

static void ZyncRunInstaller(NSString *name, void (*installer)(void)) {
    @try {
        installer();
    } @catch (NSException *exception) {
        ZYNC_LOG(@"module %@ failed: %@", name, exception.reason);
    }
}

static void ZyncBoot(void) {
    // Exactly-once guard: DidFinishLaunching, the 5s fallback timer and the
    // 1s late-injection window check can all race — only the first wins.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
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
    });
}

static void ZyncBootAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ZyncBoot();
        } @catch (NSException *exception) {
            ZYNC_LOG(@"boot failed: %@", exception.reason);
        }
    });
}

static void ZyncScheduleBootAfterLaunch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gZyncDidFinishToken = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:dispatch_get_main_queue()
                    usingBlock:^(NSNotification *note) {
                         (void)note;
                         @try {
                             ZYNC_LOG(@"boot: DidFinishLaunching notification received");
                             ZyncBootAsync();
                         } @catch (NSException *exception) {
                             ZYNC_LOG(@"boot: DidFinishLaunching handler failed: %@", exception.reason);
                         }
                     }];

        // Safety net: the dylib constructor can run after the notification
        // already fired (late injection), so the observer above can miss it.
        // A 5s main-queue timer force-runs boot when no path ran it yet.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZYNC_LOG(@"boot: 5s fallback timer fired — ensuring boot");
            ZyncBootAsync();
        });

        // Late-injection window check: if a window already exists at
        // constructor time the host is already running — boot in 1s so the
        // visible Settings screen still gets its injection attempt.
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            BOOL hasWindow = NO;
            if (app) {
                for (UIScene *scene in app.connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        if (((UIWindowScene *)scene).windows.count > 0) hasWindow = YES;
                    }
                }
            }
            if (hasWindow) {
                ZYNC_LOG(@"boot: window already present at constructor — scheduling boot in 1s");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ZYNC_LOG(@"boot: 1s late-injection timer fired — ensuring boot");
                    ZyncBootAsync();
                });
            } else {
                ZYNC_LOG(@"boot: no window at constructor time — waiting for DidFinishLaunching");
            }
        } @catch (NSException *exception) {
            ZYNC_LOG(@"boot: window check threw (%@) — relying on notification + 5s fallback", exception.reason);
        }
    });
}

__attribute__((constructor))
static void ZyncEntry(void) {
    fprintf(stderr, "[Zync] loaded %s (%s)\n", [ZYNC_VERSION UTF8String], [ZYNC_BUILD UTF8String]);
    fflush(stderr);
    ZYNC_LOG(@"loaded %@ (%@)", ZYNC_VERSION, ZYNC_BUILD);
    ZyncScheduleBootAfterLaunch();
}
