# Zync — Zalo native customization (iOS)

Dylib độc lập cho **Zalo 26.11.01** (`vn.com.vng.zingalo`, arm64, iOS 15.1+):
tùy chỉnh giao diện, quyền riêng tư, chặn quảng cáo và khôi phục tính năng —
tích hợp theo phong cách native, không giao diện demo.

## Thành phần

| Module | Vai trò |
|---|---|
| ZyncCore | khởi tạo, cô lập từng module, logging |
| ZyncCompatibility | nhận diện host + version gate + anchors |
| ZyncPreferences | lưu cấu hình (suite riêng + mirror App Group `group.zsettings.vn.com.vng.zingalo`) |
| ZyncHookEngine | discovery runtime, thay method có kiểm chứng arity/encoding |
| ZyncURIFilter | chặn endpoint tracking/ad (NSURLProtocol) |
| ZyncPrivacy | ẩn typing, control seen/read receipts, tắt Firebase collection |
| ZyncAds | chặn request quảng cáo + vô hiệu hóa view quảng cáo |
| ZyncFeatures | khôi phục Profile Music, Google Drive Backup, More Tab |
| ZyncSettings | hàng "Zync Customize" (clone cell gốc) + điều hướng native |
| ZyncUI | dashboard: Appearance / Privacy / Ad Blocking / Feature Restoration / About |
| ZyncGlass | tab bar material (Liquid Glass khi runtime có `UIGlassEffect`, fallback blur hệ thống) |

## Tính năng

**Zync Customize** — hàng settings được clone từ cell object thật của Zalo
(`BasicSettingCellV2Object` của "Tài khoản và bảo mật", key `00Zh8W`), chèn ngay
phía trên "Tài khoản và bảo mật", điều hướng bằng navigation controller gốc.
Cao/padding/typography/separator/disclosure giống hệt vì dùng chính class gốc.

**Privacy** — hide typing indicator, control seen status, control read receipts,
disable tracking & analytics, disable Firebase collection. Chỉ chặn chiều *gửi*;
trạng thái đọc trên máy vẫn nguyên vẹn.

**Ad Blocking** — chặn endpoint đã xác minh trong binary (`/zpads/`, `/get/ads`,
`/ads_out_stream`, `/ads_boost`, `/v1/ads/`, `ads.platform.zalo.me`) + vô hiệu hóa
các view mang marker quảng cáo (`ZInstantFeedAdsView`, `LocationOAAdsCell`, …).

**Feature Restoration** — Profile Music (force getter `enableProfileMusic*` +
mirror key `features@profile_music`/`kProfileMusicSetting`), Google Drive Backup
(bridge `_basicBackupGDriveSectionZInstantData` ↔ `__basic…`), More Tab
(`enable_tabmore`).

**Liquid Glass** — overlay material nằm trong bounds của tab bar
(`ZaloTabBarViewController`), không chặn touch, không đổi safe area. Tier
`REAL_GLASS` khi runtime có `UIGlassEffect` (iOS 26+), tier `BLUR` dùng
`systemUltraThinMaterial`. Lưu ý: host đang bật `UIDesignRequiresCompatibility=YES`
nên *system* tab bar không thể adopt Liquid Glass từ trong process — xem
`docs/ARCHITECTURE.md`.

## Build

```bash
make          # → build/libZync.dylib (macOS + Xcode 26 SDK)
make gates    # kiểm tra artifact: arm64, deps, install_name, minos, UIGlassEffect, codesign
```

CI: GitHub Actions `macos-26`, đóng gói `Zync-<version>.zip` + SHA-256 + report,
publish Pre-release khi push tag `build-*` (hiện tại **Build 6** / `build-6`).

## Kiểm chứng anchors

Mọi selector/class/key/URL dùng trong code đều nằm trong
`Scripts/anchors.txt` và được đối chiếu ngược với binary:

```bash
ZYNC_IPA_DUMP=<dump-dir> ./Scripts/anchors-verify.sh
# → anchors: 49 verified, 0 missing
```

Dump dir cần: `objc_methname.txt`, `objc_classname.txt`, `zalo.strings`
(xem `docs/IPA-ANALYSIS.md` để biết cách tạo).

## Cài đặt

Dylib không chứa code ký/tiêm — inject bằng toolchain của bạn
(insert load command + re-sign bundle). `make gates` đảm bảo dylib sạch:
chỉ link system frameworks, install_name `@executable_path/Frameworks/libZync.dylib`.

## Không port (có lý do kỹ thuật)

- **Unlock ZCloud Premium** — quyền lợi do server quyết định; flip client chỉ là cosmetic và vi phạm thanh toán.
- **Fake admin/owner nhóm** — dữ liệu server-authoritative; chỉ gây hiển thị sai, có rủi ro ban.
- **Chat head nổi** — iOS không có API overlay cấp ứng dụng (ngoài PiP).

## License

MIT cho source của dự án. Ý tưởng tính năng tham khảo từ ZaloXposed (AGPL-3.0) —
**clean-room**: không sao chép code, không sao chép matcher/constant table.
