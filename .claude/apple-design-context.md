# Apple Design Context

## Product
- **Name**: DocSnap
- **Description**: On-device document scanner: capture paper with the camera, auto-detect edges, clean up, export searchable PDF, share via AirDrop.
- **Category**: Productivity / utility
- **Stage**: Development (v0.1, redesign pass 2026-10-27)

## Platforms
| Platform | Supported | Min OS | Notes |
|----------|-----------|--------|-------|
| iOS      | Yes       | 17.0   | iPhone only, portrait. Primary device: iPhone 13 Pro. Liquid Glass styles on iOS 26 with fallbacks |
| iPadOS   | No        |        | Possible later |
| macOS    | No        |        |       |
| tvOS     | No        |        |       |
| watchOS  | No        |        |       |
| visionOS | No        |        |       |

## Technology
- **UI Framework**: SwiftUI (UIKit wrappers for VisionKit camera and share sheet)
- **Architecture**: Single-window, NavigationStack (Library → Document → Page viewer; Crop as full-screen cover)
- **Apple Technologies**: VisionKit, Vision (rectangle/document segmentation, OCR), Core Image, PDFKit/UIGraphicsPDFRenderer, PhotosUI

## Design System
- **Base**: System semantic colors and materials + small token layer in `DocSnap/Views/Theme.swift`
- **Brand Colors**: Accent "scan blue" #2563EB (light) / #3B82F6 (dark), high-contrast #1D4ED8 / #5E9BFF (asset catalog `AccentColor`). App icon gradient #4573FF → #5433CC
- **Typography**: SF Pro via system text styles (no custom fonts)
- **Style**: Minimal / Swiss — content (the paper) first, white page thumbnails with hairline edge and soft short shadow, no decorative 3D
- **Dark Mode**: Supported (semantic colors; pages stay white like paper)
- **Dynamic Type**: Supported via text styles

## Accessibility
- **Target Level**: WCAG AA contrast; Apple baseline (VoiceOver labels, 44 pt targets, Reduce Motion respected)
- **Key Considerations**: Combined VoiceOver labels on document cards/page cells; haptics only complement visual feedback

## Users
- **Primary Persona**: Student/professional scanning receipts, homework, contracts on an iPhone
- **Key Use Cases**: Scan → share PDF via AirDrop; import photo → auto crop; OCR copy text (incl. Vietnamese)
- **Known Challenges**: Real-device camera and detection quality not yet verified on hardware
