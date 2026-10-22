# Releasing PlexiChore (Mac + Android + Windows)

Checklist for publishing a new version as a GitHub Release. Written after v1.0.0 (2026-10-22,
https://github.com/pntapps/plexichore/releases/tag/v1.0.0 — Mac DMG + Android APK; published as a pre-release, then made a full release marked **Latest** the same day; the notes still call it a beta).
**Claude: follow this whenever a release, version bump, DMG, APK, notarization or signing comes up, and ask the
user before every outward-facing step** (notarization upload, commit, push, tag, release, flipping pre-release).

## 0. Ground rules
- Never commit or push until the user says so. Commit as `PNT Apps <pntapps.dev@gmail.com>`; push with
  `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main`.
- Never commit signing material or build output: keystores (`*.jks`, `*.keystore`), passwords, `.p12`, DMGs, APKs,
  `PlexiChore-Mac/build/`, `PlexiChore/app/release/` (Android Studio's signed-APK folder, git-ignored).
- Never read password files into the conversation. Pass them to tools by path (`keytool -storepass:file …`,
  `apksigner --ks-pass file:…`).
- The repo is public: release notes must state the known limits honestly (see §5).

## 1. Bump the versions (both apps, every release)
| App | Where | Rule |
|---|---|---|
| Mac | `PlexiChore-Mac/Resources/Info.plist` → `CFBundleShortVersionString` (e.g. 1.0.1) and `CFBundleVersion` (build number) | `CFBundleVersion` must increase every release. `build-app.sh` reads these (`VERSION=` / `BUILD_NUMBER=` only override the built copy). |
| Android | `PlexiChore/app/build.gradle.kts` → `versionCode` and `versionName` | **`versionCode` must be higher than the last release (v1.0.0 = 1)**, otherwise Android refuses to install it as an update. |
Use the same marketing version for both (tag `vX.Y.Z`). Commit the bump with the release changes.

## 2. Mac DMG (Developer ID + notarization)
One-time setup on a **new Mac** (the user does these; they involve their Apple account):
1. Developer ID certificate: Xcode → Settings → Accounts → team → Manage Certificates → + → *Developer ID
   Application* — or import the existing one exported as `.p12` from the old Mac. Check with
   `security find-identity -v -p codesigning` → must list `Developer ID Application: Md Imran Ansari (5ZKLJ5PZ6K)`.
2. Notary credentials in the keychain (user runs it; app-specific password from appleid.apple.com):
   `xcrun notarytool store-credentials plexichore-notary --apple-id "<apple id>" --team-id 5ZKLJ5PZ6K --password "<app-specific password>"`

Build (from `PlexiChore-Mac/`):
```bash
swift build && swift test
ID="Developer ID Application: Md Imran Ansari (5ZKLJ5PZ6K)"
SIGN_IDENTITY="$ID" UNIVERSAL=1 ./scripts/build-app.sh      # → build/PlexiChore.app (arm64 + x86_64, hardened runtime)
SIGN_IDENTITY="$ID" ./scripts/package-dmg.sh                 # → build/PlexiChore-<ver>.dmg
./scripts/notarize.sh build/PlexiChore-<ver>.dmg             # UPLOADS TO APPLE — ask the user first
```
- `notarize.sh` waits for Apple, staples, and runs `spctl`. Expect `accepted · source=Notarized Developer ID`.
  It currently prints a false warning "the DMG itself is not Developer ID signed" — `spctl` confirms it is (fix pending).
- If the script is interrupted after upload: `xcrun notarytool history --keychain-profile plexichore-notary`, then
  `xcrun stapler staple build/PlexiChore-<ver>.dmg` once it shows Accepted. No need to resubmit an accepted file.
- Every new build is a new file → it needs its own notarization.
- Smoke-test the built app on the real tablet before releasing (USB extend + Primary restore + ⌃⌥⌘D).

## 3. Android APK (release, signed with the registered key)
- Package `com.pntapps.plexichore` is registered and verified in Play Console → Android developer verification with
  key SHA-256 `4F:15:14:99:19:F2:6D:0D:27:C0:7D:FD:E2:F0:7B:FF:08:F4:2E:63:30:F2:21:71:58:7E:B7:D2:07:EE:26:89`.
- Keystore: `android-app-key.jks` (alias `releasekey`), kept by the user outside the repo (on the first Mac:
  `~/Downloads/Android App Developement Keys/`, with its password file). **Every release must be signed with this key**
  — a different key can't update installed copies and won't match the registration.
- Build: the user signs in Android Studio (Build → Generate Signed App Bundle / APK → APK → release); output goes to
  `PlexiChore/app/release/app-release.apk` (git-ignored). Signing is not configured in Gradle yet.
- Verify before publishing:
  ```bash
  BT=$(ls -d ~/Library/Android/sdk/build-tools/* | sort -V | tail -1)
  "$BT/apksigner" verify --print-certs PlexiChore/app/release/app-release.apk | grep SHA-256   # must be 4f15…2689
  "$BT/aapt2" dump badging PlexiChore/app/release/app-release.apk | head -1                    # versionCode/versionName
  ```
- **R8 / release-only crashes:** debug builds don't shrink. Always install the release APK on the tablet and open it
  (onboarding → Home → connect → stream) before publishing. v1.0.0's first release build crashed at launch
  (`IllegalAccessError`, R8 moved Kotlin facade classes) — fixed by `-keeppackagenames androidx.**,kotlin.**,kotlinx.**`
  in `app/src/main/keepRules/rules.keep`; keep it. Read crashes with `adb -s <serial> logcat -b crash`.
- Installing a release-signed APK over a debug build fails (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) — uninstalling
  wipes the app's settings, so ask the user first.

## 3b. Windows host (installer + portable exe)
First done for v1.1.0 (2026-10-22, pre-release, Windows only; Mac/Android stayed on v1.0.0).
- Version: `PlexiChore-Desktop/src/PlexiChore.App/PlexiChore.App.csproj` → `<Version>`. Keep the file without a BOM.
- Needs the .NET 10 SDK and Inno Setup 6 (`winget install Microsoft.DotNet.SDK.10`, `JRSoftware.InnoSetup`).
- Build **from the release commit** (the exe embeds it: ProductVersion `1.1.0+<sha>`):
  `taskkill /F /IM PlexiChore.exe` (if the dist exe runs), then `powershell -File PlexiChore-Desktop\publish.ps1 -Installer`
  → `dist\PlexiChore.exe` (~229 MB) + `dist\PlexiChoreSetup-<ver>.exe` (~60 MB; installs LICENSE.txt/NOTICE.txt).
- Publish as `PlexiChoreSetup-<ver>.exe` + `PlexiChore-Windows-<ver>-portable.exe` + `SHA256SUMS.txt`
  (PowerShell `Get-FileHash`, lowercase, `"<hash>  <name>"` lines with LF so `sha256sum -c` verifies).
- Not code-signed yet: the notes must tell users about SmartScreen (*More info → Run anyway*).
- Smoke test: run the dist exe, connect the tablet (Extend), check the log for CONFIG + hardware encoder.

## 3c. Website downloads
`website/` picks the newest file per platform from GitHub Releases **by file name** — keep the names exactly
`PlexiChoreSetup-<ver>.exe`, `PlexiChore-Windows-<ver>-portable.exe`, `PlexiChore-Mac-<ver>.dmg`,
`PlexiChore-Android-<ver>.apk`. No website change is needed for a new release (cache: 10 minutes).

## 4. CI
Push triggers `.github/workflows/{mac,android,windows}.yml` (path-filtered). Mac runs on `macos-15-intel` because
hosted arm64 runners were repeatedly unavailable. CI artifacts are ad-hoc/unsigned test builds (14 days) — never
publish those; releases use the notarized DMG and the key-signed APK. Wait for green CI on the release commit.

## 5. Publish the GitHub Release
```bash
R=<scratch dir>; cp PlexiChore-Mac/build/PlexiChore-<ver>.dmg $R/PlexiChore-Mac-<ver>.dmg
cp PlexiChore/app/release/app-release.apk $R/PlexiChore-Android-<ver>.apk
(cd $R && shasum -a 256 PlexiChore-Mac-<ver>.dmg PlexiChore-Android-<ver>.apk > SHA256SUMS.txt)
gh release create v<ver> --target $(git rev-parse HEAD) --title "PlexiChore <ver> — Mac + Android" \
  --notes-file $R/NOTES.md [--prerelease] $R/PlexiChore-Mac-<ver>.dmg $R/PlexiChore-Android-<ver>.apk $R/SHA256SUMS.txt
gh release download v<ver> -D <empty dir> && (cd <empty dir> && shasum -a 256 -c SHA256SUMS.txt)   # verify
```
- `--target` needs the **full** commit SHA (a short SHA fails with HTTP 422).
- Notes: start from the v1.0.0 notes (`gh release view v1.0.0`) — downloads table, Mac + Android install steps, USB
  needs USB debugging + adb, Wi-Fi pairing code, emergency key ⌃⌥⌘D, what changed, and **known limits**: the Wi-Fi
  stream is unencrypted (recommend USB / trusted networks), rotation/scale re-creates the display (~1 s blank),
  private macOS display API, what is still unverified, Windows SmartScreen (unsigned) and no-monitor limits.
- Ask the user whether to publish as a pre-release or a full release. Pre-releases are **not shown** in the repo
  home page's Releases box (it then shows only "1 tag") — only a full release marked Latest is, and
  `/releases/latest` points to it. Flip with `gh release edit v<ver> --prerelease=false --latest` (or back with
  `--prerelease`). It only changes the label; files and links stay the same.
- Afterwards: update `ROADMAP.md` and this file if anything about the process changed.
