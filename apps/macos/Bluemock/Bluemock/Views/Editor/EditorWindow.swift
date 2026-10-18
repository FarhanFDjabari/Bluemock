import SwiftUI
import AppKit

nonisolated struct EditorLaunch: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case new, edit, duplicate }
    let source: Source
    let path: String?
    static let new = EditorLaunch(source: .new, path: nil)
    static func edit(path: String) -> Self { Self(source: .edit, path: path) }
    static func duplicate(path: String) -> Self { Self(source: .duplicate, path: path) }
}

struct EditorWindow: View {
    @Binding var launch: EditorLaunch?
    @Bindable var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var definition = DeviceDefinition()
    @State private var savedDefinition = DeviceDefinition()
    @State private var existingPath: String?
    @State private var issues: [EditorValidationIssue] = []
    @State private var loadError: String?
    @State private var showStartSheet = false
    @State private var activeDialog: EditorDialog?
    @State private var commentWarningAcknowledged = Set<String>()
    @State private var isBusy = false
    @State private var launched = false

    private var isDirty: Bool { definition != savedDefinition }

    var body: some View {
        NavigationStack {
          ScrollViewReader { scroll in
            Form {
                if let loadError { Text(loadError).foregroundStyle(.red) }
                ValidationSummary(issues: issues) { path in withAnimation { scroll.scrollTo(path, anchor: .center) } }
                GeneralSection(definition: $definition, issues: issues)
                AdvertisingSection(definition: $definition, issues: issues)
                ServicesSection(definition: $definition, issues: issues)
                StateSection(definition: $definition, issues: issues)
                RulesSection(definition: $definition, issues: issues)
                ActionsSection(definition: $definition, issues: issues)
                DisclosureGroup("Tests preserved") {
                    Text("This file contains \(testCount) selftest case(s). The tests block is preserved and is not editable in v1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItemGroup {
                    Button("Close", action: requestClose)
                        .keyboardShortcut("w", modifiers: .command)
                        .accessibilityLabel("Close device editor")
                    Button("Validate", action: { Task { await validate() } })
                        .disabled(isBusy).accessibilityLabel("Validate device definition")
                    Button("Revert", action: revert)
                        .disabled(!isDirty || isBusy).accessibilityLabel("Revert unsaved changes")
                    if existingPath != nil {
                        Button("Delete", role: .destructive) { activeDialog = .delete }
                            .disabled(isBusy).accessibilityLabel("Delete device definition")
                    }
                    Button("Save", action: { Task { await beginSave() } })
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || isBusy)
                        .accessibilityLabel("Save device definition")
                }
            }
            .navigationTitle(definition.name.isEmpty ? "Device Editor" : definition.name)
            .frame(minWidth: 700, minHeight: 600)
            .sheet(isPresented: $showStartSheet) {
                EditorStartSheet(presets: store.presets, devices: store.devices,
                                 blank: startBlank, preset: startPreset, duplicate: startDuplicate)
            }
            .confirmationDialog(dialogTitle, isPresented: dialogPresented, titleVisibility: .visible) {
                dialogButtons
            } message: { Text(dialogMessage) }
            .onCommand(#selector(NSWindow.performClose(_:)), perform: requestClose)
            .task {
                guard !launched else { return }
                launched = true
                if store.cli == nil || store.deviceDirectory == nil { await store.refresh() }
                await loadLaunch()
            }
          }
        }
    }

    private var testCount: Int {
        if case .array(let values) = definition.tests { return values.count }
        return 0
    }
    private var dialogPresented: Binding<Bool> {
        Binding(get: { activeDialog != nil }, set: { if !$0 { activeDialog = nil } })
    }
    private var dialogTitle: String {
        switch activeDialog { case .comments: "Saving drops comments"; case .delete: "Delete device definition?"; case .discard: "Discard unsaved changes?"; case nil: "" }
    }
    private var dialogMessage: String {
        switch activeDialog {
        case .comments: "Comments in this file are not preserved by the CLI YAML writer."
        case .delete: "This removes \(existingPath ?? "the device file") from the device folder."
        case .discard: "Your unsaved edits will be lost."
        case nil: ""
        }
    }
    @ViewBuilder private var dialogButtons: some View {
        switch activeDialog {
        case .comments:
            Button("Save without comments") { if let path = existingPath { commentWarningAcknowledged.insert(path) }; activeDialog = nil; Task { await saveNow() } }
            Button("Cancel", role: .cancel) { activeDialog = nil }
        case .delete:
            Button("Delete", role: .destructive) { Task { await deleteFile() } }
            Button("Cancel", role: .cancel) { activeDialog = nil }
        case .discard:
            Button("Discard", role: .destructive) { activeDialog = nil; dismiss() }
            Button("Keep Editing", role: .cancel) { activeDialog = nil }
        case nil: EmptyView()
        }
    }

    private func loadLaunch() async {
        guard let launch else { showStartSheet = true; return }
        switch launch.source {
        case .new:
            definition = .blank(); savedDefinition = definition; existingPath = nil; showStartSheet = true
        case .edit:
            if let path = launch.path { await loadDefinition(path: path, isDuplicate: false) }
        case .duplicate:
            if let path = launch.path { await loadDefinition(path: path, isDuplicate: true) }
        }
    }

    private func startBlank() {
        definition = .blank(); savedDefinition = definition; existingPath = nil; issues = []; loadError = nil; showStartSheet = false
    }
    private func startPreset(_ id: String) {
        Task { await loadDefinition(path: id, isDuplicate: true, preset: true); showStartSheet = false }
    }
    private func startDuplicate(_ path: String) {
        Task { await loadDefinition(path: path, isDuplicate: true); showStartSheet = false }
    }
    private func loadDefinition(path: String, isDuplicate: Bool, preset: Bool = false) async {
        guard let cli = store.cli else { loadError = "Bluemock CLI not found"; return }
        isBusy = true
        defer { isBusy = false }
        do {
            var loaded = try await CLIRunner.show(path, using: cli)
            if !preset, URL(fileURLWithPath: path).pathExtension.lowercased() == "json",
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let raw = try? JSONDecoder().decode(DeviceDefinition.self, from: data) {
                loaded.tests = raw.tests
                loaded.unknownTopLevel = raw.unknownTopLevel
            }
            if isDuplicate {
                loaded.id += "-copy"
                loaded.name += " Copy"
            }
            definition = loaded
            savedDefinition = loaded
            existingPath = isDuplicate || preset ? nil : path
            issues = []
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func validate() async {
        guard let cli = store.cli else { loadError = "Bluemock CLI not found"; return }
        isBusy = true
        defer { isBusy = false }
        do { issues = try await CLIRunner.validate(definition, using: cli) }
        catch { issues = [EditorValidationIssue(path: "$", message: error.localizedDescription)] }
    }

    private func beginSave() async {
        if existingPath == nil {
            guard validFilename(definition.id) else {
                issues = [EditorValidationIssue(path: "id", message: "Use letters, numbers, dots, underscores or hyphens for the file name.")]
                return
            }
            if let directory = store.deviceDirectory {
                let candidate = directory.appendingPathComponent(definition.id + ".yaml")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    issues = [EditorValidationIssue(path: "id", message: "A device file with this id already exists.")]
                    return
                }
            }
        } else if let path = existingPath, hasComments(path), !commentWarningAcknowledged.contains(path) {
            activeDialog = .comments
            return
        }
        await saveNow()
    }

    private func saveNow() async {
        guard let cli = store.cli else { loadError = "Bluemock CLI not found"; return }
        guard validFilename(definition.id) else {
            issues = [EditorValidationIssue(path: "id", message: "Use letters, numbers, dots, underscores or hyphens for the file name.")]
            return
        }
        isBusy = true
        defer { isBusy = false }
        let path: String
        if let existingPath { path = existingPath }
        else {
            guard let directory = store.deviceDirectory else { loadError = "Device directory is unavailable"; return }
            path = directory.appendingPathComponent(definition.id + ".yaml").path
        }
        do {
            let priorID = savedDefinition.id
            let saveIssues = try await CLIRunner.save(definition, to: path, using: cli)
            issues = saveIssues
            guard saveIssues.isEmpty else { return }
            existingPath = path
            savedDefinition = definition
            store.markNeedsRestart(definition.id, previousID: priorID)
            await store.reloadDevices()
        } catch { issues = [EditorValidationIssue(path: "$", message: error.localizedDescription)] }
    }

    private func deleteFile() async {
        guard let existingPath else { return }
        do {
            await store.stop(savedDefinition.id)
            try FileManager.default.removeItem(atPath: existingPath)
            await store.reloadDevices()
            activeDialog = nil
            dismiss()
        } catch { loadError = error.localizedDescription; activeDialog = nil }
    }

    private func revert() { definition = savedDefinition; issues = []; loadError = nil }
    private func requestClose() { if isDirty { activeDialog = .discard } else { dismiss() } }
    private func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
    private func hasComments(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") || trimmed.contains(" #")
        }
    }
}

private enum EditorDialog { case comments, delete, discard }
