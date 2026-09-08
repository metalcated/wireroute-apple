// SPDX-License-Identifier: MIT

import SwiftUI
#if os(iOS)
import NetworkExtension
#elseif os(macOS)
import CoreWLAN
#endif

private enum AutomaticProfileTargetChoice: Hashable {
    case useDefault
    case vpnOff
    case profile(UUID)
}

private struct AutomaticWiFiAssignmentDraft: Identifiable, Equatable {
    let id: UUID
    var ssid: String
    var target: AutomaticProfileTargetChoice

    init(id: UUID = UUID(), ssid: String, target: AutomaticProfileTargetChoice) {
        self.id = id
        self.ssid = ssid
        self.target = target
    }
}

@MainActor
private final class AutomaticProfilesEditorModel: ObservableObject {
    @Published var isEnabled: Bool
    @Published var defaultProfileID: UUID?
    @Published var otherWiFiTarget: AutomaticProfileTargetChoice
    @Published var cellularTarget: AutomaticProfileTargetChoice
    @Published var ethernetTarget: AutomaticProfileTargetChoice
    @Published var trustedWiFiNames: String
    @Published var assignments: [AutomaticWiFiAssignmentDraft]
    @Published var isSaving = false
    @Published var alertTitle: String?
    @Published var alertMessage: String?

    let references: [AutomaticProfileReference]
    let wasEnabled: Bool
    let mustConfirmSingleProfileOnDemand: Bool
    private let tunnelsManager: TunnelsManager

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        let policy = tunnelsManager.automaticProfilePolicy
        let available = tunnelsManager.automaticProfileReferences
        var knownByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        for reference in Self.references(in: policy) where knownByID[reference.id] == nil {
            knownByID[reference.id] = reference
        }
        references = knownByID.values.sorted {
            TunnelsManager.tunnelNameIsLessThan($0.name, $1.name)
        }
        isEnabled = policy.isEnabled
        wasEnabled = policy.isEnabled
        mustConfirmSingleProfileOnDemand = !policy.isEnabled
            && tunnelsManager.hasEnabledSingleProfileOnDemand
        defaultProfileID = policy.defaultProfile?.id
        otherWiFiTarget = Self.choice(for: policy.otherWiFiTarget)
        cellularTarget = Self.choice(for: policy.cellularTarget)
        ethernetTarget = Self.choice(for: policy.ethernetTarget)
        trustedWiFiNames = policy.trustedWiFiNames.joined(separator: "\n")
        assignments = policy.wiFiAssignments.map {
            AutomaticWiFiAssignmentDraft(
                ssid: $0.ssid,
                target: Self.choice(for: $0.target)
            )
        }
    }

    var shouldConfirmSave: Bool {
        isEnabled && mustConfirmSingleProfileOnDemand
    }

    func displayName(for reference: AutomaticProfileReference) -> String {
        let isAvailable = tunnelsManager.automaticProfileReferences.contains { $0.id == reference.id }
        return isAvailable
            ? reference.name
            : tr(format: "automaticProfilesUnavailableProfile (%@)", reference.name)
    }

    func label(for choice: AutomaticProfileTargetChoice) -> String {
        switch choice {
        case .useDefault:
            return tr("automaticProfilesUseDefault")
        case .vpnOff:
            return tr("automaticProfilesVPNOff")
        case .profile(let id):
            guard let reference = references.first(where: { $0.id == id }) else {
                return tr("automaticProfilesUnavailable")
            }
            return displayName(for: reference)
        }
    }

    func addCurrentWiFiAsTrusted() {
        currentWiFiName { [weak self] currentName in
            guard let self else { return }
            guard let currentName else {
                showAlert(
                    title: tr("automaticProfilesWiFiUnavailableTitle"),
                    message: tr("automaticProfilesWiFiUnavailableMessage")
                )
                return
            }
            var names = parsedTrustedWiFiNames
            guard !names.contains(currentName) else { return }
            names.append(currentName)
            trustedWiFiNames = names.joined(separator: "\n")
        }
    }

    func addAssignment() {
        let initialTarget = references.first.map { AutomaticProfileTargetChoice.profile($0.id) }
            ?? .vpnOff
        assignments.append(AutomaticWiFiAssignmentDraft(ssid: "", target: initialTarget))
    }

    func removeAssignments(at offsets: IndexSet) {
        assignments.remove(atOffsets: offsets)
    }

    func save(completion: @escaping @MainActor () -> Void) {
        let policy: AutomaticProfilePolicy
        do {
            policy = try makePolicy().validated()
        } catch {
            showAlert(
                title: tr("automaticProfilesSaveFailureTitle"),
                message: error.localizedDescription
            )
            return
        }

        isSaving = true
        tunnelsManager.prepareAutomaticProfilesAuthorization(for: policy) { [weak self] authorizationError in
            guard let self else { return }
            if let authorizationError {
                isSaving = false
                showAlert(
                    title: authorizationError.alertText.title,
                    message: authorizationError.alertText.message
                )
                return
            }
            tunnelsManager.saveAutomaticProfilePolicy(policy) { [weak self] error in
                guard let self else { return }
                isSaving = false
                if let error {
                    showAlert(title: error.alertText.title, message: error.alertText.message)
                    return
                }
                completion()
            }
        }
    }

    private var parsedTrustedWiFiNames: [String] {
        trustedWiFiNames
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    private func makePolicy() throws -> AutomaticProfilePolicy {
        let defaultProfile = defaultProfileID.flatMap(reference(withID:))
        let assignmentModels = assignments.map { assignment in
            AutomaticWiFiAssignment(
                ssid: assignment.ssid,
                target: target(for: assignment.target)
            )
        }
        return AutomaticProfilePolicy(
            isEnabled: isEnabled,
            defaultProfile: defaultProfile,
            otherWiFiTarget: target(for: otherWiFiTarget),
            cellularTarget: target(for: cellularTarget),
            ethernetTarget: target(for: ethernetTarget),
            trustedWiFiNames: parsedTrustedWiFiNames,
            wiFiAssignments: assignmentModels
        )
    }

    private func target(for choice: AutomaticProfileTargetChoice) -> AutomaticProfileTarget {
        switch choice {
        case .useDefault:
            return .useDefault
        case .vpnOff:
            return .vpnOff
        case .profile(let id):
            guard let reference = reference(withID: id) else { return .vpnOff }
            return .profile(reference)
        }
    }

    private func reference(withID id: UUID) -> AutomaticProfileReference? {
        references.first { $0.id == id }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }

    private func currentWiFiName(
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        #if targetEnvironment(simulator)
        completion("Simulator Wi-Fi")
        #elseif os(iOS)
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            Task { @MainActor in
                completion(ssid)
            }
        }
        #elseif os(macOS)
        completion(CWWiFiClient.shared().interface()?.ssid())
        #else
        completion(nil)
        #endif
    }

    private static func choice(for target: AutomaticProfileTarget) -> AutomaticProfileTargetChoice {
        switch target {
        case .useDefault:
            return .useDefault
        case .vpnOff:
            return .vpnOff
        case .profile(let reference):
            return .profile(reference.id)
        }
    }

    private static func references(in policy: AutomaticProfilePolicy) -> [AutomaticProfileReference] {
        var references = [AutomaticProfileReference]()
        if let defaultProfile = policy.defaultProfile {
            references.append(defaultProfile)
        }
        for target in [policy.otherWiFiTarget, policy.cellularTarget, policy.ethernetTarget]
            + policy.wiFiAssignments.map(\.target) {
            if case .profile(let reference) = target {
                references.append(reference)
            }
        }
        return references
    }
}

struct AutomaticProfilesEditorView: View {
    @StateObject private var model: AutomaticProfilesEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsModeChangeConfirmation = false
    private let onClose: (() -> Void)?

    init(tunnelsManager: TunnelsManager, onClose: (() -> Void)? = nil) {
        _model = StateObject(
            wrappedValue: AutomaticProfilesEditorModel(tunnelsManager: tunnelsManager)
        )
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("automaticProfilesEnable"), isOn: $model.isEnabled)
                        .disabled(model.references.isEmpty)
                } footer: {
                    Text(tr("automaticProfilesIntro"))
                }

                Section {
                    defaultProfilePicker
                } header: {
                    Text(tr("automaticProfilesDefaultTitle"))
                } footer: {
                    Text(tr("automaticProfilesDefaultHelp"))
                }

                Section {
                    targetPicker(
                        tr("automaticProfilesOtherWiFi"),
                        selection: $model.otherWiFiTarget
                    )
                    #if os(iOS)
                    targetPicker(
                        tr("automaticProfilesCellular"),
                        selection: $model.cellularTarget
                    )
                    #endif
                    targetPicker(
                        tr("automaticProfilesEthernet"),
                        selection: $model.ethernetTarget
                    )
                } header: {
                    Text(tr("automaticProfilesActionsTitle"))
                } footer: {
                    Text(tr("automaticProfilesActionsHelp"))
                }

                Section {
                    TextEditor(text: $model.trustedWiFiNames)
                        .frame(minHeight: 76)
                        .accessibilityLabel(tr("automaticProfilesTrustedWiFiNames"))
                    Button(tr("automaticProfilesAddCurrentWiFi")) {
                        model.addCurrentWiFiAsTrusted()
                    }
                } header: {
                    Text(tr("automaticProfilesTrustedWiFiTitle"))
                } footer: {
                    Text(tr("automaticProfilesTrustedWiFiHelp"))
                }

                Section {
                    if model.assignments.isEmpty {
                        Text(tr("automaticProfilesAssignmentsEmpty"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($model.assignments) { $assignment in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(
                                tr("automaticProfilesWiFiName"),
                                text: $assignment.ssid
                            )
                            assignmentProfilePicker(selection: $assignment.target)
                        }
                        .padding(.vertical, 3)
                    }
                    .onDelete(perform: model.removeAssignments)
                    Button {
                        model.addAssignment()
                    } label: {
                        Label(
                            tr("automaticProfilesAddAssignment"),
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .disabled(model.references.isEmpty)
                } header: {
                    Text(tr("automaticProfilesAssignmentsTitle"))
                } footer: {
                    Text(tr("automaticProfilesAssignmentsHelp"))
                }

                Section(tr("automaticProfilesControlTitle")) {
                    Label(
                        tr("automaticProfilesControlHelp"),
                        systemImage: "hand.raised.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(tr("automaticProfilesTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("automaticProfilesCancel")) {
                        close()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("automaticProfilesSave")) {
                        if model.shouldConfirmSave {
                            showsModeChangeConfirmation = true
                        } else {
                            save()
                        }
                    }
                    .disabled(model.isSaving)
                }
            }
            .disabled(model.isSaving)
            .overlay {
                if model.isSaving {
                    ProgressView(tr("automaticProfilesSaving"))
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert(tr("automaticProfilesReplaceOnDemandTitle"), isPresented: $showsModeChangeConfirmation) {
                Button(tr("automaticProfilesCancel"), role: .cancel) {}
                Button(tr("automaticProfilesEnable")) { save() }
            } message: {
                Text(tr("automaticProfilesReplaceOnDemandMessage"))
            }
            .alert(
                model.alertTitle ?? tr("automaticProfilesSaveFailureTitle"),
                isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } }
                )
            ) {
                Button(tr("automaticProfilesOK"), role: .cancel) {}
            } message: {
                Text(model.alertMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 640, idealHeight: 760)
        #endif
    }

    @ViewBuilder
    private var defaultProfilePicker: some View {
        Picker(tr("automaticProfilesDefault"), selection: $model.defaultProfileID) {
            Text(tr("automaticProfilesVPNOff")).tag(nil as UUID?)
            ForEach(model.references, id: \.id) { reference in
                Text(model.displayName(for: reference)).tag(Optional(reference.id))
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func targetPicker(
        _ title: String,
        selection: Binding<AutomaticProfileTargetChoice>
    ) -> some View {
        Picker(title, selection: selection) {
            Text(tr("automaticProfilesUseDefault")).tag(AutomaticProfileTargetChoice.useDefault)
            Text(tr("automaticProfilesVPNOff")).tag(AutomaticProfileTargetChoice.vpnOff)
            ForEach(model.references, id: \.id) { reference in
                Text(model.displayName(for: reference))
                    .tag(AutomaticProfileTargetChoice.profile(reference.id))
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func assignmentProfilePicker(
        selection: Binding<AutomaticProfileTargetChoice>
    ) -> some View {
        Picker(tr("automaticProfilesProfile"), selection: selection) {
            ForEach(model.references, id: \.id) { reference in
                Text(model.displayName(for: reference))
                    .tag(AutomaticProfileTargetChoice.profile(reference.id))
            }
        }
        .pickerStyle(.menu)
    }

    private func save() {
        model.save { close() }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
