// language: Objective-C, file: ZyncPreferences.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Persistent configuration. Primary suite: vn.com.vng.zingalo.zync.
// External values (read by Zalo itself) are mirrored into standard defaults and
// the settings App Group "group.zsettings.vn.com.vng.zingalo", with the previous
// value remembered so toggling a feature off can restore the user's data.

#import "Zync.h"

NSString *const ZyncPrefsDidChangeNotification = @"ZyncPrefsDidChangeNotification";

NSString *const kZyncGlassTabBar         = @"zync.appearance.glass";
NSString *const kZyncHideTyping          = @"zync.privacy.hideTyping";
NSString *const kZyncHideSeen            = @"zync.privacy.hideSeen";
NSString *const kZyncHideReadReceipts    = @"zync.privacy.hideReadReceipts";
NSString *const kZyncBlockTracking       = @"zync.privacy.blockTracking";
NSString *const kZyncBlockFirebase       = @"zync.privacy.blockFirebase";
NSString *const kZyncHideAds             = @"zync.ads.hide";
NSString *const kZyncBlockAdRequests     = @"zync.ads.blockRequests";
NSString *const kZyncRestoreProfileMusic = @"zync.features.profileMusic";
NSString *const kZyncRestoreGDrive       = @"zync.features.gdriveBackup";
NSString *const kZyncRestoreMoreTab      = @"zync.features.moreTab";

static NSString *const kZyncSuite      = @"vn.com.vng.zingalo.zync";
static NSString *const kZyncGroupSuite = @"group.zsettings.vn.com.vng.zingalo";
static NSString *const kZyncPrevPrefix = @"zync.internal.prev.";

@interface ZyncPreferences ()
@property (nonatomic, strong) NSUserDefaults *own;
@property (nonatomic, strong) NSUserDefaults *group;
@property (nonatomic, strong) NSUserDefaults *standard;
@end

@implementation ZyncPreferences

+ (instancetype)shared {
    static ZyncPreferences *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ZyncPreferences alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _own      = [[NSUserDefaults alloc] initWithSuiteName:kZyncSuite] ?: [NSUserDefaults standardUserDefaults];
        _group    = [[NSUserDefaults alloc] initWithSuiteName:kZyncGroupSuite];
        _standard = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (BOOL)boolForKey:(NSString *)key {
    if ([self.own objectForKey:key] != nil) return [self.own boolForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group boolForKey:key];
    return [self.standard boolForKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [self.own setBool:value forKey:key];
    if (self.group) [self.group setBool:value forKey:key];
    [self.own synchronize];
    [self.group synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZyncPrefsDidChangeNotification object:key];
    ZYNC_LOG(@"pref %@ = %@", key, value ? @"ON" : @"OFF");
}

- (void)writeExternalValue:(id)value forKey:(NSString *)key {
    [self rememberExternalValueForKey:key];
    [self writeValue:value toExternalKey:key];
    ZYNC_LOG(@"external %@ written", key);
}

- (void)restoreExternalValueForKey:(NSString *)key {
    NSString *slot = [kZyncPrevPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] == nil) return;
    id previous = [self.own objectForKey:slot];
    if ([previous isKindOfClass:[NSNumber class]] && [previous boolValue] == NO &&
        ![self wasExternalKeyPresentBeforeWrite:key]) {
        // previous value was "absent" — remove what we wrote
        [self.standard removeObjectForKey:key];
        [self.group removeObjectForKey:key];
    } else if (previous) {
        [self writeValue:previous toExternalKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        [self.group removeObjectForKey:key];
    }
    [self.own removeObjectForKey:slot];
    ZYNC_LOG(@"external %@ restored", key);
}

- (BOOL)wasExternalKeyPresentBeforeWrite:(NSString *)key {
    NSString *flag = [kZyncPrevPrefix stringByAppendingFormat:@"present.%@", key];
    return [[self.own objectForKey:flag] boolValue];
}

- (void)rememberExternalValueForKey:(NSString *)key {
    NSString *slot = [kZyncPrevPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] != nil) return; // keep the very first captured value
    id current = [self readExternalKey:key];
    NSString *flag = [kZyncPrevPrefix stringByAppendingFormat:@"present.%@", key];
    if (current) {
        [self.own setObject:current forKey:slot];
        [self.own setBool:YES forKey:flag];
    } else {
        // Nothing existed before; remember that absence with an explicit marker value.
        [self.own setObject:@NO forKey:slot];
        [self.own setBool:NO forKey:flag];
    }
    [self.own synchronize];
}

- (id)readExternalKey:(NSString *)key {
    if ([self.standard objectForKey:key] != nil) return [self.standard objectForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group objectForKey:key];
    return nil;
}

- (void)writeValue:(id)value toExternalKey:(NSString *)key {
    if (value) {
        [self.standard setObject:value forKey:key];
        if (self.group) [self.group setObject:value forKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self.standard synchronize];
    [self.group synchronize];
}

@end
