// language: Objective-C, file: ZyncSettings.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Native Settings integration — injects "Zync Customize" as a cloned sibling of
// the "Account and security" row inside SettingUI40TableViewController (the
// settings hub class that owns accountAndSecurityObject / _accountAndSecurityObject).
//
// Primary tier: deep-copy the real cell object, retitle it, insert it directly
// above "Account and security" in the arranged content, and intercept row
// selection to push the Zync dashboard. The row that ships is a genuine Zalo
// cell object — identical height, padding, typography, separator and behaviour.
//
// Overlay tier (only if the model cannot be reached): a "Zync Customize"
// row drawn as an overlay view directly above the visible "Account and
// security" cell. It never touches the dataSource, so it works regardless
// of which dataSource object the table view actually uses.

#import "Zync.h"

#pragma mark - State

static id gOurRow = nil;
static NSArray<NSArray *> *gSectionSnapshot = nil;
static BOOL gSnapshotAligned = NO;
static NSUInteger gInjectAttempts = 0;
static Class gSettingsClass = Nil;

static NSArray<NSString *> *ZyncKnownAccountTitleValues(void) {
    return @[@"Tài khoản và bảo mật",
             @"Account and security",
             @"00Zh8W",
             @"tabme.section_items.account_security.title",
             @"tabme_account_security"];
}

static void ZyncEnsureRow(id vc);
static void ZyncPresentOverlayRow(id vc);
static void ZyncUpdateOverlay(id vc);
static char ZyncRetryCountKey;
static const NSUInteger kZyncMaxBFNodes = 4000;

// class_copyIvarList only returns ivars declared on the exact class — model,
// cell and category state in Zalo lives on superclasses (e.g. model/actions
// on BasicSettingTableViewController, title on BasicSettingCellV2Object
// parents). Walk the full chain so discovery, cloning and retitling all see
// inherited state.
static NSArray<NSValue *> *ZyncAllIvars(Class cls) {
    NSMutableArray<NSValue *> *list = [NSMutableArray array];
    Class current = cls;
    while (current && current != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            [list addObject:[NSValue valueWithPointer:(void *)ivars[i]]];
        }
        free(ivars);
        current = class_getSuperclass(current);
    }
    return list;
}

#pragma mark - Object cloning

// object_setIvar does not retain; ARC-managed ivars will release on dealloc.
// Retain once here so the clone owns exactly one reference, like a normal assignment.
static void ZyncSetIvarRetained(id object, Ivar ivar, id value) {
    if (value) CFRetain((__bridge CFTypeRef)value);
    object_setIvar(object, ivar, value);
}

static id ZyncCloneCellObject(id source) {
    if (!source) return nil;
    Class cls = object_getClass(source);
    if (!cls) return nil;

    // NSObject's default copyWithZone: returns self — only a real copy helps.
    if ([source respondsToSelector:@selector(copyWithZone:)]) {
        @try {
            id copy = [source copy];
            if (copy && copy != source && object_getClass(copy) == cls) return copy;
        } @catch (__unused NSException *e) {}
    }

    id clone = nil;
    @try { clone = [[cls alloc] init]; } @catch (__unused NSException *e) { return nil; }
    if (!clone) return nil;

    for (NSValue *boxed in ZyncAllIvars(cls)) {
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] == '\0') continue;
        if (type[0] == '@') {
            @try {
                id value = object_getIvar(source, ivar);
                if (value) ZyncSetIvarRetained(clone, ivar, value);
            } @catch (__unused NSException *e) {}
        } else {
            NSUInteger size = 0;
            NSGetSizeAndAlignment(type, &size, NULL);
            if (size > 0 && size <= 64) {
                ptrdiff_t offset = ivar_getOffset(ivar);
                memcpy((uint8_t *)(__bridge void *)clone + offset,
                       (const uint8_t *)(__bridge const void *)source + offset, size);
            }
        }
    }
    return clone;
}

static BOOL ZyncRetitleCellObject(id object, NSString *newTitle, NSString **outOldValue) {
    if (!object) return NO;
    NSArray<NSString *> *known = ZyncKnownAccountTitleValues();
    Class cls = object_getClass(object);
    BOOL done = NO;
    for (NSValue *boxed in ZyncAllIvars(cls)) {
        if (done) break;
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;
        id value = nil;
        @try { value = object_getIvar(object, ivar); } @catch (__unused NSException *e) { continue; }
        if (![value isKindOfClass:[NSString class]]) continue;
        if ([known containsObject:value]) {
            if (outOldValue) *outOldValue = value;
            @try { ZyncSetIvarRetained(object, ivar, newTitle); } @catch (__unused NSException *e) { continue; }
            done = YES;
        }
    }

    if (!done) {
        for (NSString *key in @[@"title", @"name", @"text", @"cellTitle", @"localizedTitle"]) {
            @try {
                id value = [object valueForKey:key];
                if ([value isKindOfClass:[NSString class]] &&
                    ([ZyncKnownAccountTitleValues() containsObject:value] || [value containsString:@"account_security"])) {
                    [object setValue:newTitle forKey:key];
                    done = YES;
                    break;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return done;
}

#pragma mark - Model discovery

@interface ZyncBFSNode : NSObject
@property (nonatomic, strong) id node;
@property (nonatomic, strong) id parent;
@property (nonatomic, strong) ZyncBFSNode *parentEntry;
@property (nonatomic, assign) NSUInteger indexInParent;
@property (nonatomic, strong) id keyInParent;
@property (nonatomic, assign) Ivar parentIvar;
@end

@implementation ZyncBFSNode
@end

static BOOL ZyncSkipTraversalClass(id node) {
    return [node isKindOfClass:[NSString class]] || [node isKindOfClass:[NSNumber class]] ||
           [node isKindOfClass:[NSData class]] || [node isKindOfClass:[NSDate class]] ||
           [node isKindOfClass:[NSURL class]] || [node isKindOfClass:[NSSet class]] ||
           [node isKindOfClass:[NSValue class]] || [node isKindOfClass:[NSNull class]] ||
           [node isKindOfClass:[UIView class]] || [node isKindOfClass:[UIViewController class]];
}

static NSMutableArray<ZyncBFSNode *> *ZyncCollectCandidates(id root, NSUInteger maxDepth) {
    NSMutableArray<ZyncBFSNode *> *all = [NSMutableArray array];
    NSMutableArray<ZyncBFSNode *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    ZyncBFSNode *rootNode = [ZyncBFSNode new];
    rootNode.node = root;
    [queue addObject:rootNode];

    NSUInteger depth = 0;
    while (queue.count > 0 && depth < maxDepth && all.count < kZyncMaxBFNodes) {
        NSMutableArray<ZyncBFSNode *> *next = [NSMutableArray array];
        for (ZyncBFSNode *entry in queue) {
            id node = entry.node;
            if (!node || ZyncSkipTraversalClass(node)) continue;
            NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)node];
            if ([seen containsObject:ptr]) continue;
            [seen addObject:ptr];
            [all addObject:entry];

            if ([node isKindOfClass:[NSArray class]]) {
                NSArray *array = node;
                for (NSUInteger i = 0; i < array.count; i++) {
                    id child = array[i];
                    if (!child || ZyncSkipTraversalClass(child)) continue;
                    ZyncBFSNode *n = [ZyncBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.indexInParent = i;
                    [next addObject:n];
                }
            } else if ([node isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = node;
                for (id key in dict) {
                    id child = dict[key];
                    if (!child || ZyncSkipTraversalClass(child)) continue;
                    ZyncBFSNode *n = [ZyncBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.keyInParent = key;
                    [next addObject:n];
                }
            } else {
                for (NSValue *boxed in ZyncAllIvars(object_getClass(node))) {
                    Ivar ivar = (Ivar)boxed.pointerValue;
                    const char *type = ivar_getTypeEncoding(ivar);
                    if (!type || type[0] != '@') continue;
                    id child = nil;
                    @try { child = object_getIvar(node, ivar); } @catch (__unused NSException *e) { continue; }
                    if (!child || ZyncSkipTraversalClass(child)) continue;
                    ZyncBFSNode *n = [ZyncBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.parentIvar = ivar;
                    [next addObject:n];
                }
            }
        }
        [queue setArray:next];
        depth++;
    }
    return all;
}

// Places `value` into the slot that currently holds `child.node` (parent object
// via ivar, or parent collection via index/key). Returns NO when the parent is
// an immutable collection (caller must climb one level and retry with a copy).
static BOOL ZyncPlaceValue(id value, ZyncBFSNode *child) {
    id parent = child.parent;
    @try {
        if ([parent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)parent replaceObjectAtIndex:child.indexInParent withObject:value];
            return YES;
        }
        if ([parent isKindOfClass:[NSMutableDictionary class]]) {
            [(NSMutableDictionary *)parent setObject:value forKey:child.keyInParent];
            return YES;
        }
        if (child.parentIvar != NULL) {
            ZyncSetIvarRetained(parent, child.parentIvar, value);
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// Walks up from the matched array, converting every immutable ancestor
// (array/dictionary) into a mutable copy that is re-linked into its own parent,
// so the returned NSMutableArray is reachable from the live object graph.
static NSMutableArray *ZyncMakeMutableChain(ZyncBFSNode *match) {
    id node = match.node;
    if (![node isKindOfClass:[NSArray class]]) return nil;

    id value = [node isKindOfClass:[NSMutableArray class]] ? node : [node mutableCopy];
    if (![value isKindOfClass:[NSMutableArray class]]) return nil;

    ZyncBFSNode *child = match;
    while (child) {
        if (ZyncPlaceValue(value, child)) return (NSMutableArray *)value;

        id parent = child.parent;
        if (![parent isKindOfClass:[NSArray class]] && ![parent isKindOfClass:[NSDictionary class]]) return nil;
        id newParent = [parent mutableCopy];
        if (!newParent) return nil;
        if ([newParent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)newParent replaceObjectAtIndex:child.indexInParent withObject:value];
        } else if ([newParent isKindOfClass:[NSMutableDictionary class]] && child.keyInParent) {
            [(NSMutableDictionary *)newParent setObject:value forKey:child.keyInParent];
        } else {
            return nil;
        }
        value = newParent;
        child = child.parentEntry;
    }
    return nil;
}

static NSMutableArray *ZyncFindContainerForObject(id root, id target, NSUInteger *outIndex) {
    NSMutableArray<ZyncBFSNode *> *nodes = ZyncCollectCandidates(root, 7);
    for (ZyncBFSNode *entry in nodes) {
        id node = entry.node;
        if (![node isKindOfClass:[NSArray class]]) continue;
        if ([node indexOfObjectIdenticalTo:target] == NSNotFound) continue;

        NSMutableArray *container = ZyncMakeMutableChain(entry);
        if (!container) continue;
        if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
        ZYNC_LOG(@"ensure: container found via ivar graph");
        return container;
    }

    // Stage 2: arranged content may come from a getter (getArrangedTableContent),
    // not a stored ivar. Only mutate when a containing array is reachable and
    // mutable-ized via the existing chain logic — a throwaway copy is ignored.
    SEL arrangedSel = sel_registerName("getArrangedTableContent");
    if (root && [root respondsToSelector:arrangedSel]) {
        id arranged = nil;
        @try { arranged = [root performSelector:arrangedSel]; } @catch (__unused NSException *e) {}
        if (arranged && arranged != root) {
            if ([arranged isKindOfClass:[NSMutableArray class]] &&
                [arranged indexOfObjectIdenticalTo:target] != NSNotFound) {
                if (outIndex) *outIndex = [arranged indexOfObjectIdenticalTo:target];
                ZYNC_LOG(@"ensure: container via getArrangedTableContent (mutable root)");
                return arranged;
            }
            NSMutableArray<ZyncBFSNode *> *subNodes = ZyncCollectCandidates(arranged, 4);
            for (ZyncBFSNode *entry in subNodes) {
                id node = entry.node;
                if (![node isKindOfClass:[NSArray class]]) continue;
                if ([node indexOfObjectIdenticalTo:target] == NSNotFound) continue;
                NSMutableArray *container = ZyncMakeMutableChain(entry);
                if (!container) continue;
                if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
                ZYNC_LOG(@"ensure: container via getArrangedTableContent");
                return container;
            }
            ZYNC_LOG(@"ensure: getArrangedTableContent reachable but no mutable container");
        }
    }
    ZYNC_LOG(@"ensure: container not found");
    return nil;
}

static id ZyncFetchAccountObject(id vc) {
    if (!vc) return nil;
    @try {
        id value = [vc valueForKey:@"accountAndSecurityObject"];
        if (value) return value;
    } @catch (__unused NSException *e) {}

    for (NSValue *boxed in ZyncAllIvars(object_getClass(vc))) {
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *name = ivar_getName(ivar);
        if (name && strcmp(name, "_accountAndSecurityObject") == 0) {
            id found = nil;
            @try { found = object_getIvar(vc, ivar); } @catch (__unused NSException *e) {}
            return found;
        }
    }
    return nil;
}

#pragma mark - Snapshot (for row mapping)

static void ZyncRefreshSnapshot(id vc) {
    NSMutableArray<NSArray *> *sections = [NSMutableArray array];
    NSMutableArray<ZyncBFSNode *> *nodes = ZyncCollectCandidates(vc, 7);
    for (ZyncBFSNode *entry in nodes) {
        id node = entry.node;
        if (![node isKindOfClass:[NSArray class]]) continue;
        NSArray *array = node;
        if (array.count == 0) continue;
        BOOL cellObjectLike = YES;
        for (id element in array) {
            if ([element isKindOfClass:[NSArray class]] || [element isKindOfClass:[NSDictionary class]]) { cellObjectLike = NO; break; }
            NSString *clsName = NSStringFromClass(object_getClass(element));
            if (!([clsName containsString:@"CellObject"] || [clsName containsString:@"Object"])) { cellObjectLike = NO; break; }
        }
        if (cellObjectLike) [sections addObject:array];
    }
    gSectionSnapshot = sections;

    gSnapshotAligned = NO;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        UITableView *tv = [(UITableViewController *)vc tableView];
        NSInteger sectionCount = [tv numberOfSections];
        if (sectionCount == (NSInteger)sections.count) {
            gSnapshotAligned = YES;
            for (NSInteger s = 0; s < sectionCount; s++) {
                if ([tv numberOfRowsInSection:s] != (NSInteger)sections[(NSUInteger)s].count) {
                    gSnapshotAligned = NO;
                    break;
                }
            }
        }
    }
}

#pragma mark - Injection

static BOOL ZyncInjectRow(id vc) {
    if (gOurRow) return YES;
    id accountObject = ZyncFetchAccountObject(vc);
    ZYNC_LOG(@"ensure: accountObject=%@",
             accountObject ? NSStringFromClass(object_getClass(accountObject)) : @"<nil>");
    if (!accountObject) return NO;

    NSUInteger accountIndex = 0;
    NSMutableArray *container = ZyncFindContainerForObject(vc, accountObject, &accountIndex);
    ZYNC_LOG(@"ensure: container=%@ count=%lu index=%lu",
             container ? NSStringFromClass(object_getClass(container)) : @"<nil>",
             (unsigned long)container.count, (unsigned long)accountIndex);
    if (!container) return NO;

    id clone = ZyncCloneCellObject(accountObject);
    ZYNC_LOG(@"ensure: clone=%@", clone ? NSStringFromClass(object_getClass(clone)) : @"<nil>");
    if (!clone) return NO;
    NSString *oldTitle = nil;
    if (!ZyncRetitleCellObject(clone, @"Zync Customize", &oldTitle)) {
        ZYNC_LOG(@"ensure: retitle failed (old=%@) — row not injected", oldTitle ? oldTitle : @"<nil>");
        return NO;
    }
    ZYNC_LOG(@"ensure: retitled %@ -> Zync Customize", oldTitle ? oldTitle : @"<unknown>");

    NSUInteger insertIndex = MIN(accountIndex, container.count);
    @try {
        [container insertObject:clone atIndex:insertIndex];
    } @catch (__unused NSException *e) {
        ZYNC_LOG(@"ensure: insert threw");
        return NO;
    }

    gOurRow = clone;
    ZyncRefreshSnapshot(vc);
    BOOL visibleInSnapshot = NO;
    if (gSectionSnapshot) {
        for (NSArray *array in gSectionSnapshot) {
            if ([array indexOfObjectIdenticalTo:gOurRow] != NSNotFound) { visibleInSnapshot = YES; break; }
        }
    }
    ZYNC_LOG(@"ensure: Zync Customize row injected at index %lu (visible-in-snapshot=%d)",
             (unsigned long)insertIndex, visibleInSnapshot);
    return YES;
}

static void ZyncReloadTable(id vc) {
    if (![NSThread isMainThread]) {
        __weak id weakVC = vc;
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncReloadTable(weakVC); });
        return;
    }
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    } else if ([vc isKindOfClass:[UIViewController class]]) {
        NSArray *subviews = [[(UIViewController *)vc view] subviews];
        for (UIView *view in subviews) {
            if ([view isKindOfClass:[UITableView class]]) { tv = (UITableView *)view; break; }
        }
    }
    if (tv) [tv reloadData];
}

static UITableView *ZyncTableViewForVC(id vc) {
    if (!vc) return nil;
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    } else if ([vc isKindOfClass:[UIViewController class]]) {
        NSArray *subviews = [[(UIViewController *)vc view] subviews];
        for (UIView *view in subviews) {
            if ([view isKindOfClass:[UITableView class]]) { tv = (UITableView *)view; break; }
        }
    }
    return tv;
}

static BOOL ZyncTableReady(id vc) {
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    }
    return tv != nil && [tv numberOfSections] > 0;
}

static void ZyncScheduleRetry(id vc) {
    if (gOurRow) return;
    NSNumber *doneNum = objc_getAssociatedObject(vc, &ZyncRetryCountKey);
    NSInteger tries = doneNum ? doneNum.integerValue : 0;
    if (tries >= 2) return;
    objc_setAssociatedObject(vc, &ZyncRetryCountKey, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSTimeInterval delay = tries == 0 ? 1.0 : 3.0;
    ZYNC_LOG(@"ensure: retry %ld in %.0fs", (long)(tries + 1), delay);
    __weak id weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakVC && !gOurRow) {
            @try { ZyncEnsureRow(weakVC); } @catch (__unused NSException *e) {}
        }
    });
}

#pragma mark - Overlay row (no dataSource mutation)

static const NSInteger kZyncOverlayTag = 0x5A7CE;

static void ZyncRemoveOverlay(UITableView *tv) {
    if (!tv) return;
    UIView *host = tv.superview ?: tv;
    while (UIView *old = [host viewWithTag:kZyncOverlayTag]) {
        [old removeFromSuperview];
    }
}

static BOOL ZyncTextMatchesAccount(NSString *text) {
    if (!text || text.length == 0) return NO;
    NSString *lower = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    lower = [lower lowercaseString];
    NSString *viTitle = [@"Tài khoản và bảo mật" lowercaseString];
    NSString *enTitle = [@"Account and security" lowercaseString];
    return [lower isEqualToString:viTitle] || [lower isEqualToString:enTitle];
}

static UILabel *ZyncFindFirstLabelRec(UIView *view) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) return (UILabel *)sub;
        UILabel *nested = ZyncFindFirstLabelRec(sub);
        if (nested) return nested;
    }
    return nil;
}

static NSString *ZyncCellText(UITableViewCell *cell) {
    if (!cell) return nil;
    if (cell.textLabel && cell.textLabel.text.length > 0) return cell.textLabel.text;
    UILabel *label = ZyncFindFirstLabelRec(cell);
    if (label && label.text.length > 0) return label.text;
    return nil;
}

static UITableViewCell *ZyncFindAccountCell(UITableView *tv) {
    if (!tv) return nil;
    for (UITableViewCell *cell in tv.visibleCells) {
        if (ZyncTextMatchesAccount(ZyncCellText(cell))) return cell;
    }
    return nil;
}

@interface ZyncOverlayControl : UIControl
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation ZyncOverlayControl

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.onTap) self.onTap();
}

@end

static UIView *ZyncBuildOverlayRow(UITableView *tv, UITableViewCell *accountCell, id vc) {
    CGFloat overlayHeight = accountCell ? accountCell.frame.size.height : 44.0;
    if (overlayHeight <= 0) overlayHeight = 44.0;
    UIView *overlay = [[UIView alloc] initWithFrame:CGRectMake(tv.bounds.origin.x,
                                                                CGRectGetMinY(accountCell.frame) - overlayHeight,
                                                                tv.bounds.size.width,
                                                                overlayHeight)];
    overlay.tag = kZyncOverlayTag;
    overlay.backgroundColor = accountCell.backgroundColor;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    overlay.userInteractionEnabled = YES;

    UILabel *sourceLabel = accountCell.textLabel ?: ZyncFindFirstLabelRec(accountCell);
    CGFloat inset = 16.0;
    if (sourceLabel && sourceLabel.frame.origin.x > 0) inset = sourceLabel.frame.origin.x;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(inset, 0, tv.bounds.size.width - inset * 2 - 30, overlayHeight)];
    title.text = @"Zync Customize";
    title.font = sourceLabel.font ?: [UIFont systemFontOfSize:17.0];
    title.textColor = [UIColor labelColor];
    title.backgroundColor = [UIColor clearColor];
    title.userInteractionEnabled = NO;
    [overlay addSubview:title];

    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(tv.bounds.size.width - inset - 20, 0, 20, overlayHeight)];
    chevron.text = @"›";
    chevron.font = [UIFont systemFontOfSize:17.0];
    chevron.textColor = [UIColor separatorColor];
    chevron.textAlignment = NSTextAlignmentRight;
    chevron.backgroundColor = [UIColor clearColor];
    chevron.userInteractionEnabled = NO;
    chevron.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [overlay addSubview:chevron];

    ZyncOverlayControl *control = [[ZyncOverlayControl alloc] initWithFrame:overlay.bounds];
    control.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    control.backgroundColor = [UIColor clearColor];
    __weak id weakVC = vc;
    __weak UITableView *weakTV = tv;
    control.onTap = ^{
        id host = weakVC;
        UITableView *table = weakTV;
        if (host && table) {
            UITableViewCell *cell = ZyncFindAccountCell(table);
            if (cell) {
                NSIndexPath *path = [table indexPathForCell:cell];
                if (path) [table deselectRowAtIndexPath:path animated:YES];
            }
        }
        if (host) [ZyncSettingsViewController pushFrom:host];
    };
    [overlay addSubview:control];
    return overlay;
}

static void ZyncPresentOverlayRow(id vc) {
    if (!vc) return;
    if (![NSThread isMainThread]) {
        __weak id weakVC = vc;
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncPresentOverlayRow(weakVC); });
        return;
    }
    UITableView *tv = ZyncTableViewForVC(vc);
    if (!tv) {
        ZYNC_LOG(@"ensure: overlay no tableView");
        return;
    }
    UITableViewCell *accountCell = ZyncFindAccountCell(tv);
    if (!accountCell) {
        ZYNC_LOG(@"ensure: overlay awaiting account cell");
        ZyncScheduleRetry(vc);
        return;
    }
    ZyncRemoveOverlay(tv);
    UIView *overlay = ZyncBuildOverlayRow(tv, accountCell, vc);
    [tv addSubview:overlay];
    [tv bringSubviewToFront:overlay];
    ZYNC_LOG(@"ensure: overlay row visible above account cell");
}

static void ZyncUpdateOverlay(id vc) {
    if (!vc) return;
    if (![NSThread isMainThread]) {
        __weak id weakVC = vc;
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncUpdateOverlay(weakVC); });
        return;
    }
    UITableView *tv = ZyncTableViewForVC(vc);
    if (!tv) return;
    UIView *host = tv.superview ?: tv;
    UIView *overlay = [host viewWithTag:kZyncOverlayTag];
    if (!overlay) return;
    UITableViewCell *accountCell = ZyncFindAccountCell(tv);
    if (!accountCell) {
        overlay.hidden = YES;
        ZYNC_LOG(@"ensure: overlay awaiting account cell");
        return;
    }
    CGFloat overlayHeight = accountCell.frame.size.height > 0 ? accountCell.frame.size.height : 44.0;
    overlay.hidden = NO;
    overlay.frame = CGRectMake(tv.bounds.origin.x, CGRectGetMinY(accountCell.frame) - overlayHeight,
                               tv.bounds.size.width, overlayHeight);
    ZYNC_LOG(@"ensure: overlay row visible above account cell");
}

static void ZyncEnsureRow(id vc) {
    if (!vc) return;
    if (gOurRow) {
        // Re-insert if the model was rebuilt without our row.
        BOOL stillPresent = NO;
        if (gSectionSnapshot) {
            for (NSArray *array in gSectionSnapshot) {
                if ([array indexOfObjectIdenticalTo:gOurRow] != NSNotFound) { stillPresent = YES; break; }
            }
        }
        if (!stillPresent) {
            gInjectAttempts++;
            id accountObject = ZyncFetchAccountObject(vc);
            NSUInteger idx = 0;
            NSMutableArray *container = accountObject ? ZyncFindContainerForObject(vc, accountObject, &idx) : nil;
            if (container) {
                if ([container indexOfObjectIdenticalTo:gOurRow] == NSNotFound) {
                    BOOL inserted = NO;
                    @try { [container insertObject:gOurRow atIndex:MIN(idx, container.count)]; inserted = YES; } @catch (__unused NSException *e) {}
                    ZYNC_LOG(@"ensure: re-inserted row=%d", inserted);
                    if (inserted) ZyncReloadTable(vc);
                }
            } else {
                ZYNC_LOG(@"ensure: model gone — clearing row for re-clone");
                gOurRow = nil; // model gone; re-clone next pass
            }
        }
        ZyncRefreshSnapshot(vc);
        if (!gOurRow) ZyncInjectRow(vc);
        return;
    }

    gInjectAttempts++;
    BOOL injected = NO;
    @try { injected = ZyncInjectRow(vc); } @catch (__unused NSException *e) { injected = NO; }
    if (injected) {
        // Per-VC retry count (associated object) resets on primary success;
        // the global attempt counter remains a backstop only and never gates
        // the overlay on its own (see below).
        objc_setAssociatedObject(vc, &ZyncRetryCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Primary row now owns visibility; drop any overlay left from an
        // earlier overlay-tier presentation so the row is not duplicated.
        ZyncRemoveOverlay(ZyncTableViewForVC(vc));
        ZyncReloadTable(vc);
    } else {
        NSNumber *doneNum = objc_getAssociatedObject(vc, &ZyncRetryCountKey);
        NSInteger tries = doneNum ? doneNum.integerValue : 0;
        UITableView *tableView = ZyncTableViewForVC(vc);
        BOOL hasTableView = tableView != nil;
        BOOL tableReady = ZyncTableReady(vc);
        ZYNC_LOG(@"ensure: primary inject failed (attempts=%lu perVCtries=%ld hasTableView=%d tableReady=%d)",
                 (unsigned long)gInjectAttempts, (long)tries, hasTableView, tableReady);
        // After retries, fall back to the overlay above the visible
        // "Account and security" cell instead of any dataSource mutation.
        if ((tries >= 1 && hasTableView) || tries >= 2 || gInjectAttempts >= 10) {
            ZYNC_LOG(@"ensure: primary exhausted after %lu attempts (perVCtries=%ld hasTableView=%d tableReady=%d) — presenting overlay",
                     (unsigned long)gInjectAttempts, (long)tries, hasTableView, tableReady);
            ZyncPresentOverlayRow(vc);
        } else {
            ZyncScheduleRetry(vc);
        }
    }
}

#pragma mark - Row selection

static BOOL ZyncHandleSelection(id vc, NSIndexPath *indexPath, UITableView *tv) {
    if (gOurRow) {
        id tapped = nil;
        if (gSnapshotAligned && indexPath.section < (NSInteger)gSectionSnapshot.count) {
            NSArray *section = gSectionSnapshot[(NSUInteger)indexPath.section];
            if (indexPath.row < (NSInteger)section.count) tapped = section[(NSUInteger)indexPath.row];
        }
        if (!tapped) {
            for (NSArray *section in gSectionSnapshot) {
                NSUInteger idx = [section indexOfObjectIdenticalTo:gOurRow];
                if (idx != NSNotFound && (NSInteger)idx == indexPath.row &&
                    [tv numberOfRowsInSection:indexPath.section] == (NSInteger)section.count) {
                    tapped = section[idx];
                    break;
                }
            }
        }
        if (tapped == gOurRow) {
            [ZyncSettingsViewController pushFrom:vc];
            [tv deselectRowAtIndexPath:indexPath animated:YES];
            return YES;
        }
        return NO;
    }

    return NO;
}

#pragma mark - Install

typedef void (*ZyncV0)(id, SEL);
typedef void (*ZyncV1Bool)(id, SEL, BOOL);
typedef void (*ZyncV2)(id, SEL, id, id);

void ZyncSettingsInstall(void) {
    gSettingsClass = NSClassFromString(@"SettingUI40TableViewController");
    BOOL settingsClassFound = gSettingsClass != Nil;
    ZYNC_LOG(@"settings hub class SettingUI40TableViewController found=%d (%@)",
             settingsClassFound, gSettingsClass ? NSStringFromClass(gSettingsClass) : @"<nil>");
    if (!gSettingsClass) {
        ZYNC_LOG(@"settings hub class not found — settings integration idle");
        return;
    }

    SEL viewDidLoadSel = sel_registerName("viewDidLoad");
    IMP viewDidLoadOrig = class_getMethodImplementation(gSettingsClass, viewDidLoadSel);
    BOOL okViewDidLoad = ZyncReplaceMethod(gSettingsClass, viewDidLoadSel, 0, "v", ^(id self) {
        ((ZyncV0)viewDidLoadOrig)(self, viewDidLoadSel);
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncEnsureRow(self); });
    });
    ZYNC_LOG(@"settings hook viewDidLoad validated=%d", okViewDidLoad);

    SEL willAppearSel = sel_registerName("viewWillAppear:");
    IMP willAppearOrig = class_getMethodImplementation(gSettingsClass, willAppearSel);
    BOOL okViewWillAppear = ZyncReplaceMethod(gSettingsClass, willAppearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZyncV1Bool)willAppearOrig)(self, willAppearSel, animated);
        ZyncEnsureRow(self);
    });
    ZYNC_LOG(@"settings hook viewWillAppear: validated=%d", okViewWillAppear);

    SEL didAppearSel = sel_registerName("viewDidAppear:");
    IMP didAppearOrig = class_getMethodImplementation(gSettingsClass, didAppearSel);
    BOOL okViewDidAppear = ZyncReplaceMethod(gSettingsClass, didAppearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZyncV1Bool)didAppearOrig)(self, didAppearSel, animated);
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncEnsureRow(self); });
    });
    ZYNC_LOG(@"settings hook viewDidAppear: validated=%d", okViewDidAppear);

    SEL updateTitleSel = sel_registerName("updateTitleObjects");
    BOOL okUpdateTitle = NO;
    if (ZyncClassHasInstanceMethod(gSettingsClass, updateTitleSel)) {
        IMP updateTitleOrig = class_getMethodImplementation(gSettingsClass, updateTitleSel);
        okUpdateTitle = ZyncReplaceMethod(gSettingsClass, updateTitleSel, 0, "v", ^(id self) {
            ((ZyncV0)updateTitleOrig)(self, updateTitleSel);
            dispatch_async(dispatch_get_main_queue(), ^{ ZyncEnsureRow(self); });
        });
    }
    ZYNC_LOG(@"settings hook updateTitleObjects validated=%d", okUpdateTitle);

    SEL layoutSel = sel_registerName("viewDidLayoutSubviews");
    IMP layoutOrig = class_getMethodImplementation(gSettingsClass, layoutSel);
    BOOL okLayout = ZyncReplaceMethod(gSettingsClass, layoutSel, 0, "v", ^(id self) {
        ((ZyncV0)layoutOrig)(self, layoutSel);
        ZyncUpdateOverlay(self);
    });
    ZYNC_LOG(@"settings hook viewDidLayoutSubviews validated=%d", okLayout);

    SEL didSelectSel = sel_registerName("tableView:didSelectRowAtIndexPath:");
    IMP didSelectOrig = class_getMethodImplementation(gSettingsClass, didSelectSel);
    BOOL okDidSelect = ZyncReplaceMethod(gSettingsClass, didSelectSel, 2, "v", ^(id self, UITableView *tv, NSIndexPath *indexPath) {
        if (ZyncHandleSelection(self, indexPath, tv)) return;
        ((ZyncV2)didSelectOrig)(self, didSelectSel, tv, indexPath);
    });
    ZYNC_LOG(@"settings hook didSelect validated=%d (tableView:didSelectRowAtIndexPath:)", okDidSelect);

    ZYNC_LOG(@"settings hooks summary viewDidAppear:=%d viewWillAppear:=%d updateTitleObjects=%d viewDidLayoutSubviews=%d didSelect=%d",
             okViewDidAppear, okViewWillAppear, okUpdateTitle, okLayout, okDidSelect);

    // Late install: Settings may already be on screen before hooks land.
    // Scan the key window once (main queue) so the visible instance still
    // gets an injection attempt — no polling loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
            if (window) break;
        }
        if (!window) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
        }
        UIViewController *root = window.rootViewController;
        if (!root || window == nil) return;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:root];
        id found = nil;
        while (stack.count > 0 && !found) {
            UIViewController *cursor = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (object_getClass(cursor) == gSettingsClass) { found = cursor; break; }
            [stack addObjectsFromArray:cursor.childViewControllers];
            if (cursor.presentedViewController) [stack addObject:cursor.presentedViewController];
            if ([cursor isKindOfClass:[UINavigationController class]]) {
                [stack addObjectsFromArray:[(UINavigationController *)cursor viewControllers]];
            }
        }
        if (found) {
            ZYNC_LOG(@"ensure: late install found visible settings screen — injecting");
            @try { ZyncEnsureRow(found); } @catch (__unused NSException *e) {}
        }
    });

    ZYNC_LOG(@"settings integration installed");
}
