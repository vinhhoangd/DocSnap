import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.defaultFilterKey) private var defaultFilter: ScanFilter = .magicColor
    @AppStorage(Settings.pdfPageSizeKey) private var pageSize: PDFPageSize = .auto
    @AppStorage(Settings.searchablePDFKey) private var searchablePDF = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Space.md) {
                        AppMark()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DocSnap").font(.title3.weight(.semibold))
                            Text("Scan, clean up and share documents.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Theme.Space.xxs)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Picker(selection: $defaultFilter) {
                        ForEach(ScanFilter.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        SettingLabel("Default Filter", systemImage: "camera.filters", color: .indigo)
                    }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Applied to new scans and imports. You can change it per page.")
                }

                Section {
                    Picker(selection: $pageSize) {
                        ForEach(PDFPageSize.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        SettingLabel("Page Size", systemImage: "doc.richtext", color: .blue)
                    }
                    Toggle(isOn: $searchablePDF) {
                        SettingLabel("Searchable PDF", systemImage: "text.magnifyingglass", color: .teal)
                    }
                } header: {
                    Text("PDF Export")
                } footer: {
                    Text("Searchable PDFs include an invisible text layer, so you can search and copy text in Files, Preview and other apps.")
                }

                Section {
                    LabeledContent {
                        Text(version)
                    } label: {
                        SettingLabel("Version", systemImage: "info", color: .gray)
                    }
                } footer: {
                    Label("Scanning, border detection and text recognition all run on your iPhone. Nothing is uploaded.",
                          systemImage: "lock.fill")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// iOS Settings-style row label: white symbol on a small colored rounded square.
private struct SettingLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// The app mark drawn in SwiftUI (matches the app icon's corner brackets and page).
private struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.45, blue: 1.0), Color(red: 0.33, green: 0.20, blue: 0.80)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 58, height: 58)
            .overlay {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
