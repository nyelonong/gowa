# Gowa

A fast, light, beautiful HTTP client for macOS — native SwiftUI, with
collections stored as [OpenCollection](https://www.opencollection.com/) YAML
files you can keep in git.

## Features

- **Collections in git** — every collection is a single, spec-conformant
  OpenCollection YAML file. Open it, edit it, `git commit` it. Unknown spec
  sections survive round-trips untouched.
- **Nested folders** — organize requests in a tree inside the sidebar;
  create, rename, duplicate, delete via context menu.
- **Full request editor** — query/path params, headers with enable toggles,
  body editor (JSON/text/XML/form-urlencoded) with pretty-print, request
  settings (redirects, timeout).
- **Auth** — Basic, Bearer, API Key (header or query), none, inherit. Other
  spec auth types (OAuth2, AWS, digest…) are preserved exactly in the YAML.
- **Environments & variables** — `{{name}}` placeholders interpolate into
  URLs, params, headers, bodies, and auth from the active environment.
- **Secrets stay out of git** — mark a variable as Secret and its value is
  stored in the macOS Keychain; the collection file only ever contains the
  variable name. (Tip: keep credentials in secret variables and reference
  them as `{{token}}` in auth fields — never inline.)
- JSON response highlighting, native TextKit viewer, timing/size readout,
  request history (`⌘K` clears), `⌘↩` to send.

## Build

Requires Xcode with the Swift 6 toolchain and macOS 15+.

```sh
swift build              # debug
swift build -c release   # release
scripts/make-app.sh      # Gowa.app bundle (ad-hoc signed)
scripts/make-app.sh --open
```

## CLI

The same binary doubles as a headless collection runner for CI:

```sh
# from a release build
.build/release/gowa run ~/path/to/collection.yml --env Production

# or via the app bundle
Gowa.app/Contents/MacOS/gowa run collection.yml

# only requests whose name contains "Users"
gowa run collection.yml --filter Users
```

Runs every request top-to-bottom with `{{variables}}`, captures (chained
tokens flow between requests), and checks. Exit codes: `0` all passed,
`1` failures, `2` usage error — CI-friendly.

## Tests

```sh
swift test
```

## The git workflow

1. Pick a folder that is (or will be) a git repository.
2. `⌘S` saves the collection as `YourName.yml` there.
3. Review and commit with git as usual — diffs are plain YAML, keys sorted
   deterministically.
4. Reveal the file in Finder from the sidebar toolbar.

## Structure

| File | Role |
| --- | --- |
| `Sources/gowa/GowaApp.swift` | App entry, window, ⌘N/⌘O/⌘S commands |
| `Sources/gowa/ContentView.swift` | Split layout, environment switcher |
| `Sources/gowa/CollectionSidebar.swift` | Collection tree, context menus, rename flow |
| `Sources/gowa/RequestEditor.swift` | Tabbed request editor (params/headers/auth/body/settings) |
| `Sources/gowa/ResponseViews.swift` | Status capsule, headers list, copy |
| `Sources/gowa/AppState.swift` | Observable state, send pipeline (auth + interpolation) |
| `Sources/gowa/OpenCollection.swift` | OpenCollection YAML model — dictionary-first for lossless round-trips |
| `Sources/gowa/HTTPClient.swift` | Async URLSession engine |
| `Sources/gowa/JSONHighlighter.swift` | UTF-16 tokenizer → TextKit color runs |
| `Sources/gowa/BodyDisplay.swift` | Background-built response presentation |
| `Sources/gowa/CodeViewer.swift` | NSTextView-based body viewer |
| `Sources/gowa/HistoryStore.swift` | Persisted request history |
