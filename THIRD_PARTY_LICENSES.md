# Third-party licenses

PhotoFlow contains **no third-party source code, libraries, fonts or machine-learning models.**

It uses only components that ship with macOS:

| Component | Provider | Notes |
|---|---|---|
| SwiftUI, AppKit, Foundation, Core Image, Core Graphics, ImageIO, Vision, Metal, Accelerate, CryptoKit, QuickLook, UniformTypeIdentifiers | Apple (macOS SDK) | System frameworks, used under the Xcode and Apple SDKs Agreement |
| On-device Vision models (image classification, face detection, horizon detection, saliency, feature prints, image registration, aesthetics scores) | Apple, part of macOS | Not bundled with PhotoFlow and never downloaded by it |
| SQLite (`libsqlite3`) | System library | Public domain (https://sqlite.org/copyright.html) |
| SF Symbols | Apple | Used through the system as permitted for apps on Apple platforms |

The app icon and the DMG background were created for PhotoFlow (`Scripts/make_icon.py`).
