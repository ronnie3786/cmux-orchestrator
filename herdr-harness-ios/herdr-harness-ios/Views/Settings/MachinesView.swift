import SwiftUI

struct MachinesView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        List {
            Section {
                ForEach(model.machines) { machine in
                    NavigationLink {
                        MachineEditorView(model: model, machine: machine)
                    } label: {
                        MachineListRow(
                            machine: machine,
                            state: model.connectionState(forMachine: machine.id)
                        )
                    }
                    .accessibilityIdentifier("machine-row-\(machine.id)")
                }
                .onMove(perform: model.reorderMachines)
            }

            Section {
                NavigationLink {
                    MachineEditorView(model: model, machine: nil)
                } label: {
                    Label("add machine", systemImage: "plus")
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(HerdrTheme.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
        .toolbar { EditButton() }
    }
}

struct MachineListRow: View {
    let machine: HerdrMachine
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                Text(machineHost(machine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.name), \(machineHost(machine)), \(state.title)")
    }
}

func machineHost(_ machine: HerdrMachine) -> String {
    URLComponents(string: machine.urlString)?.host ?? machine.urlString
}
