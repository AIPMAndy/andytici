# Build / Release runbook for Andy题词

## Prerequisites
- macOS 13+
- Xcode 16+ (Swift 6+)
- `brew install gh create-dmg`

## Local build (development)
```bash
cd Textream
xcodebuild -project Textream.xcodeproj -scheme Textream -configuration Debug build
# Output: ~/Library/Developer/Xcode/DerivedData/Textream-*/Build/Products/Debug/Textream.app
open Textream.xcodeproj
```

## Run unit tests
```bash
xcodebuild -project Textream.xcodeproj -scheme Textream test
```

## Regenerate AppIcon
```bash
python3 scripts/generate_appicon.py
# requires: pip3 install pillow
```

## Tagged release
1. Bump version in `Textream/Textream.xcodeproj/project.pbxproj` (MARKETING_VERSION)
2. Update `Casks/andytici.rb` version + sha256
3. Build archive in Xcode → Distribute App → Developer ID
4. Create `.dmg` (rename exported .app to `Andy题词.app` first)
   ```bash
   create-dmg \
     --volname "Andy题词" \
     --window-pos 200 120 \
     --window-size 600 400 \
     --icon-size 128 \
     --icon "Andy题词.app" 175 190 \
     --app-drop-link 425 190 \
     --no-internet-enable \
     "Andy题词-#{VERSION}.dmg" \
     "Andy题词.app"
   ```
5. Compute sha256: `shasum -a 256 Andy题词-#{VERSION}.dmg`
6. Commit + push tag
7. Create GitHub release with DMG attached
8. Tap `andy/homebrew-andytici` (or submit to `homebrew-cask`):
   ```bash
   brew tap andy/andytici https://github.com/andy/homebrew-andytici
   brew install --cask andytici
   ```
