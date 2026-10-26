import SwiftUI

struct SettingsView: View {
    let store: LibraryStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("System").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    .accessibilityIdentifier("settings.appearance")
                }
                Section("Reading") {
                    Picker("PDF Scrolling", selection: $settings.readingMode) {
                        Text("Vertical").tag(ReadingMode.vertical)
                        Text("Horizontal").tag(ReadingMode.horizontal)
                    }
                    .accessibilityIdentifier("settings.scrolling")
                    Toggle("Show Page Number", isOn: $settings.showsPageNumber)
                        .accessibilityIdentifier("settings.pageNumber")
                }
                Section("Library") {
                    NavigationLink {
                        ArchiveView(store: store)
                    } label: {
                        Label("View Archived Notebooks", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("settings.archive")
                }
                Section {
                    Toggle(isOn: .constant(false)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud Sync")
                            Text("Coming in V3").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(true)
                    .accessibilityIdentifier("settings.cloudSync")
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
