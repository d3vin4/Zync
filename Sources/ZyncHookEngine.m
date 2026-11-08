// language: Objective-C, file: ZyncHookEngine.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Runtime discovery + strictly validated method replacement.
// No hardcoded addresses. Every install validates selector arity and return
// encoding first; anything that does not match is skipped silently (logged).

#import "Zync.h"

BOOL ZyncIsAppRelatedClass(Class cls) {
    if (!cls) return NO;
    NSBundle *bundle = [NSBundle bundleForClass:cls];
    NSString *path = [bundle bundlePath];
    if (!path) return NO;
    return [path containsString:@"/Zalo.app/"];
}

BOOL ZyncClassHasInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    return class_getInstanceMethod(cls, sel) != NULL;
}

BOOL ZyncClassHasIvar(Class cls, const char *name) {
    if (!cls || !name) return NO;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    if (!ivars) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        const char *ivarName = ivar_getName(ivars[i]);
        if (ivarName && strcmp(ivarName, name) == 0) { found = YES; break; }
    }
    free(ivars);
    return found;
}

void ZyncEnumerateAppClasses(void (^enumerator)(Class cls)) {
    if (!enumerator) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (ZyncIsAppRelatedClass(cls)) enumerator(cls);
    }
    free(classes);
}

BOOL ZyncReplaceMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                       const char *allowedReturns, id hookBlock) {
    if (!cls || !sel || !hookBlock || !allowedReturns) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    NSUInteger totalArgs = method_getNumberOfArguments(method);
    if (totalArgs != declaredArgs + 2) return NO;

    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] == '\0') return NO;
    if (strchr(allowedReturns, encoding[0]) == NULL) return NO;

    static NSMutableSet *hooked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hooked = [NSMutableSet set]; });
    NSString *pairKey = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized (hooked) {
        if ([hooked containsObject:pairKey]) return NO;
        [hooked addObject:pairKey];
    }

    IMP replacement = imp_implementationWithBlock(hookBlock);
    if (!replacement) return NO;
    class_replaceMethod(cls, sel, replacement, encoding);
    ZYNC_LOG(@"hook %s -[%s]", sel_getName(sel), class_getName(cls));
    return YES;
}
