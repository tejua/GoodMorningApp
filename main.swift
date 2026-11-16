import SwiftUI
import AppKit

// Stores a Color in UserDefaults as a hex string so choices survive relaunch.
extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xFF) / 255,
                  green: Double((v >> 16) & 0xFF) / 255,
                  blue: Double((v >> 8) & 0xFF) / 255,
                  opacity: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
}

struct ContentView: View {
    @State private var now = Date()
    @AppStorage("bgColor") private var bgHex = "1E1E2EFF"
    @AppStorage("textColor") private var textHex = "FFFFFFFF"
    @State private var showOptions = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let deviceName = Host.current().localizedName ?? "this Mac"

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
        VStack(spacing: 14) {
            Text(greeting)
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text(deviceName)
                .font(.title2)
                .opacity(0.75)
            Text(now, format: .dateTime.hour().minute().second())
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.headline)
                .opacity(0.75)

            if showOptions {
                VStack(spacing: 10) {
                    ColorPicker("Background colour", selection: bgColor, supportsOpacity: false)
                    ColorPicker("Text colour", selection: textColor, supportsOpacity: false)
                    Button("Reset to default") {
                        bgHex = "1E1E2EFF"; textHex = "FFFFFFFF"
                    }
                }
                .padding(14)
                .frame(width: 280)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.primary)
                .padding(.top, 8)
            }
        }
        .foregroundStyle(Color(hex: textHex))
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(hex: bgHex))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { showOptions.toggle() }
            } label: {
                Image(systemName: showOptions ? "xmark.circle.fill" : "paintpalette.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: textHex))
            }
            .buttonStyle(.plain)
            .help("Colour options")
            .padding(12)
        }
        .onReceive(timer) { now = $0 }
    }
}

@main
struct GoodMorningApp: App {
    var body: some Scene {
        WindowGroup("Greeting") { ContentView() }
            .windowResizability(.contentSize)
    }
}
