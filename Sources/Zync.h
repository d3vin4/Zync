// language: Objective-C, file: Zync.h, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Zync umbrella header — shared interfaces for all modules.

#ifndef ZYNC_H
#define ZYNC_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ZYNC_VERSION @"4.0"
#define ZYNC_BUILD   @"Build 4"

/** Appends a formatted line to <Documents>/Zync.log and the App Group log (tmp fallback). Implemented in ZyncCore.m. */
void ZyncFileLog(NSString *format, ...);

#define ZYNC_LOG(fmt, ...) do { \
    NSString *_zyncMessage = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSLog(@"[Zync] %@", _zyncMessage); \
    ZyncFileLog(@"[Zync] %@", _zyncMessage); \
} while (0)

extern NSString *const ZyncPrefsDidChangeNotification;

#pragma mark - Preference keys (all BOOL unless noted)

extern NSString *const kZyncGlassTabBar;        // zync.appearance.glass
extern NSString *const kZyncHideTyping;         // zync.privacy.hideTyping
extern NSString *const kZyncHideSeen;           // zync.privacy.hideSeen
extern NSString *const kZyncHideReadReceipts;   // zync.privacy.hideReadReceipts
extern NSString *const kZyncBlockTracking;      // zync.privacy.blockTracking
extern NSString *const kZyncBlockFirebase;      // zync.privacy.blockFirebase
extern NSString *const kZyncHideAds;            // zync.ads.hide
extern NSString *const kZyncBlockAdRequests;    // zync.ads.blockRequests
extern NSString *const kZyncRestoreProfileMusic;// zync.features.profileMusic
extern NSString *const kZyncRestoreGDrive;      // zync.features.gdriveBackup
extern NSString *const kZyncRestoreMoreTab;     // zync.features.moreTab

#pragma mark - ZyncPreferences

@interface ZyncPreferences : NSObject
+ (instancetype)shared;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
/** Mirrors a value into standard defaults + the Zalo settings App Group, remembering the previous value. */
- (void)writeExternalValue:(id)value forKey:(NSString *)key;
- (void)restoreExternalValueForKey:(NSString *)key;
@end

#pragma mark - Runtime hook engine

/** Enumerates all classes living inside Zalo.app (main bundle + embedded frameworks). */
void ZyncEnumerateAppClasses(void (^enumerator)(Class cls));
BOOL ZyncIsAppRelatedClass(Class cls);
BOOL ZyncClassHasInstanceMethod(Class cls, SEL sel);
BOOL ZyncClassHasIvar(Class cls, const char *name);

/**
 * Replaces an instance method implementation after strict validation:
 * arity must match (declaredArgs + 2) and the return encoding head must be in
 * allowedReturns (e.g. "v" for void, "Bc" for BOOL variants).
 * Returns NO — without touching the binary — whenever anything does not match.
 * Each (class, selector) pair is hooked at most once (dedupe set).
 */
BOOL ZyncReplaceMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                       const char *allowedReturns, id hookBlock);

#pragma mark - Module installers (called by ZyncCore)

void ZyncURIFilterInstall(void);
void ZyncPrivacyInstall(void);
void ZyncAdsInstall(void);
void ZyncFeaturesInstall(void);
void ZyncSettingsInstall(void);
void ZyncGlassInstall(void);

#pragma mark - Compatibility

@interface ZyncCompatibility : NSObject
+ (BOOL)hostSupported;
+ (NSString *)hostVersion;
+ (BOOL)anchorExists:(NSString *)className;
@end

#pragma mark - Dashboard UI

@interface ZyncSettingsViewController : UITableViewController
+ (instancetype)make;
/** Pushes the dashboard on the host's navigation controller (presents a wrapper if none). */
+ (void)pushFrom:(UIViewController *)host;
@end

#endif /* ZYNC_H */
