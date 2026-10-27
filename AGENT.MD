# AGENT.MD — DocSnap working agreement

Read this whole file **every time you start or resume work**, before touching code.
It holds the requirements, the expectations, and where the last session stopped.

---

## 1. Resume protocol (do this first, every session)

1. Re-read this file top to bottom, especially **§2 Requirements** and **§9 Status / next steps**.
2. Run:
   ```bash
   cd /Users/HoangDucVinh/Documents/CamScanner
   git status
   git log --oneline -15
   git pull --ff-only
   ```
3. If `project.yml` changed, regenerate the Xcode project: `xcodegen generate`.
4. Build and run the tests (§6) before starting new work, so you know the baseline is green.
5. Continue from the first unchecked item in **§9**. Don't redo finished work.
6. Before stopping: update **§9**, then commit and push (§5).

## 2. Requirements (from the owner)

- An iPhone app that works like the CamScanner app on the App Store: use the iPhone camera to scan paper documents.
- Must work perfectly on the owner's **iPhone 13 Pro (128 GB)**.
- **Automatic border detection** (the edge outline is placed automatically), with manual corner adjustment.
- **Share through AirDrop** (and the rest of the iOS share sheet: Files, Mail, Messages, Save to Photos, Print).
- iPhone first; **Android later**.
- Use Git; **commit and push to GitHub every time work stops** at a milestone.
- **API keys stay private** in `.env` (git-ignored). Never commit secrets — the repo is **public**.
- Install/update the coding tools needed for the job.
- **Ask the owner** before creating any online account (Vercel, Docker, Apple Developer, Firebase, …), before spending money, and whenever a decision is genuinely theirs. The owner is the boss.
- Use multiple agents: some for testing, some for finding bugs, some for fixing bugs (§7).

## 3. Decisions already made (don't re-ask)

| Topic | Decision (2026-10-27) |
|---|---|
| App name | **DocSnap** (can't use "CamScanner" — trademark) |
| Bundle id | `com.vinhhoang.docsnap` (override in `Config/Local.xcconfig` if Apple says it's taken) |
| iOS stack | Native **Swift + SwiftUI**, iOS 17+, VisionKit document camera, Vision (edge detection + OCR), Core Image (perspective + filters), PDFKit/UIKit PDF |
| Android stack (later) | Native Kotlin + Jetpack Compose + Google ML Kit Document Scanner, in `android/` |
| Project generation | **XcodeGen** — `project.yml` is the source of truth; the generated `DocSnap.xcodeproj` is committed too so it opens directly |
| GitHub | Public repo `vinhhoangd/DocSnap`, branch `main` |
| Device install | **Free Apple ID** signing for now (app expires after 7 days → reinstall from Xcode). Paid account later only if the owner agrees |
| Backend | None. Everything (detection, OCR, PDF) runs **on device** — no API keys needed today |

The UI and branding must be DocSnap's own. Match CamScanner's *features*, not its logo, name, or artwork.

## 4. Secrets and signing

- `.env` holds any API keys; copy `.env.example` → `.env`. `.env` is git-ignored.
- An iOS binary can be unpacked, so a key compiled into the app is **not** secret. If a cloud API is ever needed, put the key on a server/proxy and have the app call that — ask the owner before creating that account.
- Personal signing settings live in `Config/Local.xcconfig` (git-ignored). Template: `Config/Local.xcconfig.example`.
- Before every push: `git diff --cached` must not contain keys, tokens, team IDs or passwords.

## 5. Git workflow

- Small, focused commits with clear messages. Push to `origin main` at every stopping point.
- Never commit: `.env`, `Config/Local.xcconfig`, `build/`, `DerivedData/`, `xcuserdata/`.
- If a push fails, fix the cause (don't force-push `main` without asking the owner).

## 6. Build, test, run

```bash
# regenerate project after editing project.yml
xcodegen generate

# build + unit/UI tests on the simulator
./scripts/test.sh

# lint
swiftlint
```

- The **simulator has no camera**; VisionKit scanning only works on a real iPhone. On the simulator, use "Import from Photos" or the UI-test sample data (`-uiTestingSampleData` launch argument).
- To install on the iPhone: open `DocSnap.xcodeproj` in Xcode → Settings → Accounts → add the Apple ID → select the DocSnap target → Signing & Capabilities → Team = your Personal Team → plug in the iPhone → Run. On the phone: Settings → General → VPN & Device Management → trust the developer. Developer Mode must be on (Settings → Privacy & Security → Developer Mode).

## 7. Multi-agent workflow

For every feature milestone:

1. **Builder** (main session) implements the feature.
2. **Tester agent** writes/extends XCTest unit + UI tests and runs `./scripts/test.sh`; reports failures with logs.
3. **Bug-hunter agent** reviews the diff read-only (crashes, memory with 12 MP images, threading, data loss, edge cases like 0 pages / huge docs / permission denied) and lists concrete bugs with file:line.
4. **Fixer agent** (or the builder) fixes each confirmed bug and adds a regression test.
5. Re-run tests; only a green build gets committed and pushed.

## 8. Feature checklist (CamScanner parity)

Core (v0.1):
- [x] Document library: list, search (title + OCR text), rename, delete, thumbnails
- [x] Scan with VisionKit camera: live auto border detection, auto-capture, multi-page
- [x] Import from Photos with automatic border detection (Vision)
- [x] Manual crop: draggable corners, magnifier loupe, auto-detect / full-page buttons
- [x] Perspective correction
- [x] Filters: Original, Magic Color, Grayscale, B&W, Lighten
- [x] Rotate pages, delete pages, reorder pages, add pages to existing document
- [x] OCR (Vision, on-device, auto language incl. Vietnamese where supported) with copy/share text
- [x] Export PDF (Auto / A4 / Letter) with invisible searchable text layer
- [x] Export JPEG images
- [x] Share sheet → AirDrop, Files, Mail, Print, Save to Photos
- [x] Settings: default filter, PDF page size, searchable PDF

Later (v0.2+):
- [ ] Custom AVFoundation camera (doc / ID card / book modes, flash, grid) with live edge overlay
- [ ] ID card mode (front + back on one page)
- [ ] Signature, watermark, annotation (PencilKit)
- [ ] Folders, tags, sort options
- [ ] PDF password protection, compression quality setting
- [ ] Batch merge / split documents
- [ ] iCloud sync
- [ ] Android app (`android/`)
- [ ] App Store release (needs paid Apple Developer account — ask owner)

## 9. Status / next steps (update before every stop)

**Last updated:** 2026-10-27

Done this session:
- Project created; core v0.1 features implemented (see §8); tests on simulator.

Next up:
1. Owner installs on iPhone 13 Pro (steps in §6) and reports how scanning, borders and AirDrop feel.
2. Tune filters / detection from real-device feedback.
3. Start v0.2 items in §8 in order, starting with the custom camera.
