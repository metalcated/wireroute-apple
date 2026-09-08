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
    private let onCancel: (() -> Void)?
    private let onSaved: (() -> Void)?

    init(
        tunnelsManager: TunnelsManager,
        onCancel: (() -> Void)? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: AutomaticProfilesEditorModel(tunnelsManager: tunnelsManager)
        )
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader

                    panel {
                        Toggle(tr("automaticProfilesEnable"), isOn: $model.isEnabled)
                            .toggleStyle(.switch)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .tint(automaticProfilesAccent)
                            .disabled(model.references.isEmpty)
                    }

                    sectionCard(
                        title: tr("automaticProfilesDefaultTitle"),
                        detail: tr("automaticProfilesDefaultHelp")
                    ) {
                        defaultProfilePicker
                    }

                    sectionCard(
                        title: tr("automaticProfilesActionsTitle"),
                        detail: tr("automaticProfilesActionsHelp")
                    ) {
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
                    }

                    sectionCard(
                        title: tr("automaticProfilesTrustedWiFiTitle"),
                        detail: tr("automaticProfilesTrustedWiFiHelp")
                    ) {
                        TextEditor(text: $model.trustedWiFiNames)
                            .font(.system(.body, design: .rounded))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 88)
                            .background(automaticProfilesInset)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(automaticProfilesBorder.opacity(0.82), lineWidth: 1)
                            }
                            .accessibilityLabel(tr("automaticProfilesTrustedWiFiNames"))

                        secondaryActionButton(
                            title: tr("automaticProfilesAddCurrentWiFi"),
                            systemImage: "wifi"
                        ) {
                            model.addCurrentWiFiAsTrusted()
                        }
                    }

                    sectionCard(
                        title: tr("automaticProfilesAssignmentsTitle"),
                        detail: tr("automaticProfilesAssignmentsHelp")
                    ) {
                        if model.assignments.isEmpty {
                            Text(tr("automaticProfilesAssignmentsEmpty"))
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        ForEach($model.assignments) { $assignment in
                            assignmentRow(assignment: $assignment)
                        }
                        secondaryActionButton(
                            title: tr("automaticProfilesAddAssignment"),
                            systemImage: "plus"
                        ) {
                            model.addAssignment()
                        }
                        .disabled(model.references.isEmpty)
                    }

                    panel {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(automaticProfilesAccent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tr("automaticProfilesControlTitle"))
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                Text(tr("automaticProfilesControlHelp"))
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }

            footer
        }
        .background(automaticProfilesBackground.ignoresSafeArea())
        .tint(automaticProfilesAccent)
        .disabled(model.isSaving)
        .overlay {
            if model.isSaving {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    ProgressView(tr("automaticProfilesSaving"))
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(automaticProfilesRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(automaticProfilesBorder.opacity(0.72), lineWidth: 1)
                        }
                }
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
        #if os(macOS)
        .frame(minWidth: 650, idealWidth: 700, minHeight: 650, idealHeight: 760)
        #endif
    }

    @ViewBuilder
    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(automaticProfilesAccent)
                .frame(width: 48, height: 48)
                .background(automaticProfilesAccent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("automaticProfilesTitle"))
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text(tr("automaticProfilesIntro"))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(automaticProfilesCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(automaticProfilesBorder.opacity(0.72), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(detail)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            panel(content: content)
        }
    }

    @ViewBuilder
    private var defaultProfilePicker: some View {
        Menu {
            Button {
                model.defaultProfileID = nil
            } label: {
                choiceMenuLabel(
                    tr("automaticProfilesVPNOff"),
                    isSelected: model.defaultProfileID == nil
                )
            }
            ForEach(model.references, id: \.id) { reference in
                Button {
                    model.defaultProfileID = reference.id
                } label: {
                    choiceMenuLabel(
                        model.displayName(for: reference),
                        isSelected: model.defaultProfileID == reference.id
                    )
                }
            }
        } label: {
            choiceRow(
                title: tr("automaticProfilesDefault"),
                value: model.defaultProfileID
                    .flatMap { id in model.references.first { $0.id == id } }
                    .map(model.displayName(for:)) ?? tr("automaticProfilesVPNOff")
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func targetPicker(
        _ title: String,
        selection: Binding<AutomaticProfileTargetChoice>
    ) -> some View {
        Menu {
            choiceMenuButton(
                title: tr("automaticProfilesUseDefault"),
                choice: .useDefault,
                selection: selection
            )
            choiceMenuButton(
                title: tr("automaticProfilesVPNOff"),
                choice: .vpnOff,
                selection: selection
            )
            ForEach(model.references, id: \.id) { reference in
                choiceMenuButton(
                    title: model.displayName(for: reference),
                    choice: .profile(reference.id),
                    selection: selection
                )
            }
        } label: {
            choiceRow(title: title, value: model.label(for: selection.wrappedValue))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func assignmentProfilePicker(
        selection: Binding<AutomaticProfileTargetChoice>
    ) -> some View {
        Menu {
            ForEach(model.references, id: \.id) { reference in
                choiceMenuButton(
                    title: model.displayName(for: reference),
                    choice: .profile(reference.id),
                    selection: selection
                )
            }
        } label: {
            choiceRow(
                title: tr("automaticProfilesProfile"),
                value: model.label(for: selection.wrappedValue)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func choiceMenuButton(
        title: String,
        choice: AutomaticProfileTargetChoice,
        selection: Binding<AutomaticProfileTargetChoice>
    ) -> some View {
        Button {
            selection.wrappedValue = choice
        } label: {
            choiceMenuLabel(title, isSelected: selection.wrappedValue == choice)
        }
    }

    @ViewBuilder
    private func choiceMenuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func choiceRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(automaticProfilesAccent)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(automaticProfilesInset)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func assignmentRow(
        assignment: Binding<AutomaticWiFiAssignmentDraft>
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField(tr("automaticProfilesWiFiName"), text: assignment.ssid)
                    .font(.system(.body, design: .rounded))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(automaticProfilesInset)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(automaticProfilesBorder.opacity(0.82), lineWidth: 1)
                    }
                Button {
                    model.assignments.removeAll { $0.id == assignment.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 42, height: 42)
                        .background(automaticProfilesInset)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("automaticProfilesRemoveAssignment"))
            }
            assignmentProfilePicker(selection: assignment.target)
        }
        .padding(12)
        .background(automaticProfilesRaised.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func secondaryActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                Spacer()
            }
            .foregroundStyle(automaticProfilesAccent)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(automaticProfilesAccent.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(tr("automaticProfilesCancel")) {
                cancel()
            }
            .buttonStyle(.plain)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .background(automaticProfilesRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .keyboardShortcut(.cancelAction)

            Button(tr("automaticProfilesSave")) {
                if model.shouldConfirmSave {
                    showsModeChangeConfirmation = true
                } else {
                    save()
                }
            }
            .buttonStyle(.plain)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .frame(minHeight: 44)
            .background(automaticProfilesAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(automaticProfilesCard)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(automaticProfilesBorder.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func save() {
        model.save {
            if let onSaved {
                onSaved()
            } else {
                dismiss()
            }
        }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private var automaticProfilesBackground: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.background)
        #else
        return Color(nsColor: WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .canvas)
            : .windowBackgroundColor)
        #endif
    }

    private var automaticProfilesCard: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.card)
        #else
        return Color(nsColor: WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .surface)
            : .controlBackgroundColor)
        #endif
    }

    private var automaticProfilesInset: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.inset)
        #else
        return Color(nsColor: WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .inset)
            : .textBackgroundColor)
        #endif
    }

    private var automaticProfilesRaised: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.raised)
        #else
        return Color(nsColor: WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .raised)
            : .underPageBackgroundColor)
        #endif
    }

    private var automaticProfilesBorder: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.border)
        #else
        return Color(nsColor: WireRouteTheme.isBlueNordic
            ? WireRouteTheme.borderColor
            : .separatorColor)
        #endif
    }

    private var automaticProfilesAccent: Color {
        #if os(iOS)
        return Color(uiColor: WireRouteAppearance.signalBlue)
        #else
        return Color(nsColor: WireRouteTheme.accentColor)
        #endif
    }
}
