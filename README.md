# YouTube4Mac

Minimal native macOS YouTube wrapper built with SwiftUI and WebKit.

## Features

- Native macOS window
- Lightweight WebKit renderer instead of Electron
- Loads YouTube directly
- Dark appearance preference injection
- External popups opened outside the web view
- Back/forward swipe support

## Run

Build an app bundle:

```bash
./scripts/build_app.sh
```

Then open the generated app:

```bash
open dist/YouTube4Mac.app
```

## Optional SwiftPM build

If you prefer SwiftPM locally:

```bash
swift build
```
