# TGSpeicher 2.4 — native Telegram Drive for iOS

TGSpeicher is a native SwiftUI Telegram cloud-drive client for iPhone and iPad. Version 2.4 adds selectable Telegram channel backups, native Telegram photos and streamable videos, durable channel recovery and automatic chunked-document fallbacks while preserving the existing cloud-drive catalog.

## Highlights

- Native SwiftUI interface with Liquid Glass on iOS 26+ and a Material fallback on iOS 17–25.
- Direct Telegram login with phone code, QR login, 2FA and email verification through TDLib.
- Telegram **Saved Messages** as storage — no separate TGSpeicher backend required.
- Nested virtual folders, rename/move/delete, tags and a Telegram-synced recovery catalog.
- List + grid layouts, search by filename/tag, sorting by date/name/size and multi-selection.
- Durable multi-file upload queue that survives app restarts and serializes Telegram uploads safely.
- Restart-safe iCloud Photos backup with persistent Night Mode, automatic retry, stable upload IDs and duplicate-resistant queue recovery.
- Selectable private-channel destination with native Telegram photos, streamable videos and automatic document fallback for oversized or unsupported media.
- Square, lazy iCloud-style gallery tiles with bounded thumbnail memory and clean media layout.
- Native swipe-to-delete confirmation for files and empty folders plus rich long-press actions.
- Expanded icons and QuickLook-ready handling for audio, images, Office documents, archives, code and common file types.
- Remote URL import for direct HTTP/HTTPS downloads followed by upload to Telegram.
- Chunked uploads for large files, SHA-256 verification, reassembly and recovery after reinstall.
- QuickLook preview after download, Share Sheet export and Apple Files integration.
- Local Downloads browser and storage cleanup.
- Transfer status, connection state, Wi-Fi/cellular awareness, background task handoff and optional local completion notifications.
- Telegram proxy configuration (SOCKS5, HTTP and MTProto) stored with secrets in Keychain.
- iPhone + iPad support.

## Mobile-first scope

The upstream Telegram Drive project also has desktop/server-oriented features such as WebDAV/REST serving and continuous folder sync. iOS does not allow an ordinary sideloaded app to keep arbitrary server processes or filesystem watchers alive indefinitely in the background, so TGSpeicher 2.4 focuses on the mobile equivalents that work reliably under iOS lifecycle rules.

The iOS client is a clean native implementation. It does not embed a Tauri desktop runtime or copy the desktop UI into a WebView.

## Build an IPA

Every push to `main` runs `.github/workflows/build-ipa.yml` on a GitHub-hosted macOS runner. The workflow generates the Xcode project with XcodeGen, resolves TDLibFramework, builds a Release app for a generic iOS device with code signing disabled, packages `TGSpeicher-v2.4.0-unsigned.ipa`, and uploads it as an Actions artifact.

The artifact is intentionally **unsigned**. A sideload tool/signing service must sign it for your Apple ID or certificate before installation.

## Telegram API credentials

On first launch, enter the API ID and API hash created for your own Telegram application. TGSpeicher stores them locally in the iOS Keychain and connects directly to Telegram.

## Compatibility

- Deployment target: iOS 17+
- Liquid Glass enhancements: iOS 26+
- Devices: iPhone and iPad
- Storage engine: TDLib + Telegram Saved Messages for Drive, plus a selectable private channel for native Photo Backup media

Build target: TGSpeicher 2.4.0.
