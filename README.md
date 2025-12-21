# Lotus IPTV

<p align="center">
  <img src="assets/icons/app_icon.png" width="120" alt="Lotus IPTV Logo">
</p>

<p align="center">
  <strong>A Modern IPTV Player for Windows, Android, and Android TV</strong>
</p>

<p align="center">
  <a href="https://github.com/shnulaa/FlutterIPTV/actions/workflows/build-release.yml">
    <img src="https://github.com/shnulaa/FlutterIPTV/actions/workflows/build-release.yml/badge.svg" alt="Build Status">
  </a>
  <a href="https://github.com/shnulaa/FlutterIPTV/releases">
    <img src="https://img.shields.io/github/v/release/shnulaa/FlutterIPTV?include_prereleases" alt="Latest Release">
  </a>
</p>

<p align="center">
  <strong>English</strong> | <a href="README_ZH.md">中文</a>
</p>

Lotus IPTV is a modern, high-performance IPTV player built with Flutter. Features a beautiful Lotus-themed UI with pink/purple gradient accents, optimized for seamless viewing across desktop, mobile, and TV platforms.

## ✨ Features

### 🎨 Lotus Theme UI
- Pure black background with lotus pink/purple gradient accents
- Glassmorphism style cards (desktop/mobile)
- TV-optimized interface with no animations for smooth performance
- Auto-collapsing sidebar navigation (expands on focus)

### 📺 Multi-Platform Support
- **Windows**: Desktop-optimized UI with keyboard shortcuts
- **Android Mobile**: Touch-friendly interface
- **Android TV**: Full D-Pad navigation with remote control support

### ⚡ High-Performance Playback
- **Desktop/Mobile**: Powered by `media_kit` with hardware acceleration
- **Android TV**: Native ExoPlayer (Media3) for 4K video playback
- Real-time video stats (resolution, FPS, codec info)
- Supports HLS (m3u8), MP4, MKV, and more

### 📂 Smart Playlist Management
- Import M3U playlists from local files or URLs
- QR code import for easy mobile-to-TV transfer
- Auto-grouping by `group-title`
- Channel availability testing with batch operations
- Move unavailable channels to separate category

### ❤️ User Features
- Favorites management (long-press on TV, button on mobile)
- Channel search
- Recommended channels with refresh
- Default channel logo for missing thumbnails

## 📸 Screenshots

<p align="center">
  <img src="assets/screenshots/home_screen.png" width="30%" alt="Home Screen">
  <img src="assets/screenshots/channels_screen.png" width="30%" alt="Channels Screen">
  <img src="assets/screenshots/player_screen.jpg" width="30%" alt="Player Screen">
</p>

## 🚀 Installation

Download from [Releases Page](https://github.com/shnulaa/FlutterIPTV/releases).

### Android / Android TV
```bash
# Install via ADB
adb install flutter_iptv-android-arm64-vX.X.X.apk
```

### Windows
1. Download and extract `flutter_iptv-windows-vX.X.X.zip`
2. Run `flutter_iptv.exe`

## 🎮 Controls

| Action | Keyboard | TV Remote |
|--------|----------|-----------|
| Play/Pause | Space/Enter | OK |
| Channel Up | ↑ | D-Pad Up |
| Channel Down | ↓ | D-Pad Down |
| Seek Forward | → | D-Pad Right |
| Seek Backward | ← | D-Pad Left |
| Favorite (TV) | - | Long Press OK |
| Mute | M | - |
| Back | Esc | Back |

## 🛠️ Development

### Prerequisites
- Flutter SDK (>=3.0.0)
- Android Studio (for Android/TV builds)
- Visual Studio (for Windows builds)

### Build
```bash
git clone https://github.com/shnulaa/FlutterIPTV.git
cd FlutterIPTV
flutter pub get

# Run
flutter run -d windows
flutter run -d <android_device>

# Build Release
flutter build windows
flutter build apk --release
```

## 🤝 Contributing

Pull requests are welcome!

## ⚠️ Disclaimer

This application is a player only and does not provide any content. Users must provide their own M3U playlists. Developers are not responsible for the content played through this application.
