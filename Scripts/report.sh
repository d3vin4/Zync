#!/bin/bash
# Zync — build metadata + implementation report + compatibility report.
set -euo pipefail

DYLIB="${1:-build/libZync.dylib}"
OUTDIR="${2:-build}"
VERSION="${ZYNC_VERSION:-build-8}"
TAG="${GITHUB_REF_NAME:-local}"
COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"

mkdir -p "$OUTDIR"

shasum -a 256 "$DYLIB" | awk '{print $1}' > "$OUTDIR/libZync.dylib.sha256"

nm -m "$DYLIB" > "$OUTDIR/libZync.nm.txt" 2>/dev/null || true
otool -L "$DYLIB" > "$OUTDIR/libZync.otool-L.txt" 2>/dev/null || true
file "$DYLIB" > "$OUTDIR/libZync.file.txt" 2>/dev/null || true

BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")

cat > "$OUTDIR/IMPLEMENTATION-REPORT.md" <<EOF
# Zync — Implementation Report

- Version: ${VERSION}
- Build: ${BUILD_DATE}
- Commit: ${COMMIT}
- Artifact: $(basename "$DYLIB") ($(stat -f%z "$DYLIB" 2>/dev/null || stat -c%s "$DYLIB") bytes)
- SHA-256: $(cat "$OUTDIR/libZync.dylib.sha256")
- Target: iOS 15.1+, arm64 — Zalo 26.11.01 (vn.com.vng.zingalo)

## Modules

| Module | Deliverable |
|---|---|
| ZyncCore | constructor boot, module isolation, logging |
| ZyncCompatibility | host identity + version gate + anchors |
| ZyncPreferences | persistent toggles (suite + settings App Group mirror) |
| ZyncHookEngine | runtime discovery, arity/encoding-validated replacement |
| ZyncURIFilter | tracking/ad endpoint blocking (NSURLProtocol) |
| ZyncPrivacy | typing suppression, seen/read-receipt control, Firebase collection off |
| ZyncAds | ad request blocking + ad view neutralization |
| ZyncFeatures | Profile Music restore, Google Drive backup bridge, More tab key |
| ZyncSettings | Zync Customize row (cloned native cell) + navigation |
| ZyncUI | dashboard: Appearance / Privacy / Ad Blocking / Feature Restoration / About |
| ZyncGlass | tab bar glass material overlay (REAL_GLASS / BLUR tier) |

## Exported interface

\`\`\`
$(nm -g "$DYLIB" 2>/dev/null | head -50 || echo "nm unavailable")
\`\`\`
EOF

cat > "$OUTDIR/COMPATIBILITY-REPORT.md" <<EOF
# Zync — Compatibility Report

- Host: Zalo 26.11.01 (vn.com.vng.zingalo), arm64, decrypted IPA build 261101802
- Deployment target: iOS 15.1 (host MinimumOSVersion)
- Runtime guards: every host class/selector is resolved via NSClassFromString /
  sel_registerName and validated (arity + return encoding) before use; missing
  anchors degrade to a logged no-op — no crash path.
- Liquid Glass: UIGlassEffect used only when present at runtime (iOS 26+);
  otherwise system blur material. The host opts out of the iOS 26 redesign
  (UIDesignRequiresCompatibility=YES), so system glass adoption would require
  repackaging — documented in docs/ARCHITECTURE.md.
- Not ported by design (no usable iOS mechanism / server-authoritative):
  ZCloud premium unlock, group admin/owner spoofing, chat-head overlay.
EOF

echo "reports written to $OUTDIR"
