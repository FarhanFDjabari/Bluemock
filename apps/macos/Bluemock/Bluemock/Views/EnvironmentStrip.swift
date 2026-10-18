import SwiftUI

struct EnvironmentStrip: View {
    @Bindable var store: DeviceStore
    private var report: DoctorReport? { store.doctorReport }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(report?.ok == true ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Environment status")
                .accessibilityValue(report?.ok == true ? "Ready" : "Needs attention")
            Text(report?.summary ?? (store.cli == nil ? "Bluemock CLI not found" : "Checking environment…"))
                .font(.caption)
                .lineLimit(1)
                .help(report?.summary ?? "Environment status")
            Spacer(minLength: 4)
            Button {
                Task { await store.refresh(forceDoctor: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh environment status")
            if report?.hasFixableFailure == true {
                Button("Fix") { Task { await store.fixDoctor() } }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}
