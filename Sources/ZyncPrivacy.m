// language: Objective-C, file: ZyncPrivacy.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Messaging privacy + analytics control.
//
// Outgoing typing: hook sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:
// Seen:           sendSeenMessageWithChatEntity:, sendSeenMessageWithTalkTableItem:,
//                 sendSeenMessages:messageDict:incomingData:, _sendSeenMessageWithSeenData:messageType:
// Read receipts:  sendSeenServer, sendSeenServerPARQueue, forceSendSeenServer,
//                 sendSeenLastMessageWithThreadIds:withMessageType:, sendSeenChatACK:withSubCommandType:,
//                 sendSeenGroupChatACKByData:withSubCommandType:,
//                 sendSeenCurrentUnreadFriendRequest:(retryTime:)sourceView:
// Local chat state (marking read on device) is intentionally untouched — only
// the outbound notifications are suppressed, so messaging integrity holds.
//
// Analytics: Firebase collection flags are flipped through the official
// Firebase API when present (FIRAnalytics / FIRPerformance / FIRCrashlytics).

#import "Zync.h"

// Block-observer token held for process lifetime (releasing it unregisters).
static id gZyncPrivacyPrefsToken = nil;

#pragma mark - Generic per-arity installer helpers

typedef void (*ZyncV0)(id, SEL);
typedef void (*ZyncV1)(id, SEL, id);
typedef void (*ZyncV2)(id, SEL, id, id);
typedef void (*ZyncV3)(id, SEL, id, id, id);
typedef void (*ZyncV5)(id, SEL, id, id, id, id, id);

// Gate: every declared argument must be an object (# = Class, @ = object,
// including @"Class" and @"?" block forms). Scalar (Q/i/B/c/s/...) or
// pointer (^/*/v) arguments would be retained as objects by the id-based
// hook — an EXC_BAD_ACCESS during objc_retain — so refuse them here.
// Uses only class_getInstanceMethod / method_getNumberOfArguments /
// method_getTypeEncoding; no new anchors.
static const char *ZySkipDigits(const char *p) {
    while (p && *p >= '0' && *p <= '9') p++;
    return p;
}

static const char *ZySkipTypeQualifiers(const char *p) {
    while (p && (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'O' ||
                 *p == 'V' || *p == 'o')) {
        p++;
    }
    return p;
}

static const char *ZySkipOneType(const char *p) {
    if (!p) return p;
    // Modern encodings carry byte-offset size digits before/after each type
    // (e.g. v40@0:8@16@24@32). Skip them so offsets are never read as types.
    p = ZySkipDigits(p);
    p = ZySkipTypeQualifiers(p);
    p = ZySkipDigits(p);
    char c = *p;
    if (c == '\0') return p;
    if (c == '{' || c == '(' || c == '[') {
        char close = (c == '{') ? '}' : (c == '(' ? ')' : ']');
        int depth = 0;
        while (*p) {
            if (*p == c) depth++;
            else if (*p == close) {
                depth--;
                p++;
                if (depth == 0) break;
                continue;
            }
            p++;
        }
        return ZySkipDigits(p);
    }
    if (c == '^') {
        p++;
        return ZySkipOneType(p);
    }
    if (c == '@') {
        p++;
        if (*p == '"') {
            p++;
            while (*p && *p != '"') p++;
            if (*p == '"') p++;
        } else if (*p == '?') {
            // Bare block form @?
            p++;
        }
        return ZySkipDigits(p);
    }
    if (c == '"') {
        p++;
        while (*p && *p != '"') p++;
        if (*p == '"') p++;
        return ZySkipDigits(p);
    }
    // Single-char types including ':' (skip as 1 char) and scalars (Q/i/...).
    return ZySkipDigits(p + 1);
}

static BOOL ZyArgsAreObjects(Class cls, SEL sel, NSUInteger declaredArgs) {
    if (!cls || !sel) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    const char *enc = method_getTypeEncoding(method);
    if (!enc || enc[0] == '\0') return NO;
    if (method_getNumberOfArguments(method) != declaredArgs + 2) {
        ZYNC_LOG(@"skip %s -[%s] non-object arg in %s", sel_getName(sel), class_getName(cls), enc);
        return NO;
    }
    const char *p = enc;
    p = ZySkipOneType(p); // return
    p = ZySkipOneType(p); // self
    p = ZySkipOneType(p); // _cmd
    for (NSUInteger i = 0; i < declaredArgs; i++) {
        const char *q = ZySkipTypeQualifiers(ZySkipDigits(p));
        if (*q != '@' && *q != '#') {
            ZYNC_LOG(@"skip %s -[%s] non-object arg in %s", sel_getName(sel), class_getName(cls), enc);
            return NO;
        }
        p = ZySkipOneType(p);
    }
    return YES;
}

static void ZyInstallV0(const char *selName, NSString *toggleKey) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 0, "v", ^(id self) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return;
            ((ZyncV0)original)(self, sel);
        });
    });
}

static void ZyInstallV1(const char *selName, NSString *toggleKey) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        if (!ZyArgsAreObjects(cls, sel, 1)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 1, "v", ^(id self, id a1) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return;
            ((ZyncV1)original)(self, sel, a1);
        });
    });
}

static void ZyInstallV2(const char *selName, NSString *toggleKey) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        if (!ZyArgsAreObjects(cls, sel, 2)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 2, "v", ^(id self, id a1, id a2) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return;
            ((ZyncV2)original)(self, sel, a1, a2);
        });
    });
}

static void ZyInstallV3(const char *selName, NSString *toggleKey) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        if (!ZyArgsAreObjects(cls, sel, 3)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 3, "v", ^(id self, id a1, id a2, id a3) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return;
            ((ZyncV3)original)(self, sel, a1, a2, a3);
        });
    });
}

static void ZyInstallV5(const char *selName, NSString *toggleKey) {
    SEL sel = sel_registerName(selName);
    ZyncEnumerateAppClasses(^(Class cls) {
        if (!ZyncClassHasInstanceMethod(cls, sel)) return;
        if (!ZyArgsAreObjects(cls, sel, 5)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        ZyncReplaceMethod(cls, sel, 5, "v", ^(id self, id a1, id a2, id a3, id a4, id a5) {
            if ([[ZyncPreferences shared] boolForKey:toggleKey]) return;
            ((ZyncV5)original)(self, sel, a1, a2, a3, a4, a5);
        });
    });
}

#pragma mark - Firebase / analytics

static void ZyncApplyFirebaseState(void) {
    BOOL blocked = [[ZyncPreferences shared] boolForKey:kZyncBlockFirebase];
    if (!blocked) return;

    Class firAnalytics = NSClassFromString(@"FIRAnalytics");
    if (firAnalytics && [firAnalytics respondsToSelector:NSSelectorFromString(@"setAnalyticsCollectionEnabled:")]) {
        IMP imp = class_getMethodImplementation(object_getClass(firAnalytics),
                                                NSSelectorFromString(@"setAnalyticsCollectionEnabled:"));
        if (imp) ((void (*)(id, SEL, BOOL))imp)(firAnalytics,
                                               NSSelectorFromString(@"setAnalyticsCollectionEnabled:"), NO);
    }

    Class firPerformance = NSClassFromString(@"FIRPerformance");
    if (firPerformance && [firPerformance respondsToSelector:NSSelectorFromString(@"setDataCollectionEnabled:")]) {
        IMP imp = class_getMethodImplementation(object_getClass(firPerformance),
                                                NSSelectorFromString(@"setDataCollectionEnabled:"));
        if (imp) ((void (*)(id, SEL, BOOL))imp)(firPerformance,
                                               NSSelectorFromString(@"setDataCollectionEnabled:"), NO);
    }

    Class crashlytics = NSClassFromString(@"FIRCrashlytics");
    SEL sharedSel = NSSelectorFromString(@"crashlytics");
    if (crashlytics && [crashlytics respondsToSelector:sharedSel]) {
        IMP sharedImp = class_getMethodImplementation(object_getClass(crashlytics), sharedSel);
        id instance = sharedImp ? ((id (*)(id, SEL))sharedImp)(crashlytics, sharedSel) : nil;
        SEL collectionSel = NSSelectorFromString(@"setCrashlyticsCollectionEnabled:");
        if (instance && [instance respondsToSelector:collectionSel]) {
            IMP imp = class_getMethodImplementation(object_getClass(instance), collectionSel);
            if (imp) ((void (*)(id, SEL, BOOL))imp)(instance, collectionSel, NO);
        }
    }
    ZYNC_LOG(@"Firebase collection disabled");
}

void ZyncPrivacyInstall(void) {
    // Typing indicator (outgoing only).
    ZyInstallV5("sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:", kZyncHideTyping);

    // Seen notifications.
    ZyInstallV1("sendSeenMessageWithChatEntity:", kZyncHideSeen);
    ZyInstallV1("sendSeenMessageWithTalkTableItem:", kZyncHideSeen);
    ZyInstallV3("sendSeenMessages:messageDict:incomingData:", kZyncHideSeen);
    ZyInstallV2("_sendSeenMessageWithSeenData:messageType:", kZyncHideSeen);

    // Read receipts / server acknowledgements.
    ZyInstallV0("sendSeenServer", kZyncHideReadReceipts);
    ZyInstallV0("sendSeenServerPARQueue", kZyncHideReadReceipts);
    ZyInstallV0("forceSendSeenServer", kZyncHideReadReceipts);
    ZyInstallV2("sendSeenLastMessageWithThreadIds:withMessageType:", kZyncHideReadReceipts);
    ZyInstallV2("sendSeenChatACK:withSubCommandType:", kZyncHideReadReceipts);
    ZyInstallV2("sendSeenGroupChatACKByData:withSubCommandType:", kZyncHideReadReceipts);
    ZyInstallV2("sendSeenCurrentUnreadFriendRequest:sourceView:", kZyncHideReadReceipts);
    ZyInstallV3("sendSeenCurrentUnreadFriendRequest:retryTime:sourceView:", kZyncHideReadReceipts);

    // Firebase / analytics.
    ZyncApplyFirebaseState();
    gZyncPrivacyPrefsToken = [[NSNotificationCenter defaultCenter] addObserverForName:ZyncPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isEqualToString:kZyncBlockFirebase]) ZyncApplyFirebaseState();
    }];

    ZYNC_LOG(@"privacy installed");
}
