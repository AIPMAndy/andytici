# Release Runbook — Andy题词

> **Maintainer-only document.** For *using* the app, see [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md). This file is the recipe for cutting a new release.

---

## TL;DR

```bash
# Bump version
$EDITOR Textream/build_no_xcode.sh   # VERSION + BUILD_NUM

# Build arm64 + universal
cd Textream
./build_no_xcode.sh                  # arm64-only smoke build
./build_no_xcode.sh --universal      # fat binary for distribution

# Package DMG
hdiutil create -format UDZO \
    -srcfolder build_universal/release/Andy题词.app \
    -volname "Andy题词 0.1.1" \
    /tmp/Andy题词_0.1.1_universal.dmg

# Verify
shasum -a 256 /tmp/Andy题词_0.1.1_universal.dmg
codesign --verify --verbose build_universal/release/Andy题词.app

# Tag + push + release
cd ..
git tag -a v0.1.1 -m "Andy题词 v0.1.1 — ..."
git push origin main --tags
gh release create v0.1.1 \
    /tmp/Andy题词_0.1.1_universal.dmg \
    --title "Andy题词 v0.1.1 — ..." \
    --notes-file release-notes.md
```

---

## Prerequisites

| Tool | Used for | How to install |
| --- | --- | --- |
| macOS 15.0+ host | All builds | (this Mac) |
| Command Line Tools | `swiftc`, `lipo`, `iconutil`, `sips`, `plutil`, `codesign` | `xcode-select --install` |
| `gh` CLI | GitHub Releases | `brew install gh` |
| `hdiutil` | DMG packaging | preinstalled on macOS |

**No Xcode required.** The entire build runs on the Command Line Tools subset. If a future contributor wants to use `xcodebuild` or the XCTest runner, they'll need full Xcode (see [Building from source](README.md#build-from-source) for the optional Xcode path).

---

## Version bumping

Two places to keep in sync:

| File | Field | Current |
| --- | --- | --- |
| `Textream/build_no_xcode.sh` | `VERSION` | `0.1.1` |
| `Textream/build_no_xcode.sh` | `BUILD_NUM` | `2` |
| `Textream/Info.plist` | `CFBundleShortVersionString` | (inherited from script) |
| `Textream/Info.plist` | `CFBundleVersion` | (inherited from script) |

`build_no_xcode.sh` writes these into the hand-assembled `Contents/Info.plist` at build time, so editing the script is enough.

---

## Local development build

```bash
cd Textream
./build_no_xcode.sh
open build/release/Andy题词.app
```

Output: arm64-only `.app`, ~5 MB, in `build/release/Andy题词.app`.

For tests, source code only — no XCTest runner:

```bash
# Static checks (read-only)
grep -rn "TODO\|FIXME\|print(" Textream/Textream --include="*.swift" | head
swiftc -parse -target arm64-apple-macos15.0 Textream/Textream/*.swift   # syntax-only
```

For a full XCTest run, the maintainer recommends opening `Textream.xcodeproj` in Xcode on a separate machine.

---

## Universal binary

```bash
cd Textream
rm -rf build_universal
./build_no_xcode.sh --universal
open build_universal/release/Andy题词.app
```

Output: arm64 + x86_64 fat `.app`, ~9 MB, in `build_universal/release/Andy题词.app`.

### Verify

```bash
file build_universal/release/Andy题词.app/Contents/MacOS/Andy题词
# → Mach-O universal binary [arm64:x86_64]

lipo -info build_universal/release/Andy题词.app/Contents/MacOS/Andy题词
# → Architectures in the fat file: x86_64 arm64

codesign --verify --verbose build_universal/release/Andy题词.app
# → valid on disk
# → satisfies its Designated Requirement

sips -g pixelWidth -g pixelHeight \
    build_universal/release/Andy题词.app/Contents/Resources/AppIcon.icns
# → should report an icon dimension (not "0 x 0")
```

---

## Package as DMG

```bash
hdiutil create -format UDZO \
    -srcfolder build_universal/release/Andy题词.app \
    -volname "Andy题词 0.1.1" \
    /tmp/Andy题词_0.1.1_universal.dmg

shasum -a 256 /tmp/Andy题词_0.1.1_universal.dmg
```

UDZO = zlib-compressed read-only. Volume name is what shows up when the user mounts the DMG.

---

## Release on GitHub

```bash
# Commit working-tree changes first
cd ..
git status
git add -A
git commit -m "feat(vX.Y.Z): ..."

# Annotated tag
git tag -a vX.Y.Z -m "Andy题词 vX.Y.Z — short description"
git push origin main --tags

# Release with notes (use a file for multi-line notes)
cat > /tmp/release-notes.md <<'EOF'
## Andy题词 vX.Y.Z

<one-line description>

### What's new
- ...

### How to install
1. Download `Andy题词_X.Y.Z_universal.dmg`
2. Drag to /Applications
3. First launch: right-click → Open to bypass Gatekeeper (ad-hoc signed)

### Known limitations
- Not Apple-notarized yet
- ...
EOF

gh release create vX.Y.Z \
    /tmp/Andy题词_X.Y.Z_universal.dmg \
    --title "Andy题词 vX.Y.Z — short title" \
    --notes-file /tmp/release-notes.md
```

### Known issue: GitHub CJK filename normalization

GitHub replaces non-ASCII characters in asset filenames with `.` (or strips them). The DMG `Andy题词_0.1.1_universal.dmg` will appear as `Andy._0.1.1_universal.dmg` in the release. **The content is intact** — sha256 matches the uploaded file. If this becomes a problem for downstream tooling (e.g. Homebrew Cask), rename the file before upload:

```bash
cp /tmp/Andy题词_0.1.1_universal.dmg /tmp/AndyTici_0.1.1_universal.dmg
gh release upload v0.1.1 /tmp/AndyTici_0.1.1_universal.dmg --clobber
```

---

## Homebrew Cask

The Cask formula lives at `Casks/andytici.rb`. Update after each release:

1. Bump `version` in the Cask
2. Recompute `sha256` from the actual DMG: `shasum -a 256 /tmp/Andy题词_0.1.1_universal.dmg`
3. Update `url` to the new release DMG
4. Test locally:

   ```bash
   brew tap-new andy/tici
   cp Casks/andytici.rb $(brew --repository andy/tici)/Casks/
   brew install --cask andy/tici/andytici
   brew audit --cask andy/tici/andytici
   ```

5. Submit a PR to `homebrew/homebrew-cask` (or maintain a personal tap)

> ⚠️ **Notarization prerequisite.** Homebrew won't accept casks with `on_release :no` indefinitely. Once Apple Developer ID is set up, add `livecheck`, notarize the DMG, and remove the `on_release :no` line.

---

## Verification checklist (post-release)

- [ ] DMG is downloadable from `https://github.com/AIPMAndy/andytici/releases/tag/vX.Y.Z`
- [ ] sha256 of downloaded DMG matches the value in the release notes
- [ ] `gh release view vX.Y.Z` shows the asset with the correct size
- [ ] Mounting the DMG on a clean machine shows the app icon correctly
- [ ] `codesign --verify` on the app inside the DMG passes
- [ ] First-launch right-click → Open workflow documented in release notes

---

## See also

- [README.md](README.md) — user-facing English README
- [README.zh-CN.md](README.zh-CN.md) — user-facing Chinese README
- [V0.1.1_RC2_ACCEPTANCE.md](V0.1.1_RC2_ACCEPTANCE.md) — last release's verification record
- [V0.1.1_RC2_HUMAN_ACCEPTANCE.md](V0.1.1_RC2_HUMAN_ACCEPTANCE.md) — last release's human acceptance runbook
- [build_no_xcode.sh](Textream/build_no_xcode.sh) — the build script itself