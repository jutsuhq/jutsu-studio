# Mac App Store build

The `JutsuStudio-AppStore` target (project.yml) builds the same app for the Mac App Store. It differs from the
Developer ID build in four ways:

- No Sparkle. The App Store updates the app, so Software Update, its settings and its menu item are compiled out
  (`APP_STORE` in Swift), and the temporary sandbox exceptions Sparkle's installer needs are gone.
- A sandboxed `jutsu` helper (`jutsu-helper-appstore`). The App Store requires every executable in the bundle to be
  sandboxed. The helper's sandbox shares the app's group, whose container holds the agent socket.
- No links to buy credits or API balance outside the app (App Review 3.1.3(f), free stand-alone apps): the account
  plate's "Top up on higgsfield.ai" hint and the "Open Console" button on the balance alert are left out.
- `ITSAppUsesNonExemptEncryption` is false: the app uses only HTTPS and Apple's own encryption.

The bundle ID (`com.jutsustudio.JutsuStudio`) and the app group are the same as the Developer ID build's.

## Upload

1. In App Store Connect, create a macOS app with the bundle ID `com.jutsustudio.JutsuStudio`.
2. Archive and upload, signed by Xcode with the team's Apple Distribution certificate and a Mac App Store profile:

   ```bash
   xcodegen generate
   xcodebuild archive -project JutsuStudio.xcodeproj -scheme JutsuStudio-AppStore -configuration Release \
       -destination 'generic/platform=macOS' -archivePath build/JutsuStudio-AppStore.xcarchive \
       -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath build/JutsuStudio-AppStore.xcarchive \
       -exportOptionsPlist packaging/appstore/ExportOptions.plist -exportPath build/appstore \
       -allowProvisioningUpdates
   ```

3. Raise `CURRENT_PROJECT_VERSION` for every upload; App Store Connect refuses a build number it has seen.

## Review notes

- App Review signs in, so give it a Higgsfield account with credits in App Review Information.
- Say that the app is an unofficial client of Higgsfield's public API and OAuth sign-in, which Higgsfield's terms
  allow, and that it is not affiliated with Higgsfield (guidelines 5.2.1 and 5.2.2).
- The app makes AI images and videos from people's prompts, which the age rating questionnaire asks about.
- The privacy label: the app collects nothing. Prompts, uploads and results go only to Higgsfield, under the
  person's own account.
