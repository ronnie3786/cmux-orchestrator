import SwiftUI

struct HerdrHudHeaderView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)
            Text("HUD")
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.text)

            if model.machines.count > 1, let selectedMachine {
                machineMenu(selectedMachine)
            }

            if let machineID = selectedMachine?.id {
                Circle()
                    .fill(model.connectionState(forMachine: machineID).color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(model.connectionState(forMachine: machineID).title)
            }

            Spacer()

            if !session.exchanges.isEmpty {
                Button(action: clearHistory) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .disabled(session.isRunning)
                .accessibilityLabel("Clear HUD history")
                .accessibilityIdentifier("hud-clear-history")
            }

            Button(action: controller.collapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(HerdrTheme.mist)
            .accessibilityLabel("Collapse HUD")
            .accessibilityIdentifier("hud-collapse")
        }
        .padding(.horizontal, HerdrTheme.cardPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func machineMenu(_ selectedMachine: HerdrMachine) -> some View {
        Menu {
            ForEach(model.machines) { machine in
                Button {
                    session.selectedMachineID = machine.id
                } label: {
                    if machine.id == selectedMachine.id {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Text(machine.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedMachine.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .herdrFont(.caption2, weight: .bold)
            }
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(HerdrTheme.mist)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("HUD machine: \(selectedMachine.name)")
    }

    private var selectedMachine: HerdrMachine? {
        if let selectedMachineID = session.selectedMachineID,
           let selected = model.machines.first(where: { $0.id == selectedMachineID }) {
            selected
        } else {
            model.machines.first
        }
    }

    private func clearHistory() {
        Task { await session.clear(model: model) }
    }
}
