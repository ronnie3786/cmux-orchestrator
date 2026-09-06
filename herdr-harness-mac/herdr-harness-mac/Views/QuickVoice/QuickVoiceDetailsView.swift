import SwiftUI

struct QuickVoiceDetailsView: View {
    let controller: QuickVoicePanelController
    @Bindable var session: QuickVoiceSession
    let model: HerdrAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voice request").herdrFont(.headline)
                Spacer()
                Menu("Recent voice requests", systemImage: "clock.arrow.circlepath") {
                    ForEach(session.notes) { note in
                        Button(model.showSessionTitles ? note.job.title : "Voice request") {
                            session.selectNote(note.id)
                        }
                    }
                }
                .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                .disabled(session.notes.isEmpty || session.phase != .idle || session.hasPendingSubmission)
                .help("Recent requests and their reports")
                Button("Close voice request", systemImage: "xmark", action: controller.collapse)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.phase != .idle || session.selectedNote == nil {
                        QuickVoiceCaptureStatusView(session: session)
                    } else if let note = session.selectedNote {
                        QuickVoiceNoteView(note: note, session: session, model: model)
                        if let error = session.error {
                            Label(error, systemImage: "speaker.slash")
                                .herdrFont(.callout).foregroundStyle(HerdrTheme.warning)
                        }
                    }
                    if let error = session.connectionError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .herdrFont(.callout).foregroundStyle(HerdrTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(session.selectedNoteID)
            HStack {
                Menu {
                    Picker("Run agents on", selection: $session.machineID) {
                        ForEach(model.machines) { machine in
                            Text(machine.name).tag(machine.id)
                        }
                    }
                    Text("Folder: \(session.contextFolder)")
                } label: {
                    Label(session.machineName, systemImage: "desktopcomputer")
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .disabled(session.phase != .idle || session.hasPendingSubmission)
                .help("Where the next request runs. Folder: \(session.contextFolder)")
                Spacer(minLength: 4)
                if session.playingMessageID != nil {
                    Button("Stop audio", systemImage: "stop.circle", action: session.stopAudio)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                }
                Button(session.isMuted ? "Unmute voice reports" : "Mute voice reports", systemImage: session.isMuted ? "speaker.slash" : "speaker.wave.2") {
                    session.isMuted.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
            }
            if session.phase == .recording {
                Button("Stop and send", systemImage: "arrow.up", action: controller.capture)
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            } else if session.phase == .idle, !session.hasPendingSubmission, !session.recorder.canSave {
                Button(session.selectedNote == nil ? "Start recording" : "Record another request", systemImage: "mic.fill", action: controller.capture)
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(!session.canCapture)
            }
        }
        .herdrFont(.callout)
        .foregroundStyle(HerdrTheme.text)
        .padding(HerdrTheme.cardPadding)
        .frame(width: HerdrHudPlacement.quickVoiceCardSize.width, height: HerdrHudPlacement.quickVoiceCardSize.height)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.cardRadius).strokeBorder(HerdrTheme.surface) }
        .accessibilityIdentifier("quick-voice-request-card")
        .onChange(of: session.machineID) { _, _ in
            Task { await session.refresh() }
        }
    }
}
