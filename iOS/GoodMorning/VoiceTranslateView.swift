import SwiftUI
import UIKit
import Translation

struct VoiceTranslateView: View {
    @StateObject private var vt = VoiceTranslator()
    @AppStorage("spokenLang") private var spoken: SpokenLang = .english
    let textColor: Color

    var body: some View {
        VStack(spacing: 14) {
            Text("Voice translate").font(.title3.weight(.semibold))

            VStack(spacing: 6) {
                Text("I'm speaking").font(.subheadline).opacity(0.8)
                Picker("I'm speaking", selection: $spoken) {
                    ForEach(SpokenLang.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .disabled(vt.isRecording)
                HStack(spacing: 6) {
                    Text("Translates to")
                    Text(spoken.other.name).fontWeight(.semibold)
                }
                .font(.subheadline)
            }

            Button { vt.toggle(spoken) } label: {
                ZStack {
                    Circle()
                        .fill(vt.isRecording ? Color.red : textColor.opacity(0.18))
                        .frame(width: 96, height: 96)
                    Image(systemName: vt.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(vt.isRecording ? Color.white : textColor)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(vt.isRecording ? "Stop and translate" : "Start recording")

            Text(vt.status)
                .font(.callout)
                .opacity(0.75)
                .multilineTextAlignment(.center)

            if vt.packMissing {
                Button("Download \(spoken.name) → \(spoken.other.name) for offline translation") {
                    vt.downloadPacks(for: spoken)
                }
                .font(.callout)
                .multilineTextAlignment(.center)
            }

            if let err = vt.errorMessage {
                VStack(spacing: 6) {
                    Text(err).font(.callout).multilineTextAlignment(.center)
                    if vt.permissionDenied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }

            box(title: "You said (\(vt.isRecording ? spoken.name : vt.source.name))",
                text: vt.transcript, placeholder: "Your words will appear here…")
            box(title: "Translation (\(vt.isRecording ? spoken.other.name : vt.source.other.name))",
                text: vt.translation, placeholder: "The translation will appear and be spoken here…",
                replay: !vt.translation.isEmpty)
        }
        .frame(maxWidth: 520)
        .translationTask(vt.config) { session in
            await vt.run(session)
        }
        .task(id: spoken) { await vt.checkPacks(for: spoken) }
    }

    @ViewBuilder
    private func box(title: String, text: String, placeholder: String, replay: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).opacity(0.7)
                Spacer()
                if replay {
                    Button { vt.speak() } label: {
                        Label("Replay", systemImage: "speaker.wave.2.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(textColor)
                }
            }
            Text(text.isEmpty ? placeholder : text)
                .font(.body)
                .opacity(text.isEmpty ? 0.45 : 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        }
        .padding(12)
        .background(textColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
