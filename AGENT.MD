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

### Design system (2026-10-27 redesign)

- **Skills:**
  - The owner installed the Apple HIG skills (`.claude/skills/hig-*`) and `ui-ux-pro-max` (`.agents/skills/`). Use them for UI work.
  - They are committed to the repo at the owner's request (2026-10-27), so any machine gets them. They're third-party: no license files, and the HIG text is © Apple. `skills-lock.json` records their sources.
  - HIG project context lives in `.claude/apple-design-context.md`, which is committed.
- **Style:**
  - Minimal / Swiss: the paper is the hero. White page thumbnails get a hairline edge and a short soft shadow (`paperStyle()`).
  - Use system semantic colors and SF Pro text styles. No custom fonts.
- **Tokens:**
  - `DocSnap/Views/Theme.swift` holds spacing (4/8 rhythm), radii, the 44 pt minimum target, motion, `Haptics`, and the `.pressable` button style.
  - Accent "scan blue" lives in the asset catalog: #2563EB light, #3B82F6 dark, plus high-contrast variants. All are WCAG AA checked.
- **iOS 26:**
  - Liquid Glass (`.glass`, `.glassProminent`) only on controls (floating Scan/Import, the prominent toolbar Share), with `#available` fallbacks for iOS 17/18.
  - Never use glass in the content layer.
- **Accessibility:**
  - Respect Reduce Motion (`motion(_:value:reduceMotion:)`).
  - Cap badges and floating bars at large Dynamic Type sizes; the library grid goes to one column at accessibility sizes.
  - Hide decorative thumbnails from VoiceOver, and combine card labels.
- Before shipping UI, run the pre-delivery checklist in `.agents/skills/ui-ux-pro-max/references/pro-rules.md`.

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

- `~/Documents` is synced to **iCloud Drive**. Keep build output out of the project folder (`scripts/test.sh` uses `~/Library/Developer/Xcode/DerivedData/DocSnap-cli`). Delete any `… 2.xcodeproj`, `… 3.xcodeproj` (or other `… N`) conflict copies iCloud creates after `xcodegen generate`; never commit them. Before every commit run `git status --short | grep -E ' [0-9]+(\.|/|"|$)'` and expect no output.
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
- [x] Library grid/list views, date sections, sorting

Later (v0.2+):
- [x] Custom AVFoundation camera with live edge overlay, hold-steady auto-capture, flash
- [ ] Camera modes (ID card / book), grid overlay
- [x] AI Answer (Claude) for questions on a page, via the DocSnap server
- [x] Appearance setting (System/Light/Dark)
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

Done (session 1):
- Project created; v0.1 features in §8 implemented and pushed.
- Multi-agent pass: a bug hunter found 11 bugs (edit races, memory on big scans, cache size, mirrored crop, page-delete position, …) and all were fixed. A tester added regression tests and found one more bug (delete during edit), which is fixed too.
- `scripts/test.sh`: 52 unit + 12 UI tests, all green on the iPhone 13 Pro simulator (iOS 26.5). SwiftLint is clean.
- Small-issues pass:
  - The crop screen shows rotated pages upright, and drags map back to original-image space.
  - A zoomed page pans instead of swiping to the next page.
  - The crop screen uses a plain bottom bar, so the UIKit toolbar warning is gone (checked in simulator logs).
  - Added accessibility identifiers.
  - Fixed a found bug: after Rotate, a page turning landscape was drawn stale and overflowed until the next swipe (it now has a fixed full-size frame).
  - Crop is disabled while an edit is rendering.
- Verified: border detection on sample photos, filters, PDF embeds the JPEGs as-is (3-page PDF ≈ the JPEGs' total size), searchable OCR text, Vietnamese titles.

- **UI redesign (session 2, using the HIG + ui-ux-pro-max skills):**
  - Library: "Documents" with grid/list views, date sections (Today, Yesterday, Previous 7 Days, month), sort (modified, created, name), an empty state with actions, and a floating Scan + Import.
  - Document: paper cards, a page context menu (Rotate, Delete), a native bottom toolbar (Add Pages, prominent Share PDF), and "Share Images (JPEG)" in the … menu.
  - Page viewer: a refined edit bar and filter strip, plus a non-blocking "Applying…" pill.
  - Crop: new handle styling, with haptics on drag start and auto-detect.
  - Settings: iOS Settings-style rows.
  - Reviewed on the simulator in light, dark and largest Dynamic Type; 64/64 tests pass.

Not verified yet (needs the real phone):
- The VisionKit live camera (the simulator has no camera feed), AirDrop, real-paper detection quality, speed with 12 MP photos.

Known small issues / ideas:
- SwiftUI doesn't expose identifiers on alert text fields or the `.searchable` field; UI tests use `textFields.firstMatch` / `searchFields.firstMatch` there.
- Simulator tip: right after a relaunch, early taps can be dropped or queued, and the simulator panel's screenshots can lag. Use `xcrun simctl io <udid> screenshot` for a reliable frame.

- 2026-10-27:
  - Installed on the owner's iPhone 13 Pro (iOS 27.0.1), built with Xcode 27.1 and the free Personal Team.
  - Team ID, device UDID, server URL and app token are in the git-ignored `Config/Local.xcconfig`.
  - Reinstall (needed every 7 days with a free Apple ID, works over USB or the same Wi‑Fi): `scripts/deploy_phone.sh`

- 2026-10-28, session 3 (owner feedback: Apple's scanner captured too fast; wanted AI answers and an Appearance option):
  - **DocSnap Camera** is the new default; Apple Scanner is still selectable in Settings.
    - Code: `CameraController` + `ScannerView` + `StabilityTracker`.
    - Live outline with a hold-steady ring; captures after 1.5 s steady (1 s / 2 s / manual).
    - Full 12 MP photos; corners are re-detected on the photo, with the live corners as a fallback.
  - **Answer** button in the page viewer: `AnswerService` + `AnswerSheet`.
    - Streams Claude's answer from the DocSnap server (`server/api/answer.ts`, Vercel, @anthropic-ai/sdk).
    - Model `claude-opus-5-5`, adaptive thinking, effort high, `fallbacks: "default"`.
    - Answers are saved per page version.
    - Verified on the owner's linear-algebra homework photo: correct, about 11 s, about 4¢.
  - **Appearance** setting (System/Light/Dark), applied to every UIWindow.
  - Multi-agent pass:
    - The bug hunter found 12 issues and the tester found 5; all fixed.
    - The tester added 125 tests. Suites: 137 unit and 14 UI on iOS, 35 server (`cd server && npm test`). SwiftLint clean.
  - Detector rejects candidates with ≥3 corners on the frame edge: the segmentation model reports phantom strips on blank frames.
  - Secrets: `.env` holds ANTHROPIC_API_KEY and DOCSNAP_APP_TOKEN. `Config/Local.xcconfig` holds the Team ID, DOCSNAP_DEVICE_ID, DOCSNAP_APP_TOKEN and DOCSNAP_API_URL. Both are git-ignored; never print them.

Open items (blocked on the owner):
- **Server not deployed yet.**
  - The Vercel CLI is logged in, but its only scope is "adi-201" (ADI201), and the owner said not to use it.
  - The owner is creating a new Vercel team, **"DocScan 2026"**, for project `docsnap-api`.
- After the team exists:
  1. `cd server && vercel link --yes --project docsnap-api --scope <docscan-2026 slug>` and `vercel deploy --prod`.
  2. The owner adds ANTHROPIC_API_KEY and DOCSNAP_APP_TOKEN (values from `.env`) in Vercel → Project → Settings → Environment Variables (Production). Claude must not enter keys itself.
  3. Redeploy, then set `DOCSNAP_API_URL = https:/$()/<host>` in `Config/Local.xcconfig`.
  4. Verify `GET /api/answer` returns `configured: true`, then the homework photo through the live URL.
  5. Run `scripts/deploy_phone.sh`.
- Optional: connect the Vercel project to GitHub (root `server/`) so pushes redeploy it automatically.

Deploy routine after every commit: push, then `scripts/deploy_server.sh` (if server/ changed), then `scripts/deploy_phone.sh`. The phone script works over Wi‑Fi when the phone is unlocked on the same network.

Next up:
1. Owner tries the hold-steady camera and the Answer button on the iPhone and reports back.
2. Tune filters / detection from real-device feedback.
3. Start v0.2 items in §8 in order, starting with the custom camera.
