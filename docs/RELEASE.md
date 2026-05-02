# Release Workflow

Manual process for v1.3+. Automate later.

## One-time setup (before first release)

1. Install Sparkle's command-line tools (they're bundled with the SPM package
   at `~/Library/Developer/Xcode/DerivedData/P2toMXF-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`).
2. Run `generate_keys` — saves the EdDSA private key in your login Keychain and
   prints the public key. Copy the public key into `01_Project/P2toMXF/Info.plist`
   under `SUPublicEDKey`.
3. Verify by building and opening the app; Sparkle should no longer warn about
   the missing public key.

## Per-release steps

1. Bump version in Xcode (both Marketing Version and Build Number).
2. Update `docs/PROJECT_STATE.md` Quick Facts → version.
3. Clean build: kill running app, `xcodebuild clean -scheme P2toMXF`, delete
   DerivedData, `xcodebuild -scheme P2toMXF build`.
4. Archive via Xcode → Distribute App → Developer ID / notarize via the existing
   signing pipeline.
5. Compress the notarized `.app` into a `.zip` (or keep as `.dmg` if preferred):
   ```bash
   cd 04_Exports/
   ditto -c -k --sequesterRsrc --keepParent "P2toMXF.app" "P2toMXF-1.X.zip"
   ```
6. Sign the archive:
   ```bash
   sign_update P2toMXF-1.X.zip
   ```
   (This prompts for Keychain access to the private key. Outputs EdDSA signature
   and file length.)
7. Run `generate_appcast` against the folder of archives — it reads all archives
   and regenerates `appcast.xml` with signatures:
   ```bash
   generate_appcast 04_Exports/ -o appcast.xml
   ```
   Or manually add the `<item>` entry to `appcast.xml` using the signature from
   step 6.
8. Tag: `git tag v1.X && git push origin v1.X`.
9. Draft a GitHub Release: attach the `.zip`/`.dmg`, body = changelog highlights.
10. Commit updated `appcast.xml` to `main` and push. Sparkle picks up the new
    entry on next user check.

## Verification

After pushing the new appcast:
- On a machine running the PREVIOUS version, launch the app, wait ~30s (or use
  "Check for Updates…" from the App menu).
- Confirm Sparkle shows the new version in the update dialog.
- Install; verify signature validates and app relaunches correctly.
