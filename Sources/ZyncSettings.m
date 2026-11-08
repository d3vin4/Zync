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
// Fallback tier (only if the model cannot be reached): one extra row injected
// via numberOfRows/cellForRow interception using a Zalo cell class when it can
// be instantiated, otherwise a standard grouped cell.

#import "Zync.h"

#pragma mark - State

static id gOurRow = nil;
static NSArray<NSArray *> *gSectionSnapshot = nil;
static BOOL gSnapshotAligned = NO;
static BOOL gFallbackActive = NO;
static NSUInteger gInjectAttempts = 0;
static Class gSettingsClass = Nil;

static NSArray<NSString *> *ZyncKnownAccountTitleValues(void) {
    return @[@"Tài khoản và bảo mật",
             @"Account and security",
             @"00Zh8W",
             @"tabme.section_items.account_security.title",
             @"tabme_account_security"];
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

    if ([source respondsToSelector:@selector(copyWithZone:)]) {
        @try {
            id copy = [source copy];
            if (copy && object_getClass(copy) == cls) return copy;
        } @catch (__unused NSException *e) {}
    }

    id clone = nil;
    @try { clone = [[cls alloc] init]; } @catch (__unused NSException *e) { return nil; }
    if (!clone) return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];
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
    free(ivars);
    return clone;
}

static BOOL ZyncRetitleCellObject(id object, NSString *newTitle, NSString **outOldValue) {
    if (!object) return NO;
    NSArray<NSString *> *known = ZyncKnownAccountTitleValues();
    Class cls = object_getClass(object);
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    BOOL done = NO;
    for (unsigned int i = 0; i < count && !done; i++) {
        Ivar ivar = ivars[i];
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
    free(ivars);

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
           [node isKindOfClass:[NSValue class]] || [node isKindOfClass:[NSNull class]];
}

static NSMutableArray<ZyncBFSNode *> *ZyncCollectCandidates(id root, NSUInteger maxDepth) {
    NSMutableArray<ZyncBFSNode *> *all = [NSMutableArray array];
    NSMutableArray<ZyncBFSNode *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    ZyncBFSNode *rootNode = [ZyncBFSNode new];
    rootNode.node = root;
    [queue addObject:rootNode];

    NSUInteger depth = 0;
    while (queue.count > 0 && depth < maxDepth) {
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
                unsigned int count = 0;
                Ivar *ivars = class_copyIvarList(object_getClass(node), &count);
                for (unsigned int i = 0; i < count; i++) {
                    const char *type = ivar_getTypeEncoding(ivars[i]);
                    if (!type || type[0] != '@') continue;
                    id child = nil;
                    @try { child = object_getIvar(node, ivars[i]); } @catch (__unused NSException *e) { continue; }
                    if (!child || ZyncSkipTraversalClass(child)) continue;
                    ZyncBFSNode *n = [ZyncBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.parentIvar = ivars[i];
                    [next addObject:n];
                }
                free(ivars);
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
    NSMutableArray<ZyncBFSNode *> *nodes = ZyncCollectCandidates(root, 5);
    for (ZyncBFSNode *entry in nodes) {
        id node = entry.node;
        if (![node isKindOfClass:[NSArray class]]) continue;
        if ([node indexOfObjectIdenticalTo:target] == NSNotFound) continue;

        NSMutableArray *container = ZyncMakeMutableChain(entry);
        if (!container) continue;
        if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
        return container;
    }
    return nil;
}

static id ZyncFetchAccountObject(id vc) {
    @try {
        id value = [vc valueForKey:@"accountAndSecurityObject"];
        if (value) return value;
    } @catch (__unused NSException *e) {}

    Class cls = object_getClass(vc);
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    id found = nil;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (name && strcmp(name, "_accountAndSecurityObject") == 0) {
            @try { found = object_getIvar(vc, ivars[i]); } @catch (__unused NSException *e) {}
            break;
        }
    }
    free(ivars);
    return found;
}

#pragma mark - Snapshot (for row mapping)

static void ZyncRefreshSnapshot(id vc) {
    NSMutableArray<NSArray *> *sections = [NSMutableArray array];
    NSMutableArray<ZyncBFSNode *> *nodes = ZyncCollectCandidates(vc, 5);
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
    if (!accountObject) return NO;

    NSUInteger accountIndex = 0;
    NSMutableArray *container = ZyncFindContainerForObject(vc, accountObject, &accountIndex);
    if (!container) return NO;

    id clone = ZyncCloneCellObject(accountObject);
    if (!clone) return NO;
    if (!ZyncRetitleCellObject(clone, @"Zync Customize", NULL)) {
        ZYNC_LOG(@"row clone could not be retitled — falling back");
        return NO;
    }

    NSUInteger insertIndex = MIN(accountIndex, container.count);
    @try {
        [container insertObject:clone atIndex:insertIndex];
    } @catch (__unused NSException *e) { return NO; }

    gOurRow = clone;
    ZyncRefreshSnapshot(vc);
    ZYNC_LOG(@"Zync Customize row injected at index %lu", (unsigned long)insertIndex);
    return YES;
}

static void ZyncReloadTable(id vc) {
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    } else if ([vc isKindOfClass:[UIViewController class]]) {
        NSArray *subviews = [[(UIViewController *)vc view] subviews];
        for (UIView *view in subviews) {
            if ([view isKindOfClass:[UITableView class]]) { tv = (UITableView *)view; break; }
        }
    }
    [tv reloadData];
}

static BOOL ZyncTableReady(id vc) {
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    }
    return tv != nil && [tv numberOfSections] > 0;
}

static void ZyncEnsureRow(id vc) {
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
                NSUInteger insertIndex = MIN(idx, container.count);
                BOOL inserted = NO;
                @try { [container insertObject:gOurRow atIndex:insertIndex]; inserted = YES; } @catch (__unused NSException *e) {}
                if (inserted) dispatch_async(dispatch_get_main_queue(), ^{ ZyncReloadTable(vc); });
            } else {
                gOurRow = nil; // model gone; re-clone next pass
            }
        }
        ZyncRefreshSnapshot(vc);
        if (!gOurRow) ZyncInjectRow(vc);
        return;
    }

    gInjectAttempts++;
    if (ZyncInjectRow(vc)) {
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncReloadTable(vc); });
    } else if (gInjectAttempts >= 2 && ZyncTableReady(vc)) {
        gFallbackActive = YES;
        ZYNC_LOG(@"primary injection unavailable — fallback row active");
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncReloadTable(vc); });
    }
}

#pragma mark - Fallback cell

static UITableViewCell *ZyncBuildFallbackCell(UITableView *tv, NSIndexPath *indexPath) {
    NSString *reuse = @"ZyncCustomizeRow";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:reuse];
    if (cell) return cell;

    for (NSString *name in @[@"BasicSettingCell", @"BasicSettingCellV2"]) {
        Class cls = NSClassFromString(name);
        if (!cls || ![cls isSubclassOfClass:[UITableViewCell class]]) continue;
        @try {
            cell = [[cls alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        } @catch (__unused NSException *e) { cell = nil; }
        if (cell) break;
    }

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    cell.textLabel.text = @"Zync Customize";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
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

    if (gFallbackActive && indexPath.section == 0 && indexPath.row == 0) {
        [ZyncSettingsViewController pushFrom:vc];
        [tv deselectRowAtIndexPath:indexPath animated:YES];
        return YES;
    }
    return NO;
}

#pragma mark - Install

typedef void (*ZyncV0)(id, SEL);
typedef void (*ZyncV1Bool)(id, SEL, BOOL);
typedef void (*ZyncV2)(id, SEL, id, id);
typedef NSInteger (*ZyncQ2)(id, SEL, id, NSInteger);
typedef id (*ZyncObj2)(id, SEL, id, id);

void ZyncSettingsInstall(void) {
    gSettingsClass = NSClassFromString(@"SettingUI40TableViewController");
    if (!gSettingsClass) {
        ZYNC_LOG(@"settings hub class not found — settings integration idle");
        return;
    }

    SEL viewDidLoadSel = sel_registerName("viewDidLoad");
    IMP viewDidLoadOrig = class_getMethodImplementation(gSettingsClass, viewDidLoadSel);
    ZyncReplaceMethod(gSettingsClass, viewDidLoadSel, 0, "v", ^(id self) {
        ((ZyncV0)viewDidLoadOrig)(self, viewDidLoadSel);
        dispatch_async(dispatch_get_main_queue(), ^{ ZyncEnsureRow(self); });
    });

    SEL willAppearSel = sel_registerName("viewWillAppear:");
    IMP willAppearOrig = class_getMethodImplementation(gSettingsClass, willAppearSel);
    ZyncReplaceMethod(gSettingsClass, willAppearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZyncV1Bool)willAppearOrig)(self, willAppearSel, animated);
        ZyncEnsureRow(self);
    });

    SEL updateTitleSel = sel_registerName("updateTitleObjects");
    if (ZyncClassHasInstanceMethod(gSettingsClass, updateTitleSel)) {
        IMP updateTitleOrig = class_getMethodImplementation(gSettingsClass, updateTitleSel);
        ZyncReplaceMethod(gSettingsClass, updateTitleSel, 0, "v", ^(id self) {
            ((ZyncV0)updateTitleOrig)(self, updateTitleSel);
            dispatch_async(dispatch_get_main_queue(), ^{ ZyncEnsureRow(self); });
        });
    }

    SEL didSelectSel = sel_registerName("tableView:didSelectRowAtIndexPath:");
    IMP didSelectOrig = class_getMethodImplementation(gSettingsClass, didSelectSel);
    ZyncReplaceMethod(gSettingsClass, didSelectSel, 2, "v", ^(id self, UITableView *tv, NSIndexPath *indexPath) {
        if (ZyncHandleSelection(self, indexPath, tv)) return;
        NSIndexPath *forward = indexPath;
        if (gFallbackActive && !gOurRow && indexPath.section == 0 && indexPath.row > 0) {
            forward = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
        }
        ((ZyncV2)didSelectOrig)(self, didSelectSel, tv, forward);
    });

    SEL rowsSel = sel_registerName("tableView:numberOfRowsInSection:");
    if (ZyncClassHasInstanceMethod(gSettingsClass, rowsSel)) {
        IMP rowsOrig = class_getMethodImplementation(gSettingsClass, rowsSel);
        ZyncReplaceMethod(gSettingsClass, rowsSel, 2, "q", ^NSInteger(id self, UITableView *tv, NSInteger section) {
            NSInteger rows = ((ZyncQ2)rowsOrig)(self, rowsSel, tv, section);
            if (gFallbackActive && !gOurRow && section == 0) rows += 1;
            return rows;
        });
    }

    SEL cellSel = sel_registerName("tableView:cellForRowAtIndexPath:");
    if (ZyncClassHasInstanceMethod(gSettingsClass, cellSel)) {
        IMP cellOrig = class_getMethodImplementation(gSettingsClass, cellSel);
        ZyncReplaceMethod(gSettingsClass, cellSel, 2, "@", ^id(id self, UITableView *tv, NSIndexPath *indexPath) {
            if (gFallbackActive && !gOurRow && indexPath.section == 0) {
                if (indexPath.row == 0) return ZyncBuildFallbackCell(tv, indexPath);
                NSIndexPath *forward = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                return ((ZyncObj2)cellOrig)(self, cellSel, tv, forward);
            }
            return ((ZyncObj2)cellOrig)(self, cellSel, tv, indexPath);
        });
    }

    ZYNC_LOG(@"settings integration installed");
}
