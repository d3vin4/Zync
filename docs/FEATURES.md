# Zync — Danh sách tính năng & trạng thái triển khai

Mọi mục dưới đây đều **có code thực tế** chạy được, không phải UI giả.
Cột "Cơ chế" ghi đúng cách hoạt động; cột "Anchor" là bằng chứng trong binary
(đối chiếu bằng `Scripts/anchors-verify.sh`).

## A. Appearance

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Liquid Glass Tab Bar | ✅ Hoạt động | Overlay `UIVisualEffectView` trong bounds tab bar; `UIGlassEffect` khi runtime có (iOS 26+), fallback `systemUltraThinMaterial` | `ZaloTabBarViewController` |
| Toggle riêng + lưu cấu hình | ✅ | ZyncPreferences suite + App Group | — |
| Không đụng điều hướng/safe area | ✅ | `userInteractionEnabled=NO`, overlay nội bộ bar | — |

## B. Privacy

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Hide Typing Indicator | ✅ | no-op selector gửi typing khi bật | `sendStatusTyping:…` |
| Control Seen Status | ✅ | no-op 4 selector seen cấp tin nhắn | `sendSeenMessageWith…`, `sendSeenMessages:…`, `_sendSeenMessageWithSeenData:…` |
| Control Read Receipts | ✅ | no-op 7 selector ACK/server flush | `sendSeenServer`, `sendSeenChatACK:…`, `sendSeenGroupChatACKByData:…`, `forceSendSeenServer`, … |
| Disable Tracking & Analytics | ✅ | NSURLProtocol chặn `log.api.zaloapp.com`, `/tracking*`, `/tracking-v3` → 204 | strings 172689/173927/211876 |
| Disable Firebase Collection | ✅ | gọi API chính thức `setAnalyticsCollectionEnabled:NO`, `setDataCollectionEnabled:NO`, Crashlytics off (respond-guarded) | `FIRAnalytics`/`FIRPerformance`/`FIRCrashlytics` tại runtime |

Ghi chú trung thực: trạng thái đọc trên thiết bị vẫn được cập nhật — chỉ thông
báo ra bên ngoài bị chặn, nên hệ thống nhắn tin không bị phá vỡ.

## C. Ad Blocking

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Hide Ads (view) | ✅ | ghim `hidden` cho class view mang marker quảng cáo | `ZInstantFeedAdsView`, `LocationOAAdsCell` |
| Block Ad Requests | ✅ | NSURLProtocol chặn endpoint → 204 | `/zpads/`, `/get/ads`, `/ads_out_stream`, `/ads_boost`, `/v1/ads/`, `ads.platform.zalo.me` |
| Toggle độc lập + không phá layout | ✅ | chỉ ẩn view quảng cáo, không chạm nội dung khác | — |

## D. Feature Restoration

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Profile Music | ✅ | force getter `enableProfileMusic`/`…RBT`/`…Share`/`newFlag…`; mirror key `features@profile_music`, `kProfileMusicSetting`, `profile_music`, `enable_rbt`; force setter local | strings 162346/162347/285173 |
| Google Drive Backup | ✅ | mirror `restore_gdrive_photo_csc`; bridge section data `_basicBackupGDriveSectionZInstantData` ↔ `__basicBackupGDriveSectionZInstantData` khi migration trả nil | ZAGDrive* stack + migration strings |
| More Tab | ✅ | mirror `enable_tabmore` | strings |
| Hoàn tác sạch | ✅ | giá trị cũ được archive lại, tắt toggle → restore nguyên trạng | — |

## E. Zync Customize (tích hợp Settings)

| Tiêu chí | Trạng thái | Cách đạt |
|---|---|---|
| Vị trí trên "Tài khoản và bảo mật" | ✅ | chèn trước account row trong arranged content |
| Pixel-perfect: row/nav | ✅ | **clone cell object thật** (`BasicSettingCellV2Object`) — cùng height/padding/font/màu/separator/disclosure/animation |
| Điều hướng native | ✅ | push bằng navigation controller gốc |
| Fallback an toàn | ✅ | model không chạm được → chèn row qua dataSource interception |

## F. Không triển khai (lý do kỹ thuật — không giả lập)

| Mục | Lý do |
|---|---|
| Unlock ZCloud Premium | Entitlement server-authoritative; flip client không mở khoá thật, chỉ hiển thị sai |
| Fake admin/owner nhóm | Dữ liệu nhóm do server quyết định; rủi ro ban tài khoản |
| Chat head nổi | iOS không có API cửa sổ overlay cấp app |
| Anti-recall | Khả thi trên iOS (`chat.undo`/`chat.delete` có trong binary) nhưng không nằm trong danh sách yêu cầu |

## G. Kiểm thử

| Hạng mục | Cách kiểm |
|---|---|
| Anchors | `Scripts/anchors-verify.sh` → 49/49 |
| Artifact | `Scripts/gates.sh` trong CI (arm64, deps, install_name, minos, UIGlassEffect guard, codesign) |
| Runtime | Boot log `[Zync]`, dashboard About hiển thị anchor settings/tabbar; toggle từng feature độc lập |
| Persistence | Bật/tắt → kill app → mở lại, trạng thái giữ nguyên |
| Compatibility | `ZyncCompatibility` chặn bundle/version lạ; About hiển thị "supported/untested" |
