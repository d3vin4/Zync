// language: Objective-C, file: ZyncFeatures.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Feature restoration — mechanisms ported (clean-room) from the feature set of
// ZaloXposed, re-anchored on iOS evidence found in the Zalo 26.11.01 binary:
//
// Profile Music: keys kProfileMusicSetting / profile_music / features@profile_music /
//   enable_rbt exist in the binary (features@profile_music at strings line 285173).
//   Getters enableProfileMusic / enableProfileMusicRBT / enableShareProfileMusic /
//   newFlagEnableProfileMusic are forced while the toggle is on; the local setter
//   is forced to YES. External keys are mirrored into standard defaults and the
//   settings App Group so BaseUserDefault-backed code reads them.
//
// Google Drive Backup: the legacy ZAGDrive* stack (ZAGDriveAuthorization,
//   ZAGDriveService, ZAGDriveListApi, ...) plus migration strings
//   (restore_gdrive_photo_csc, kCloudMigrGDriveState) ship in the binary.
//   The backup entry is bridged when the migration path returns nil:
//   _basicBackupGDriveSectionZInstantData <-> __basicBackupGDriveSectionZInstantData.
//
// More Tab: enable_tabmore key (present in the binary) is mirrored on.

#import "Zync.h"

// Block-observer token held for process lifetime (releasing it unregisters).
static id gZyncFeaturesPrefsToken = nil;

#pragma mark - Generic BOOL getter forcing

static void ZyForceBoolGetter(const char *selName, NSString *toggleKey, BOOL (^predicate)(Class)) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (predicate && !predicate(cls)) return;
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 0, "Bc", ^BOOL(id self) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return YES;
            return ((BOOL (*)(id, SEL))original)(self, sel);
        });
    });
}

static BOOL ZyncClassLooksProfileMusic(Class cls) {
    if (ZyncClassHasIvar(cls, "_enableProfileMusic")) return YES;
    if (ZyncClassHasIvar(cls, "_enableProfileMusicRBT")) return YES;
    if (ZyncClassHasIvar(cls, "_enableShareProfileMusic")) return YES;
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)];
    return [name containsString:@"ProfileMusic"];
}

#pragma mark - Profile Music

static NSArray<NSString *> *ZyncProfileMusicExternalKeys(void) {
    return @[@"kProfileMusicSetting", @"profile_music", @"features@profile_music", @"enable_rbt"];
}

static void ZyncApplyProfileMusicState(void) {
    ZyncPreferences *prefs = [ZyncPreferences shared];
    BOOL enabled = [prefs boolForKey:kZyncRestoreProfileMusic];
    for (NSString *key in ZyncProfileMusicExternalKeys()) {
        if (enabled) {
            [prefs writeExternalValue:@YES forKey:key];
        } else {
            [prefs restoreExternalValueForKey:key];
        }
    }
}

static void ZyncInstallProfileMusicHooks(void) {
    NSArray<NSString *> *getters = @[@"enableProfileMusic",
                                     @"enableProfileMusicRBT",
                                     @"enableShareProfileMusic",
                                     @"newFlagEnableProfileMusic"];
    for (NSString *getter in getters) {
        ZyForceBoolGetter(getter.UTF8String, kZyncRestoreProfileMusic, ^BOOL(Class cls) {
            return ZyncClassLooksProfileMusic(cls);
        });
    }

    SEL localSetter = sel_registerName("setEnableProfileMusicLocal:");
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, localSetter)) return;
        IMP original = class_getMethodImplementation(cls, localSetter);
        ZyncReplaceMethod(cls, localSetter, 1, "v", ^(id self, BOOL value) {
            BOOL force = [[ZyncPreferences shared] boolForKey:kZyncRestoreProfileMusic];
            ((void (*)(id, SEL, BOOL))original)(self, localSetter, force ? YES : value);
        });
    });
}

#pragma mark - Google Drive Backup

static void ZyncInstallGDriveBridge(void) {
    SEL modern = sel_registerName("__basicBackupGDriveSectionZInstantData");
    SEL legacy = sel_registerName("_basicBackupGDriveSectionZInstantData");

    ZyncEnumerateAppClasses(^(Class cls) {
        BOOL hasModern = ZyncClassHasInstanceMethod(cls, modern);
        BOOL hasLegacy = ZyncClassHasInstanceMethod(cls, legacy);
        if (!hasModern && !hasLegacy) return;

        // Capture both originals BEFORE replacing either, then call them directly —
        // never objc_msgSend on self, which would recurse into our own replacement.
        IMP modernOrig = hasModern ? class_getMethodImplementation(cls, modern) : NULL;
        IMP legacyOrig = hasLegacy ? class_getMethodImplementation(cls, legacy) : NULL;

        if (hasModern) {
            ZyncReplaceMethod(cls, modern, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))modernOrig)(self, modern);
                if (result) return result;
                if (![[ZyncPreferences shared] boolForKey:kZyncRestoreGDrive]) return nil;
                if (legacyOrig) {
                    id fallback = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                    if (fallback) { ZYNC_LOG(@"gdrive section restored (legacy path)"); return fallback; }
                }
                return nil;
            });
        }

        if (hasLegacy) {
            ZyncReplaceMethod(cls, legacy, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                if (result) return result;
                if (![[ZyncPreferences shared] boolForKey:kZyncRestoreGDrive]) return nil;
                if (modernOrig) {
                    id fallback = ((id (*)(id, SEL))modernOrig)(self, modern);
                    if (fallback) { ZYNC_LOG(@"gdrive section restored (modern path)"); return fallback; }
                }
                return nil;
            });
        }
    });
}

static void ZyncApplyGDriveState(void) {
    ZyncPreferences *prefs = [ZyncPreferences shared];
    if ([prefs boolForKey:kZyncRestoreGDrive]) {
        [prefs writeExternalValue:@YES forKey:@"restore_gdrive_photo_csc"];
    } else {
        [prefs restoreExternalValueForKey:@"restore_gdrive_photo_csc"];
    }
}

#pragma mark - More Tab

static void ZyncApplyMoreTabState(void) {
    ZyncPreferences *prefs = [ZyncPreferences shared];
    if ([prefs boolForKey:kZyncRestoreMoreTab]) {
        [prefs writeExternalValue:@YES forKey:@"enable_tabmore"];
    } else {
        [prefs restoreExternalValueForKey:@"enable_tabmore"];
    }
}

#pragma mark - Install

void ZyncFeaturesInstall(void) {
    ZyncInstallProfileMusicHooks();
    ZyncInstallGDriveBridge();

    ZyncApplyProfileMusicState();
    ZyncApplyGDriveState();
    ZyncApplyMoreTabState();

    gZyncFeaturesPrefsToken = [[NSNotificationCenter defaultCenter] addObserverForName:ZyncPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *key = note.object;
        if ([key isEqualToString:kZyncRestoreProfileMusic]) ZyncApplyProfileMusicState();
        if ([key isEqualToString:kZyncRestoreGDrive]) ZyncApplyGDriveState();
        if ([key isEqualToString:kZyncRestoreMoreTab]) ZyncApplyMoreTabState();
    }];

    ZYNC_LOG(@"features installed");
}
