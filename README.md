# DocSnap

A document scanner for iPhone: point the camera at paper, DocSnap finds the edges, flattens the page, cleans it up, and shares it as a PDF (AirDrop, Files, Mail, Print…). Android is planned.

Everything runs on the device: no account, no upload, no API key.

## Features

- **Scan** with the camera: live automatic border detection, auto-capture, multi-page (Apple VisionKit)
- **Import** photos with automatic border detection (Vision)
- **Crop** by dragging corners or edges, with a magnifier loupe, plus Auto Detect / Full Page
- **Filters**: Original, Magic Color, Grayscale, B&W, Lighten (shadow removal built in)
- **Edit**: rotate, reorder, delete, add pages
- **Text recognition (OCR)**, on-device, with copy/share
- **Export**: searchable PDF (Auto / A4 / Letter) or JPEG images, then share via AirDrop and the share sheet
- **Library**: search by title or recognized text, rename, delete

## Requirements

- Xcode 26+, iOS 17+ (built and tested for iPhone 13 Pro)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) when you change `project.yml`

## Getting started

```bash
git clone https://github.com/vinhhoangd/DocSnap.git
cd DocSnap
cp .env.example .env                                  # no keys needed today
cp Config/Local.xcconfig.example Config/Local.xcconfig # put your Apple Team ID here
xcodegen generate
open DocSnap.xcodeproj
```

### Run on your iPhone (free Apple ID)

1. Xcode → Settings → Accounts → add your Apple ID.
2. Put your Personal Team ID in `Config/Local.xcconfig` (or pick the team under Signing & Capabilities).
3. Plug in the iPhone, select it as the run destination, press **Run**.
4. On the iPhone: Settings → Privacy & Security → **Developer Mode** on; Settings → General → VPN & Device Management → trust your developer certificate.

Free-account installs expire after 7 days; just press Run again.

### Tests

```bash
./scripts/test.sh        # unit + UI tests on the iPhone 13 Pro simulator
./scripts/test.sh unit   # unit tests only
```

The simulator has no camera. Launch with `-uiTestingSampleData` to get a sample document.

## Project layout

```
DocSnap/
  App/        app entry, sample data (debug)
  Models/     Quad, ScanPage, ScanDocument, ScanFilter
  Services/   ImageProcessor (Core Image), DocumentDetector (Vision),
              TextRecognizer (OCR), PDFExporter, DocumentStore (files + JSON)
  Views/      Library, Document, Page viewer, Crop, Settings, camera/photos capture
DocSnapTests/    unit tests
DocSnapUITests/  UI tests
AGENT.MD         working agreement for AI agents (read first)
```
