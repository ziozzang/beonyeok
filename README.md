# Beonyeok (번역)

A **DeepL API–compatible** HTTP server backed by Apple's on-device **Translation** framework, living in the menu bar.
Point any DeepL client at it with a custom server URL.

애플 온디바이스 번역을 DeepL 호환 API로 제공하는 메뉴바 앱.

```python
import deepl
t = deepl.Translator("any-key-or-yours", server_url="http://<mac-ip>:8989")
print(t.translate_text("Hello, world!", target_lang="KO").text)
```

- Endpoints: `POST|GET /v2/translate` (JSON or form; multiple `text`; `source_lang` optional → auto-detect;
  `tag_handling=xml|html`, `ignore_tags`, `show_billed_characters`), `/v2/usage`, `/v2/languages?type=source|target`,
  `/v3/languages`, empty glossary listings. `formality`/`context`/`glossary_id`/… are accepted and ignored.
- Auth: optional API keys → `Authorization: DeepL-Auth-Key <key>`; DeepL-style errors (400/403/404/413), CORS.
- Menu bar: start/stop, start on launch, launch at login, LAN (0.0.0.0) vs localhost, port, keys, stats.
- **Translation cache** (per line, SQLite + memory LRU): repeated lines return instantly.
- Language packs are downloaded from the Settings window. Apple processes one sentence at a time system-wide
  (~0.5 s/sentence); the server handles connections concurrently and the cache absorbs repeats.
- Headless: `Beonyeok.app/Contents/MacOS/Beonyeok --serve --port 8989 [--localhost] [--key KEY]`

## Install

1. Download `beonyeok_<version>_macos_arm64.zip` from [Releases](https://github.com/ziozzang/beonyeok/releases/latest) and unzip.
2. Move **Beonyeok.app** to `/Applications` (or `~/Applications`).
3. The app is ad-hoc signed (not notarized). On first launch either right-click → **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/Beonyeok.app`

Requirements: macOS 26 (Tahoe) or later, Apple Silicon.

## Updates

The app checks GitHub Releases once a day (and via **Check for Updates…**). Updates are verified against the
release's `SHA256SUMS`, installed in place and the app relaunches. Set `NO_UPDATE_CHECK=1` to disable.

## Build & release

```sh
./build.sh                         # → build/Beonyeok.app  (plain swiftc, no Xcode project)
scripts/release.sh 0.2.0 "notes"   # bump version, build, zip + SHA256SUMS, tag, push, GitHub release
```
Release assets follow the same scheme as [sugyeol](https://github.com/ziozzang/sugyeol):
`beonyeok_<version>_macos_arm64.zip` + `SHA256SUMS`.
