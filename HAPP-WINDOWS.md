# FlClash Happ for Windows

This branch adds Happ JSON subscriptions and Xray routing to the FlClash Windows x64 build. It uses the upstream installer identity and the existing `%APPDATA%\com.follow\clash` data directory. Make a FlClash backup before the first in-place installation. Use one installation with this data directory at a time.

In **Profiles → Add → Happ / Xray**, paste the original HTTPS subscription link. This creates a separate profile and leaves existing Clash profiles and their scripts available. A registered device slot is required. If the service rejects the HWID, clear a device slot through the provider before retrying. The application keeps the last valid profile when a refresh is rejected.

The profile stores the provider's Xray routes, balancing and transport options in the normal profile file. Proxy traffic and the two-attempt GET delay check use the bundled Xray. The existing FlClash core owns the system proxy and TUN.

## Build and release

Use the Windows Flutter and Go versions pinned by the upstream build. Initialize the submodules over HTTPS, stage the pinned Xray distribution, and run the upstream packaging entry point:

```powershell
git -c 'url.https://github.com/.insteadOf=git@github.com:' submodule update --init --recursive
./tool/stage_happ_xray.ps1
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/features/happ/
$env:HAPP_RELEASE_REPOSITORY = 'OWNER/FlClash-Happ'
dart setup.dart windows --env stable --targets exe
```

The fork workflow checks for the newest stable upstream tag, applies the branch's changes relative to the recorded base, and tests the patched tree. A conflict or failed test blocks publication. Run the workflow manually without publishing to check the first installer. After verifying the release, set the repository variable `HAPP_AUTO_PUBLISH` to `true` to enable the scheduled release path.

The app downloads verified installers only from the build's configured repository. Automatic updates are downloaded in the background and staged for the next exit. Windows may request elevation. Before installing, the app saves a profile and settings archive under `update-backups` in the data directory. Verified fork installers it has downloaded are kept there as well. To roll back, run the previous installer and restore the matching archive from FlClash's backup settings if needed.
