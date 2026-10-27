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
                Section("Scanning") {
                    Picker("Default Filter", selection: $defaultFilter) {
                        ForEach(ScanFilter.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    Picker("Page Size", selection: $pageSize) {
                        ForEach(PDFPageSize.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Searchable PDF (OCR)", isOn: $searchablePDF)
                } header: {
                    Text("PDF Export")
                } footer: {
                    Text("Searchable PDFs include an invisible text layer, so you can search and copy text in Files, Preview and other apps.")
                }
                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("Scanning, border detection and text recognition all run on your iPhone. Nothing is uploaded.")
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
