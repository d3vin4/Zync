# Zync — Kiến trúc

## 1. Tổng quan

```
┌────────────────────────────────────────────────────────────────┐
│ ZyncCore (constructor +0.3s, main queue, mỗi module @try/catch)│
│                                                                │
│  ZyncURIFilter ── NSURLProtocol (tracking + ads rules)         │
│  ZyncPrivacy ──── typing / seen / read-receipt no-op hooks    │
│  ZyncAds ──────── ad view class disarming                     │
│  ZyncFeatures ─── Profile Music / GDrive bridge / More Tab     │
│  ZyncSettings ─── cell-object clone + navigation interception │
│  ZyncGlass ────── tab bar material overlay                    │
│                                                                │
│  ZyncPreferences ─ suite riêng + App Group mirror + restore    │
│  ZyncHookEngine ── runtime discovery + validated replacement   │
│  ZyncCompatibility ─ identity/version/anchors                  │
└────────────────────────────────────────────────────────────────┘
```

Một dylib duy nhất (`libZync.dylib`), không framework phụ, không Theos,
không substrate. Link: `UIKit`, `Foundation`, `QuartzCore` — tất cả system.

## 2. Triết lý hook

1. **Không địa chỉ cứng, không selector bịa.** Mọi ký hiệu nằm trong
   `Scripts/anchors.txt`, đối chiếu với binary bằng `anchors-verify.sh`.
2. **Discovery runtime, không đoán.** `ZyncEnumerateAppClasses` quét
   `objc_getClassList` lọc theo bundle `/Zalo.app/`; selector dùng chung
   (`sendSeenServer`, …) được hook ở mọi class trong app sở hữu nó.
3. **Validate trước khi thay.** `ZyncReplaceMethod` kiểm tra
   `method_getNumberOfArguments == declaredArgs + 2` và return encoding hợp lệ
   (`v` cho void, `Bc` cho BOOL). Sai → bỏ qua, log, không crash.
4. **Dedupe.** Mỗi cặp (class, selector) chỉ hook một lần.
5. **Fail-safe.** Thiếu anchor → module im lặng, app chạy như chưa cài.

## 3. Privacy — cơ chế

| Feature | Hook | Ghi chú |
|---|---|---|
| Hide typing | `sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:` | chỉ chiều gửi |
| Control seen | `sendSeenMessageWithChatEntity:`, `…TalkTableItem:`, `sendSeenMessages:messageDict:incomingData:`, `_sendSeenMessageWithSeenData:messageType:` | trạng thái local không đổi |
| Control read receipts | `sendSeenServer`, `sendSeenServerPARQueue`, `forceSendSeenServer`, `sendSeenLastMessageWithThreadIds:withMessageType:`, `sendSeenChatACK:withSubCommandType:`, `sendSeenGroupChatACKByData:withSubCommandType:`, `sendSeenCurrentUnreadFriendRequest:(retryTime:)sourceView:` | ACK + server flush |
| Tracking | NSURLProtocol: host `log.api.zaloapp.com`, path `/tracking*` (gồm `/tracking-v3`, `/tracking-rt`) | trả 204 rỗng |
| Firebase | `FIRAnalytics.setAnalyticsCollectionEnabled:NO`, `FIRPerformance.setDataCollectionEnabled:NO`, `FIRCrashlytics` collection off | API chính thức, respond-guarded |

Toggle đọc **mỗi lần gọi** (không cache cứng trong block) → bật/tắt có hiệu lực ngay.

## 4. Ads — hai tầng

- **Tầng request**: endpoint xác minh từ binary — `%@/zpads/inboxnative/getads`,
  `/v1/user/core/get/ads`, `adsv2`, `ads_out_stream`, `ads_boost`,
  `/v1/ads/impression`, host `ads.platform.zalo.me`. Chặn ở NSURLProtocol, trả 204.
- **Tầng view**: class `UIView`-descendant trong Zalo.app có tên chứa
  `AdsView`/`AdsCell`/`AdsBanner`/`advert`/`promoted` (ví dụ thật:
  `ZInstantFeedAdsView`, `LocationOAAdsCell`) bị ghim `hidden` trong
  `didMoveToSuperview` và ép `YES` trong `setHidden:` khi toggle bật.

## 5. Settings — clone cell gốc

```
SettingUI40TableViewController   ← settings hub (owns accountAndSecurityObject)
viewDidLoad / viewWillAppear / updateTitleObjects  → ZyncEnsureRow
  1. accountObject = [vc valueForKey:@"accountAndSecurityObject"]
  2. container = BFS tìm NSMutableArray chứa accountObject (identity)
  3. clone = [accountObject copy] (fallback: alloc + ivar copy, retain đúng luật ARC)
  4. retitle: quét ivar NSString khớp {"Tài khoản và bảo mật", "00Zh8W",
     "tabme.section_items.account_security.title", …} → "Zync Customize"
  5. insert ngay trên account row, reload
tableView:didSelectRowAtIndexPath: → identity == gOurRow → push dashboard
```

Hệ quả: hàng Zync thừa hưởng **nguyên bản** chiều cao, padding, font, màu,
separator, disclosure, animation — vì nó là cùng một class cell object của Zalo,
chỉ khác title. Fallback (chỉ khi model không chạm được): chèn 1 row qua
`numberOfRows`/`cellForRow` với cell class `BasicSettingCell(V2)` nếu
instantiate được.

## 6. Liquid Glass — sự thật kỹ thuật

- API công khai cho glass là `UIGlassEffect` (iOS 26.0+) gắn vào `UIVisualEffectView`.
  `UITabBarController` **không có** setter glass công khai — system tab bar tự
  adopt khi process ở new-design mode.
- Zalo 26.11.01 build bằng SDK 26.2 nhưng đặt `UIDesignRequiresCompatibility=YES`
  → process chạy legacy UI → system tab bar không thành glass. Key đọc từ main
  bundle lúc launch và nằm trong code signature — **dylib không sửa được**.
- Zync vì vậy phủ overlay material trong bounds tab bar:
  - `REAL_GLASS`: `UIGlassEffect` nếu runtime có (iOS 26+), style `.regular`, tint nhẹ;
  - `BLUR`: `UIBlurEffect systemUltraThinMaterial` cho iOS cũ hơn.
- Overlay `userInteractionEnabled = NO`; hairline separator trên đỉnh; không đụng
  safe area, không đổi layout, không chặn điều hướng.
- Muốn *system* glass thật: xóa `UIDesignRequiresCompatibility` khỏi Info.plist
  + re-sign bundle (ngoài phạm vi dylib; pipeline inject/re-sign do người dùng).

## 7. Preferences

- Suite chính: `vn.com.vng.zingalo.zync`.
- Mirror: standard defaults + `group.zsettings.vn.com.vng.zingalo`
  (6 App Group của Zalo đã xác minh; `zsettings` là nhóm settings).
- `writeExternalValue:forKey:` lưu giá trị cũ (archive) trước khi ghi; tắt
  feature → `restoreExternalValueForKey:` trả lại đúng trạng thái người dùng.

## 8. Build & CI

```
macos-26 runner
  make → xcrun clang -dynamiclib -arch arm64 -miphoneos-version-min=15.1
  gates.sh: file / otool -L (không substrate) / install_name / LC_BUILD_VERSION
            minos 15.1 / nm chặn strong-undef _OBJC_CLASS_$_UIGlassEffect / codesign
  report.sh: SHA-256, nm, otool, IMPLEMENTATION-REPORT.md, COMPATIBILITY-REPORT.md
  tag v* → Pre-release (zip + dylib + sha + reports)
```

## 9. Rủi ro đã biết

| Rủi ro | Giảm thiểu |
|---|---|
| Selector đổi ở bản Zalo sau | anchors-verify + validate runtime; sai → no-op |
| Model settings đổi cấu trúc | clone thất bại → fallback row; vẫn chèn được |
| `UIGlassEffect` không render trong compat-mode process | overlay vẫn là blur hợp lệ; ghi rõ tier, không mạo nhận |
| `didMoveToSuperview` bị ad class ghi đè | setHidden: ghim song song, toggle off phục hồi ngay |
| Zalo jailbreak-detection (strings Cydia/Substrate có trong binary) | Zync không copy check nào; môi trường inject/re-sign do người dùng quyết định |
