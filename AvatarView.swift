import SwiftUI

// MARK: - Animated avatar (pure SwiftUI drawing, no images)

enum AvatarMood: Equatable { case idle, listening, thinking, speaking, concerned }

private extension Color {
    static let avSkinLight = Color(red: 1.00, green: 0.89, blue: 0.81)
    static let avSkin      = Color(red: 0.98, green: 0.80, blue: 0.69)
    static let avSkinShade = Color(red: 0.92, green: 0.70, blue: 0.59)
    static let avHair      = Color(red: 0.20, green: 0.13, blue: 0.12)
    static let avHairLight = Color(red: 0.36, green: 0.23, blue: 0.20)
    static let avIris      = Color(red: 0.42, green: 0.25, blue: 0.18)
    static let avIrisDark  = Color(red: 0.20, green: 0.11, blue: 0.08)
    static let avLash      = Color(red: 0.16, green: 0.10, blue: 0.09)
    static let avLip       = Color(red: 0.72, green: 0.31, blue: 0.37)
    static let avMouth     = Color(red: 0.52, green: 0.17, blue: 0.24)
    static let avTongue    = Color(red: 0.95, green: 0.48, blue: 0.54)
    static let avBlush     = Color(red: 1.00, green: 0.56, blue: 0.64)
    static let avTop       = Color(red: 0.62, green: 0.55, blue: 0.95)
    static let avTopDark   = Color(red: 0.47, green: 0.40, blue: 0.86)
    static let avAccent    = Color(red: 1.00, green: 0.55, blue: 0.68)
}

/// The girl herself, drawn in a 200×200 design space. Animatable so SwiftUI
/// interpolates expression changes only while an animation is running.
struct AvatarFigure: View, Animatable {
    var mouth: CGFloat = 0     // 0 closed … 1 wide open
    var tilt: CGFloat = 0      // head tilt in degrees
    var lookUp: CGFloat = 0    // 0 straight … 1 glancing up
    var blink: CGFloat = 0     // 0 open … 1 closed
    var brow: CGFloat = 0      // -1 concerned … 0 relaxed … 1 raised
    var smile: CGFloat = 0.8   // -1 frown … 1 big smile
    var waves: CGFloat = 0     // 0 none … 1 loud (listening sound waves)

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(mouth, tilt),
                             AnimatablePair(AnimatablePair(lookUp, blink), AnimatablePair(brow, smile))) }
        set {
            mouth = newValue.first.first; tilt = newValue.first.second
            lookUp = newValue.second.first.first; blink = newValue.second.first.second
            brow = newValue.second.second.first; smile = newValue.second.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 200
            ctx.translateBy(x: (size.width - 200 * s) / 2, y: (size.height - 200 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            draw(&ctx)
        }
    }

    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private func headContext(_ base: GraphicsContext) -> GraphicsContext {
        var ctx = base
        ctx.translateBy(x: 100, y: 140)
        ctx.rotate(by: .degrees(Double(tilt)))
        ctx.translateBy(x: -100, y: -140)
        return ctx
    }

    private var hairFill: GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [.avHairLight, .avHair]),
                        startPoint: CGPoint(x: 100, y: 20), endPoint: CGPoint(x: 100, y: 150))
    }

    private func draw(_ base: inout GraphicsContext) {
        // ---- Back hair (behind neck & shoulders, tilts with head)
        let back = headContext(base)
        back.fill(ellipse(100, 86, 48, 46), with: hairFill)
        var fall = Path()
        fall.move(to: CGPoint(x: 52, y: 86))
        fall.addLine(to: CGPoint(x: 52, y: 140))
        fall.addQuadCurve(to: CGPoint(x: 72, y: 158), control: CGPoint(x: 52, y: 158))
        fall.addLine(to: CGPoint(x: 128, y: 158))
        fall.addQuadCurve(to: CGPoint(x: 148, y: 140), control: CGPoint(x: 148, y: 158))
        fall.addLine(to: CGPoint(x: 148, y: 86))
        fall.closeSubpath()
        back.fill(fall, with: hairFill)

        // ---- Body (not tilted)
        let neck = Path(roundedRect: CGRect(x: 89, y: 122, width: 22, height: 40), cornerRadius: 8)
        base.fill(neck, with: .linearGradient(Gradient(colors: [.avSkinShade, .avSkin]),
                                              startPoint: CGPoint(x: 100, y: 122), endPoint: CGPoint(x: 100, y: 150)))
        var top = Path()
        top.move(to: CGPoint(x: 26, y: 204))
        top.addCurve(to: CGPoint(x: 66, y: 158), control1: CGPoint(x: 28, y: 178), control2: CGPoint(x: 44, y: 162))
        top.addLine(to: CGPoint(x: 86, y: 152))
        top.addQuadCurve(to: CGPoint(x: 114, y: 152), control: CGPoint(x: 100, y: 170))
        top.addLine(to: CGPoint(x: 134, y: 158))
        top.addCurve(to: CGPoint(x: 174, y: 204), control1: CGPoint(x: 156, y: 162), control2: CGPoint(x: 172, y: 178))
        top.closeSubpath()
        base.fill(top, with: .linearGradient(Gradient(colors: [.avTop, .avTopDark]),
                                             startPoint: CGPoint(x: 100, y: 150), endPoint: CGPoint(x: 100, y: 204)))
        // neckline trim
        var trim = Path()
        trim.move(to: CGPoint(x: 86, y: 152))
        trim.addQuadCurve(to: CGPoint(x: 114, y: 152), control: CGPoint(x: 100, y: 170))
        base.stroke(trim, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        // little heart pendant
        base.fill(ellipse(100, 166, 2.6, 2.6), with: .color(.avAccent))

        // ---- Head group (tilts around the neck)
        var ctx = headContext(base)
        // bun
        ctx.fill(ellipse(100, 36, 21, 19), with: hairFill)
        var bunShine = Path()
        bunShine.addArc(center: CGPoint(x: 100, y: 36), radius: 13, startAngle: .degrees(200), endAngle: .degrees(260), clockwise: false)
        ctx.stroke(bunShine, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        ctx.fill(Path(roundedRect: CGRect(x: 86, y: 50, width: 28, height: 8), cornerRadius: 4), with: .color(.avAccent))

        // face: round cheeks with a soft chin
        let cheeks = ellipse(100, 91, 41, 40)
        var face = Path()
        face.move(to: CGPoint(x: 60, y: 98))
        face.addCurve(to: CGPoint(x: 100, y: 136), control1: CGPoint(x: 64, y: 122), control2: CGPoint(x: 84, y: 136))
        face.addCurve(to: CGPoint(x: 140, y: 98), control1: CGPoint(x: 116, y: 136), control2: CGPoint(x: 136, y: 122))
        face.closeSubpath()
        // soft shadow under the chin onto the neck
        var chinShadow = base
        chinShadow.addFilter(.blur(radius: 3))
        chinShadow.fill(ellipse(100, 135, 13, 4), with: .color(.avSkinShade.opacity(0.8)))
        ctx.fill(cheeks,
                 with: .radialGradient(Gradient(colors: [.avSkinLight, .avSkin]),
                                       center: CGPoint(x: 96, y: 88), startRadius: 4, endRadius: 52))
        ctx.fill(face,
                 with: .radialGradient(Gradient(colors: [.avSkinLight, .avSkin]),
                                       center: CGPoint(x: 96, y: 88), startRadius: 4, endRadius: 52))

        // blush (soft)
        var soft = ctx
        soft.addFilter(.blur(radius: 3))
        soft.fill(ellipse(72, 115, 8, 4.8), with: .color(.avBlush.opacity(0.55)))
        soft.fill(ellipse(128, 115, 8, 4.8), with: .color(.avBlush.opacity(0.55)))

        // nose
        var nose = Path()
        nose.move(to: CGPoint(x: 97.5, y: 110.5))
        nose.addQuadCurve(to: CGPoint(x: 102.5, y: 110.5), control: CGPoint(x: 100, y: 113))
        ctx.stroke(nose, with: .color(.avSkinShade), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        drawMouth(&ctx)
        for (cx, side) in [(CGFloat(83), CGFloat(-1)), (117, 1)] { drawEye(&ctx, cx: cx, cy: 99, side: side) }
        for (cx, side) in [(CGFloat(83), CGFloat(-1)), (117, 1)] { drawBrow(&ctx, cx: cx, side: side) }

        // fringe (side-swept bangs)
        var fringe = Path()
        fringe.move(to: CGPoint(x: 57, y: 100))
        fringe.addCurve(to: CGPoint(x: 100, y: 47), control1: CGPoint(x: 52, y: 66), control2: CGPoint(x: 74, y: 47))
        fringe.addCurve(to: CGPoint(x: 143, y: 100), control1: CGPoint(x: 126, y: 47), control2: CGPoint(x: 148, y: 66))
        fringe.addQuadCurve(to: CGPoint(x: 126, y: 72), control: CGPoint(x: 138, y: 78))
        fringe.addQuadCurve(to: CGPoint(x: 108, y: 79), control: CGPoint(x: 118, y: 78))
        fringe.addQuadCurve(to: CGPoint(x: 90, y: 70), control: CGPoint(x: 98, y: 77))
        fringe.addQuadCurve(to: CGPoint(x: 70, y: 79), control: CGPoint(x: 78, y: 74))
        fringe.addQuadCurve(to: CGPoint(x: 57, y: 100), control: CGPoint(x: 60, y: 84))
        fringe.closeSubpath()
        ctx.fill(fringe, with: hairFill)
        // side locks framing the face
        var lockL = Path()
        lockL.move(to: CGPoint(x: 58, y: 84))
        lockL.addQuadCurve(to: CGPoint(x: 64, y: 126), control: CGPoint(x: 52, y: 110))
        lockL.addQuadCurve(to: CGPoint(x: 64, y: 92), control: CGPoint(x: 63, y: 108))
        lockL.closeSubpath()
        ctx.fill(lockL, with: hairFill)
        var lockR = Path()
        lockR.move(to: CGPoint(x: 142, y: 84))
        lockR.addQuadCurve(to: CGPoint(x: 136, y: 126), control: CGPoint(x: 148, y: 110))
        lockR.addQuadCurve(to: CGPoint(x: 136, y: 92), control: CGPoint(x: 137, y: 108))
        lockR.closeSubpath()
        ctx.fill(lockR, with: hairFill)
        // hair shine
        var shine = Path()
        shine.move(to: CGPoint(x: 76, y: 60))
        shine.addQuadCurve(to: CGPoint(x: 98, y: 52), control: CGPoint(x: 84, y: 53))
        ctx.stroke(shine, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // listening sound waves by the right ear
        if waves > 0.01 {
            for i in 0..<3 {
                let strength = min(1, max(0, waves * 3 - CGFloat(i)))
                guard strength > 0 else { continue }
                var arc = Path()
                arc.addArc(center: CGPoint(x: 152, y: 99), radius: 9 + CGFloat(i) * 6,
                           startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: false)
                ctx.stroke(arc, with: .color(Color.avAccent.opacity(0.35 + 0.6 * Double(strength))),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
    }

    private func drawEye(_ ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat, side: CGFloat) {
        let closed = blink > 0.6
        if closed {
            var lid = Path()
            lid.move(to: CGPoint(x: cx - 9, y: cy + 1))
            lid.addQuadCurve(to: CGPoint(x: cx + 9, y: cy + 1), control: CGPoint(x: cx, y: cy + 7))
            ctx.stroke(lid, with: .color(.avLash), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            return
        }
        let ry = 11.5 * (1 - blink * 0.85)
        let sclera = ellipse(cx, cy + 1, 9, ry)
        ctx.fill(sclera, with: .color(.white))
        var eye = ctx
        eye.clip(to: sclera)
        let iy = cy + 2 - lookUp * 4.5
        let ix = cx + side * 0.5
        eye.fill(ellipse(ix, iy, 7.2, 8.2),
                 with: .radialGradient(Gradient(colors: [.avIris, .avIrisDark]),
                                       center: CGPoint(x: ix, y: iy + 3), startRadius: 1, endRadius: 9))
        eye.fill(ellipse(ix, iy, 3.6, 4.2), with: .color(Color(red: 0.08, green: 0.04, blue: 0.03)))
        eye.fill(ellipse(ix - 2.6, iy - 3.4, 2.6, 2.6), with: .color(.white))
        eye.fill(ellipse(ix + 2.6, iy + 2.8, 1.2, 1.2), with: .color(.white.opacity(0.9)))
        // upper lash line + flick
        var lash = Path()
        lash.move(to: CGPoint(x: cx - 9.5, y: cy - 1))
        lash.addQuadCurve(to: CGPoint(x: cx + 9.5, y: cy - 1), control: CGPoint(x: cx, y: cy - ry * 1.95 + 1))
        ctx.stroke(lash, with: .color(.avLash), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        var flick = Path()
        let ox = cx + side * 9.5
        flick.move(to: CGPoint(x: ox, y: cy - 1))
        flick.addLine(to: CGPoint(x: ox + side * 3.5, y: cy - 4.5))
        ctx.stroke(flick, with: .color(.avLash), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    private func drawBrow(_ ctx: inout GraphicsContext, cx: CGFloat, side: CGFloat) {
        let lift = max(0, brow) * 3.5
        let concern = max(0, -brow)
        let by = 82 - lift
        let inner = CGPoint(x: cx - side * 8, y: by + 1 - concern * 4)
        let outer = CGPoint(x: cx + side * 8, y: by + 1 + concern * 1.5)
        var p = Path()
        p.move(to: inner)
        p.addQuadCurve(to: outer, control: CGPoint(x: cx, y: by - 3 + concern * 1.5))
        ctx.stroke(p, with: .color(.avHair.opacity(0.85)), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
    }

    private func drawMouth(_ ctx: inout GraphicsContext) {
        let cx: CGFloat = 100, y: CGFloat = 122
        let open = min(1, max(0, mouth))
        if open < 0.08 {
            let w: CGFloat = 13
            var p = Path()
            p.move(to: CGPoint(x: cx - w / 2, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + w / 2, y: y), control: CGPoint(x: cx, y: y + 6 * smile))
            ctx.stroke(p, with: .color(.avLip), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
            return
        }
        let w = 11 + 4 * open
        let h = 2 + 9 * open
        var m = Path()
        m.move(to: CGPoint(x: cx - w / 2, y: y))
        m.addQuadCurve(to: CGPoint(x: cx + w / 2, y: y), control: CGPoint(x: cx, y: y + 1.5 * smile))
        m.addQuadCurve(to: CGPoint(x: cx - w / 2, y: y), control: CGPoint(x: cx, y: y + h * 2))
        m.closeSubpath()
        ctx.fill(m, with: .color(.avMouth))
        var inside = ctx
        inside.clip(to: m)
        inside.fill(ellipse(cx, y + h * 1.25, w * 0.34, h * 0.55), with: .color(.avTongue))
        inside.fill(Path(CGRect(x: cx - w / 2, y: y - 1, width: w, height: min(3, 1 + h * 0.25))), with: .color(.white))
        ctx.stroke(m, with: .color(.avLip), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
    }
}

/// Avatar card + speech/thought bubbles + label. Purely presentational.
struct AvatarStage: View {
    var mood: AvatarMood
    var mouth: CGFloat
    var tilt: CGFloat
    var lookUp: CGFloat
    var blink: CGFloat
    var brow: CGFloat
    var smile: CGFloat
    var level: CGFloat
    var breathing: Bool = false   // gentle bob, 20 fps TimelineView (paused when false)
    var nod: CGFloat = 0
    var thinkingPhase: Int
    var bubbleText: String?
    var highlight: NSRange?
    var label: String
    var textColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.90),
                                                  Color(red: 0.84, green: 0.82, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if mood == .listening {
                    Circle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 3)
                        .frame(width: 150 + level * 30, height: 150 + level * 30)
                        .opacity(0.25 + Double(level) * 0.6)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !breathing)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let bob = breathing ? CGFloat(sin(t * 2 * .pi / 4.8)) * 2 : 0
                    AvatarFigure(mouth: mouth, tilt: tilt, lookUp: lookUp, blink: blink,
                                 brow: brow, smile: smile, waves: mood == .listening ? max(0.15, level) : 0)
                        .frame(width: 186, height: 186)
                        .offset(y: 8 + bob + nod)
                }
            }
            .frame(width: 190, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topTrailing) {
                if mood == .thinking { thoughtBubble.padding(10) }
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 8) {
                if let text = bubbleText, !text.isEmpty {
                    speechBubble(text)
                } else {
                    Text(label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(textColor)
                    if mood == .listening {
                        levelBar
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var levelBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(textColor.opacity(CGFloat(i) / 8 < level ? 0.9 : 0.2))
                    .frame(width: 5, height: 6 + CGFloat(i % 4) * 4)
            }
        }
    }

    private var thoughtBubble: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(red: 0.47, green: 0.40, blue: 0.86))
                    .frame(width: 6, height: 6)
                    .scaleEffect(thinkingPhase % 3 == i ? 1.35 : 0.8)
                    .opacity(thinkingPhase % 3 == i ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Capsule().fill(.white))
        .overlay(alignment: .bottomLeading) {
            Circle().fill(.white).frame(width: 7, height: 7).offset(x: -2, y: 8)
        }
        .animation(.easeInOut(duration: 0.25), value: thinkingPhase)
    }

    private func speechBubble(_ text: String) -> some View {
        var attr = AttributedString(text)
        if let r = highlight, let range = Range(r, in: text),
           let lower = AttributedString.Index(range.lowerBound, within: attr),
           let upper = AttributedString.Index(range.upperBound, within: attr) {
            attr[lower..<upper].backgroundColor = Color(red: 1.0, green: 0.86, blue: 0.45)
            attr[lower..<upper].font = .body.weight(.bold)
        }
        return Text(attr)
            .font(.body)
            .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.22))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.95)))
            .overlay(alignment: .leading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: -9, y: 7)); p.addLine(to: CGPoint(x: 0, y: 14))
                }
                .fill(.white.opacity(0.95))
                .frame(width: 1, height: 14)
            }
    }
}
