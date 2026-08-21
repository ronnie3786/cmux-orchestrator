import SwiftUI

struct MachinesView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingMachineEditor = false
    @State private var editingMachine: HerdrMachine?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.machines) { machine in
                        Button {
                            editingMachine = machine
                            isPresentingMachineEditor = true
                        } label: {
                            HStack(spacing: 10) {
                                MachineListRow(
                                    machine: machine,
                                    state: model.connectionState(forMachine: machine.id)
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .herdrFont(.caption, weight: .bold)
                                    .foregroundStyle(HerdrTheme.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("machine-row-\(machine.id)")
                    }
                }

                Section {
                    Button {
                        editingMachine = nil
                        isPresentingMachineEditor = true
                    } label: {
                        Label("add machine", systemImage: "plus")
                            .herdrFont(.subheadline, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.text)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(HerdrTheme.elevated)
                            .overlay {
                                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                            }
                            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("machines-add-machine")
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Machines")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .sheet(isPresented: $isPresentingMachineEditor) {
            MachineEditorView(model: model, machine: editingMachine)
                .frame(minWidth: 480, minHeight: 420)
        }
    }
}

struct MachineListRow: View {
    let machine: HerdrMachine
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HerdrTheme.mist.opacity(statusOpacity))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .foregroundStyle(HerdrTheme.text)
                Text(machineHost(machine))
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.name), \(machineHost(machine)), \(state.title)")
    }

    private var statusOpacity: Double {
        switch state {
        case .live, .demo: 1
        case .connecting: 0.7
        case .disconnected, .failed: 0.45
        }
    }
}

func machineHost(_ machine: HerdrMachine) -> String {
    URLComponents(string: machine.urlString)?.host ?? machine.urlString
}
