import SwiftUI
import UIKit

struct ContentView: View {
    @State private var now = Date()
    @AppStorage("bgColor") private var bgHex = "1E1E2EFF"
    @AppStorage("textColor") private var textHex = "FFFFFFFF"
    @State private var showOptions = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // iOS 16+ returns a generic name ("iPhone") unless the app has Apple's
    // user-assigned-device-name entitlement, so fall back to the model.
    private var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? UIDevice.current.model : name
    }

    private var bgColor: Binding<Color> {
        Binding(get: { Color(hex: bgHex) }, set: { bgHex = $0.hex })
    }
    private var textColor: Binding<Color> {
        Binding(get: { Color(hex: textHex) }, set: { textHex = $0.hex })
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12:  return "Good morning! ☀️"
        case 12..<17: return "Good afternoon! 🌤️"
        case 17..<21: return "Good evening! 🌇"
        default:      return "Good night! 🌙"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(greeting)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(deviceName)
                    .font(.title3)
                    .opacity(0.75)
                Text(now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 52, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.headline)
                    .opacity(0.75)
                    .multilineTextAlignment(.center)

                if showOptions {
                    VStack(spacing: 10) {
                        ColorPicker("Background colour", selection: bgColor, supportsOpacity: false)
                        ColorPicker("Text colour", selection: textColor, supportsOpacity: false)
                        Button("Reset to default") {
                            bgHex = "1E1E2EFF"; textHex = "FFFFFFFF"
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 320)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
                    .padding(.top, 4)
                }

                Divider()
                    .overlay(Color(hex: textHex).opacity(0.3))
                    .padding(.vertical, 6)

                VoiceTranslateView(textColor: Color(hex: textHex))
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color(hex: textHex))
        .background(Color(hex: bgHex).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { showOptions.toggle() }
            } label: {
                Image(systemName: showOptions ? "xmark.circle.fill" : "paintpalette.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: textHex))
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Colour options")
        }
        .onReceive(timer) { now = $0 }
    }
}

@main
struct GoodMorningApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
