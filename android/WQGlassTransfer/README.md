# WQGlass Transfer (Android)

Native Kotlin + Jetpack Compose companion app for **WQ Glass** supporting symmetric 3-way Wi-Fi LAN file transfers between **Android**, **iPhone (iOS)**, and **Windows PC**.

## Features
- **Client Mode (Connect to Device)**:
  - Auto-discovers nearby **Windows PCs**, **iPhones**, and **Android devices** over UDP `45888`.
  - Connects via QR code scan or manual `IP:Port` + PIN.
  - Browse remote folders, pull/download files into `Downloads/WQGlass`, send multiple files at full Wi-Fi speed (256 KB streaming chunks), create folders, rename, and delete.
- **Host Mode (Share This Android Device)**:
  - Runs an embedded HTTP server (port `8765`) + UDP `45888` broadcaster inside an Android Foreground Service with Wi-Fi lock.
  - Share `Downloads` or full `Internal Storage` with Windows PC, iPhone, or any web browser.
  - Generates a PIN + scannable QR code (`http://<ip>:<port>/?pin=<pin>`) and displays a live transfer log.

## Building Locally
```bash
cd android/WQGlassTransfer
gradle test assembleRelease
```
The installable APK is written to `app/build/outputs/apk/release/app-release.apk`.
