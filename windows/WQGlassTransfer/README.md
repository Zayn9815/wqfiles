# WQGlass Transfer (Windows)

Native Windows 10/11 desktop companion for **WQ Glass** supporting full symmetric 3-way Wi-Fi LAN file transfers between **Windows PC**, **iPhone (iOS)**, and **Android**.

## Features
- **Client Mode (Connect to Device)**:
  - Auto-discovers nearby **iPhones (`🍎 iOS`)**, **Android devices (`🤖 Android`)**, and **Windows PCs (`💻 Windows`)** on the same Wi-Fi via UDP `45888`.
  - Drag & drop files or entire folders anywhere on the window to send at full Wi-Fi speed (256 KB streaming chunks).
  - Browse remote directories, download files/folders, create folders, rename, delete, search, and monitor live MB/s transfer speed.
- **Host Mode (Share This PC)**:
  - Share any folder on your Windows PC over Wi-Fi (TCP `8765`, zero administrator privileges required) so **iPhone**, **Android**, or any web browser can browse, **pull files directly from your PC**, or upload files to your PC.
  - Displays a 4–8 digit PIN, connection URL, scannable QR code, and live transfer activity log.

## Building Locally
```powershell
dotnet publish windows/WQGlassTransfer/WQGlassTransfer.csproj `
  -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true `
  -o windows/WQGlassTransfer/publish
```
Then compile the installer with Inno Setup 6:
```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows/WQGlassTransfer/installer.iss
```
