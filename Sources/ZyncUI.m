// language: Objective-C, file: ZyncUI.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Zync Customize dashboard — grouped settings screen pushed onto the host
// navigation stack exactly like a native Zalo settings page.
// Sections: Appearance / Privacy / Ad Blocking / Feature Restoration / About Zync.
// Every feature has an independent switch; state persists in ZyncPreferences.

#import "Zync.h"

extern NSString *ZyncGlassMaterialDescription(void);

@interface ZyncSettingsViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *model;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *switches;
@end

@implementation ZyncSettingsViewController

+ (instancetype)make {
    ZyncSettingsViewController *vc = [[ZyncSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.title = @"Zync Customize";
    return vc;
}

+ (void)pushFrom:(UIViewController *)host {
    ZyncSettingsViewController *dash = [ZyncSettingsViewController make];
    UINavigationController *nav = host.navigationController;
    if (nav) {
        [nav pushViewController:dash animated:YES];
        return;
    }
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:dash];
    dash.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:dash
                                                      action:@selector(dismissSelf:)];
    wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:wrapper animated:YES completion:nil];
}

- (void)dismissSelf:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.switches = [NSMutableDictionary dictionary];
    [self buildModel];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48.0;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildModel];
    [self.tableView reloadData];
}

- (void)buildModel {
    NSArray *appearance = @[
        @{ @"title": @"Liquid Glass Tab Bar", @"subtitle": ZyncGlassMaterialDescription(),
           @"key": kZyncGlassTabBar, @"switch": @YES },
    ];
    NSArray *privacy = @[
        @{ @"title": @"Hide Typing Indicator", @"subtitle": @"Không gửi trạng thái đang nhập", @"key": kZyncHideTyping, @"switch": @YES },
        @{ @"title": @"Control Seen Status", @"subtitle": @"Không gửi thông báo đã xem tin nhắn", @"key": kZyncHideSeen, @"switch": @YES },
        @{ @"title": @"Control Read Receipts", @"subtitle": @"Không gửi biên nhận đã đọc lên máy chủ", @"key": kZyncHideReadReceipts, @"switch": @YES },
        @{ @"title": @"Disable Tracking & Analytics", @"subtitle": @"Chặn endpoint tracking của Zalo", @"key": kZyncBlockTracking, @"switch": @YES },
        @{ @"title": @"Disable Firebase Collection", @"subtitle": @"Tắt thu thập Firebase Analytics/Performance", @"key": kZyncBlockFirebase, @"switch": @YES },
    ];
    NSArray *ads = @[
        @{ @"title": @"Hide Ads", @"subtitle": @"Ẩn thành phần quảng cáo trong giao diện", @"key": kZyncHideAds, @"switch": @YES },
        @{ @"title": @"Block Ad Requests", @"subtitle": @"Chặn endpoint quảng cáo (zpads, ads api)", @"key": kZyncBlockAdRequests, @"switch": @YES },
    ];
    NSArray *features = @[
        @{ @"title": @"Profile Music", @"subtitle": @"Khôi phục nhạc trang cá nhân", @"key": kZyncRestoreProfileMusic, @"switch": @YES },
        @{ @"title": @"Google Drive Backup", @"subtitle": @"Khôi phục mục sao lưu Google Drive", @"key": kZyncRestoreGDrive, @"switch": @YES },
        @{ @"title": @"More Tab", @"subtitle": @"Khôi phục tab More (enable_tabmore)", @"key": kZyncRestoreMoreTab, @"switch": @YES },
    ];
    NSArray *about = @[
        @{ @"title": @"Version", @"value": [NSString stringWithFormat:@"%@ (%@)", ZYNC_VERSION, ZYNC_BUILD] },
        @{ @"title": @"Zalo", @"value": [ZyncCompatibility hostVersion] },
        @{ @"title": @"Settings anchor", @"value": [ZyncCompatibility anchorExists:@"SettingUI40TableViewController"] ? @"✔︎ SettingUI40TableViewController" : @"—" },
        @{ @"title": @"Tab bar anchor", @"value": [ZyncCompatibility anchorExists:@"ZaloTabBarViewController"] ? @"✔︎ ZaloTabBarViewController" : @"—" },
    ];

    self.model = @[
        @{ @"header": @"Appearance", @"rows": appearance },
        @{ @"header": @"Privacy", @"rows": privacy },
        @{ @"header": @"Ad Blocking", @"rows": ads },
        @{ @"header": @"Feature Restoration", @"rows": features },
        @{ @"header": @"About Zync", @"rows": about },
    ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.model.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self.model[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.model[(NSUInteger)section][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.model[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *key = row[@"key"];

    if (key) {
        static NSString *cellId = @"ZyncSwitchCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = self.switches[key];
        if (!sw) {
            sw = [[UISwitch alloc] init];
            objc_setAssociatedObject(sw, "zync.pref.key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            self.switches[key] = sw;
        }
        sw.on = [[ZyncPreferences shared] boolForKey:key];
        cell.accessoryView = sw;
        return cell;
    }

    static NSString *infoId = @"ZyncInfoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:infoId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:infoId];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"value"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "zync.pref.key");
    if (!key) return;
    [[ZyncPreferences shared] setBool:sw.on forKey:key];
    if ([key isEqualToString:kZyncGlassTabBar]) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                      withRowAnimation:UITableViewRowAnimationNone];
    }
}

@end
