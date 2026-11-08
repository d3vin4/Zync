// language: Objective-C, file: ZyncCompatibility.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Host detection: bundle identity, supported version range, anchor presence.

#import "Zync.h"

static NSString *const kZyncSupportedHostVersionPrefix = @"261101";

@implementation ZyncCompatibility

+ (BOOL)hostSupported {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = info[@"CFBundleIdentifier"];
    if (![bundleId isEqualToString:@"vn.com.vng.zingalo"]) return NO;
    NSString *build = info[@"CFBundleVersion"];
    if (build && [build hasPrefix:kZyncSupportedHostVersionPrefix]) return YES;
    NSString *version = info[@"CFBundleShortVersionString"];
    if (version && ([version hasPrefix:@"26.11"] || [version hasPrefix:kZyncSupportedHostVersionPrefix])) return YES;
    return NO;
}

+ (NSString *)hostVersion {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *status = [self hostSupported] ? @"supported" : @"untested";
    return [NSString stringWithFormat:@"%@ (%@) — %@", shortVersion, build, status];
}

+ (BOOL)anchorExists:(NSString *)className {
    if (!className) return NO;
    return NSClassFromString(className) != Nil;
}

@end
