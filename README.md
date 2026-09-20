# Gowa

A fast, light, beautiful HTTP client for macOS. Native SwiftUI on Apple's
Metal-backed rendering stack — a ~2 MB binary with zero dependencies beyond
the OS.

## Features

- All common HTTP methods with custom request headers and bodies
- JSON response highlighting with pretty-print (sorted keys)
- Response headers viewer, body copy, color-coded status capsule
- Redirect control (raw 3xx responses when disabled)
- Request timing and humanized response size
- Persistent request history in a native sidebar (`⌘K` clears)
- `⌘↩` to send

## Build

Requires Xcode with the Swift 6 toolchain and macOS 15+.

```sh
swift build              # debug
swift build -c release   # release
scripts/make-app.sh      # Gowa.app bundle (ad-hoc signed)
scripts/make-app.sh --open
```

## Tests

```sh
swift test
```

## Structure

| File | Role |
| --- | --- |
| `Sources/gowa/GowaApp.swift` | App entry, window sizing |
| `Sources/gowa/ContentView.swift` | Sidebar, request editor, response views |
| `Sources/gowa/AppState.swift` | Observable app state, send lifecycle |
| `Sources/gowa/HTTPClient.swift` | Async URLSession engine, redirect policy, status phrases |
| `Sources/gowa/JSONHighlighter.swift` | AttributedString JSON tokenizer + pretty-print |
| `Sources/gowa/HistoryStore.swift` | Codable history persisted in Application Support |
