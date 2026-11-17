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
    static let avSkirt     = Color(red: 0.36, green: 0.31, blue: 0.76)
    static let avSkirtDark = Color(red: 0.24, green: 0.20, blue: 0.56)
    static let avShoe      = Color(red: 0.56, green: 0.22, blue: 0.38)
}

/// The girl herself (full body), drawn in a 200×400 design space. Animatable so SwiftUI
/// interpolates expression changes only while an animation is running.
struct AvatarFigure: View, Animatable, Equatable {
    var mouth: CGFloat = 0     // 0 closed … 1 wide open
    var tilt: CGFloat = 0      // head tilt in degrees
    var lookUp: CGFloat = 0    // 0 straight … 1 glancing up
    var blink: CGFloat = 0     // 0 open … 1 closed
    var brow: CGFloat = 0      // -1 concerned … 0 relaxed … 1 raised
    var smile: CGFloat = 0.8   // -1 frown … 1 big smile
    var waves: CGFloat = 0     // 0 none … 1 loud (listening sound waves by the cupped hand)
    // Hand positions in design space; arms are solved with two-link IK.
    var handL = CGPoint(x: 63, y: 249)
    var handR = CGPoint(x: 137, y: 249)

    typealias Face = AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                    AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>>
    var animatableData: AnimatablePair<Face, AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get { AnimatablePair(AnimatablePair(AnimatablePair(mouth, tilt),
                                            AnimatablePair(AnimatablePair(lookUp, blink), AnimatablePair(brow, smile))),
                             AnimatablePair(handL.animatableData, handR.animatableData)) }
        set {
            let f = newValue.first
            mouth = f.first.first; tilt = f.first.second
            lookUp = f.second.first.first; blink = f.second.first.second
            brow = f.second.second.first; smile = f.second.second.second
            handL.animatableData = newValue.second.first
            handR.animatableData = newValue.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 200, size.height / 400)
            ctx.translateBy(x: (size.width - 200 * s) / 2, y: (size.height - 400 * s) / 2)
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

        // ---- Legs, socks and shoes
        for x in [CGFloat(90), 110] {
            var leg = Path(); leg.move(to: CGPoint(x: x, y: 288)); leg.addLine(to: CGPoint(x: x, y: 360))
            base.stroke(leg, with: .color(.avSkinShade), style: StrokeStyle(lineWidth: 13, lineCap: .round))
            base.stroke(leg, with: .color(.avSkin), style: StrokeStyle(lineWidth: 11.4, lineCap: .round))
            var sock = Path(); sock.move(to: CGPoint(x: x, y: 346)); sock.addLine(to: CGPoint(x: x, y: 362))
            base.stroke(sock, with: .color(.white), style: StrokeStyle(lineWidth: 12.6, lineCap: .butt))
            let sx = x < 100 ? x - 4 : x + 4
            let shoe = Path(roundedRect: CGRect(x: sx - 12, y: 359, width: 24, height: 12), cornerRadius: 6)
            base.fill(shoe, with: .linearGradient(Gradient(colors: [.avShoe.opacity(0.85), .avShoe]),
                                                  startPoint: CGPoint(x: sx, y: 359), endPoint: CGPoint(x: sx, y: 371)))
            var strap = Path(); strap.move(to: CGPoint(x: x - 6, y: 361)); strap.addLine(to: CGPoint(x: x + 6, y: 361))
            base.stroke(strap, with: .color(.avShoe), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            base.fill(ellipse(sx + (x < 100 ? -5 : 5), 362.5, 3.5, 1.6), with: .color(.white.opacity(0.35)))
        }
        // soft ground shadow
        var ground = base
        ground.addFilter(.blur(radius: 4))
        ground.fill(ellipse(100, 374, 34, 4), with: .color(.black.opacity(0.18)))

        // ---- Skirt (A-line, knee length)
        var skirt = Path()
        skirt.move(to: CGPoint(x: 80, y: 234))
        skirt.addLine(to: CGPoint(x: 120, y: 234))
        skirt.addCurve(to: CGPoint(x: 148, y: 300), control1: CGPoint(x: 132, y: 252), control2: CGPoint(x: 143, y: 280))
        skirt.addQuadCurve(to: CGPoint(x: 52, y: 300), control: CGPoint(x: 100, y: 314))
        skirt.addCurve(to: CGPoint(x: 80, y: 234), control1: CGPoint(x: 57, y: 280), control2: CGPoint(x: 68, y: 252))
        skirt.closeSubpath()
        base.fill(skirt, with: .linearGradient(Gradient(colors: [.avSkirt, .avSkirtDark]),
                                               startPoint: CGPoint(x: 100, y: 234), endPoint: CGPoint(x: 100, y: 308)))
        for (a, b) in [(CGPoint(x: 90, y: 240), CGPoint(x: 78, y: 304)), (CGPoint(x: 100, y: 240), CGPoint(x: 100, y: 307)),
                       (CGPoint(x: 110, y: 240), CGPoint(x: 122, y: 304))] {
            var pleat = Path(); pleat.move(to: a); pleat.addLine(to: b)
            base.stroke(pleat, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        var hem = Path()
        hem.move(to: CGPoint(x: 148, y: 300))
        hem.addQuadCurve(to: CGPoint(x: 52, y: 300), control: CGPoint(x: 100, y: 314))
        base.stroke(hem, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // ---- Neck and top (not tilted)
        let neck = Path(roundedRect: CGRect(x: 89, y: 122, width: 22, height: 40), cornerRadius: 8)
        base.fill(neck, with: .linearGradient(Gradient(colors: [.avSkinShade, .avSkin]),
                                              startPoint: CGPoint(x: 100, y: 122), endPoint: CGPoint(x: 100, y: 150)))
        var top = Path()
        top.move(to: CGPoint(x: 86, y: 152))
        top.addLine(to: CGPoint(x: 72, y: 157))
        top.addQuadCurve(to: CGPoint(x: 64, y: 172), control: CGPoint(x: 65, y: 159))
        top.addCurve(to: CGPoint(x: 79, y: 238), control1: CGPoint(x: 64, y: 200), control2: CGPoint(x: 74, y: 222))
        top.addLine(to: CGPoint(x: 121, y: 238))
        top.addCurve(to: CGPoint(x: 136, y: 172), control1: CGPoint(x: 126, y: 222), control2: CGPoint(x: 136, y: 200))
        top.addQuadCurve(to: CGPoint(x: 128, y: 157), control: CGPoint(x: 135, y: 159))
        top.addLine(to: CGPoint(x: 114, y: 152))
        top.addQuadCurve(to: CGPoint(x: 86, y: 152), control: CGPoint(x: 100, y: 170))
        top.closeSubpath()
        base.fill(top, with: .linearGradient(Gradient(colors: [.avTop, .avTopDark]),
                                             startPoint: CGPoint(x: 100, y: 150), endPoint: CGPoint(x: 100, y: 238)))
        base.fill(Path(roundedRect: CGRect(x: 78, y: 230, width: 44, height: 8), cornerRadius: 3), with: .color(.avSkirtDark))
        base.fill(Path(roundedRect: CGRect(x: 96, y: 230.5, width: 8, height: 7), cornerRadius: 2), with: .color(.avAccent))
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

        // ---- Arms (in front of body and hair)
        drawArm(&base, shoulder: CGPoint(x: 71, y: 166), hand: handL, side: -1)
        drawArm(&base, shoulder: CGPoint(x: 129, y: 166), hand: handR, side: 1)

        // listening sound waves next to the cupped hand
        if waves > 0.01 {
            for i in 0..<3 {
                let strength = min(1, max(0, waves * 3 - CGFloat(i)))
                guard strength > 0 else { continue }
                var arc = Path()
                arc.addArc(center: CGPoint(x: handR.x + 6, y: handR.y - 2), radius: 11 + CGFloat(i) * 6,
                           startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                base.stroke(arc, with: .color(Color.avAccent.opacity(0.35 + 0.6 * Double(strength))),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
    }

    private func drawArm(_ ctx: inout GraphicsContext, shoulder S: CGPoint, hand T: CGPoint, side: CGFloat) {
        let l1: CGFloat = 44, l2: CGFloat = 42
        let dx = T.x - S.x, dy = T.y - S.y
        let d = min(l1 + l2 - 0.5, max(abs(l1 - l2) + 4, (dx * dx + dy * dy).squareRoot()))
        let theta = atan2(dy, dx)
        let H = CGPoint(x: S.x + d * cos(theta), y: S.y + d * sin(theta))
        let a = acos(min(1, max(-1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d))))
        let e1 = CGPoint(x: S.x + l1 * cos(theta + a), y: S.y + l1 * sin(theta + a))
        let e2 = CGPoint(x: S.x + l1 * cos(theta - a), y: S.y + l1 * sin(theta - a))
        // Prefer the lower elbow, then the one pointing away from the body (natural, no 'chicken wings').
        func score(_ e: CGPoint) -> CGFloat { e.y + side * (e.x - S.x) * 0.6 }
        let E = score(e1) >= score(e2) ? e1 : e2
        var arm = Path(); arm.move(to: S); arm.addLine(to: E); arm.addLine(to: H)
        ctx.stroke(arm, with: .color(.avSkinShade), style: StrokeStyle(lineWidth: 11.6, lineCap: .round, lineJoin: .round))
        ctx.stroke(arm, with: .color(.avSkin), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        // puff sleeve
        var sleeve = Path(); sleeve.move(to: S)
        sleeve.addLine(to: CGPoint(x: S.x + (E.x - S.x) * 0.42, y: S.y + (E.y - S.y) * 0.42))
        ctx.stroke(sleeve, with: .color(.avTopDark), style: StrokeStyle(lineWidth: 18.5, lineCap: .round))
        ctx.stroke(sleeve, with: .color(.avTop), style: StrokeStyle(lineWidth: 17, lineCap: .round))
        // hand with a little thumb
        let thumb = ellipse(H.x - side * 5.5, H.y - 2.5, 3.4, 2.6)
        ctx.fill(thumb, with: .color(.avSkin))
        ctx.stroke(thumb, with: .color(.avSkinShade), lineWidth: 0.8)
        let palm = ellipse(H.x, H.y, 7, 7.5)
        ctx.fill(palm, with: .color(.avSkin))
        ctx.stroke(palm, with: .color(.avSkinShade), lineWidth: 0.9)
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

/// Three bouncing dots in a little cloud (thinking).
struct ThoughtBubble: View {
    var phase: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(red: 0.47, green: 0.40, blue: 0.86))
                    .frame(width: 8, height: 8)
                    .scaleEffect(phase % 3 == i ? 1.35 : 0.8)
                    .opacity(phase % 3 == i ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Capsule().fill(.white))
        .overlay(alignment: .bottomLeading) {
            Circle().fill(.white).frame(width: 9, height: 9).offset(x: -3, y: 10)
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

/// Small mic level meter.
struct LevelBars: View {
    var level: CGFloat
    var color: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(CGFloat(i) / 8 < level ? 0.9 : 0.25))
                    .frame(width: 4, height: 5 + CGFloat(i % 4) * 3)
            }
        }
    }
}

/// Speech bubble with a tail pointing at the avatar and optional word highlight.
struct TalkBubble<Accessory: View>: View {
    var caption: String
    var text: String
    var highlight: NSRange? = nil
    var tailOnLeading: Bool
    var dim = false
    var marks: [NSRange] = []      // words to strike through (strike) or highlight as fixed
    var strike = false
    var warn = false               // amber underline: "this might be wrong"
    var footnote: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    private let ink = Color(red: 0.16, green: 0.12, blue: 0.22)
    private let paper = Color.white.opacity(0.95)

    var body: some View {
        var attr = AttributedString(text)
        for m in marks {
            guard let range = Range(m, in: text),
                  let lo = AttributedString.Index(range.lowerBound, within: attr),
                  let hi = AttributedString.Index(range.upperBound, within: attr) else { continue }
            if warn {
                attr[lo..<hi].underlineStyle = .thick
                attr[lo..<hi].underlineColor = .orange
                attr[lo..<hi].foregroundColor = Color(red: 0.75, green: 0.42, blue: 0.0)
            } else if strike {
                attr[lo..<hi].strikethroughStyle = .single
                attr[lo..<hi].strikethroughColor = .red
                attr[lo..<hi].foregroundColor = Color(red: 0.80, green: 0.15, blue: 0.20)
            } else {
                attr[lo..<hi].foregroundColor = Color(red: 0.07, green: 0.55, blue: 0.30)
                attr[lo..<hi].font = .title3.weight(.bold)
                attr[lo..<hi].underlineStyle = .single
            }
        }
        if let r = highlight, let range = Range(r, in: text),
           let lower = AttributedString.Index(range.lowerBound, within: attr),
           let upper = AttributedString.Index(range.upperBound, within: attr) {
            attr[lower..<upper].backgroundColor = Color(red: 1.0, green: 0.86, blue: 0.45)
            attr[lower..<upper].font = .title3.weight(.bold)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(ink.opacity(0.55))
                Spacer(minLength: 4)
                accessory()
            }
            Text(attr)
                .font(.title3)
                .foregroundStyle(ink.opacity(dim ? 0.5 : 1))
                .lineLimit(9)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(paper))
        .overlay(alignment: tailOnLeading ? .topLeading : .topTrailing) {
            Path { p in
                if tailOnLeading {
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: -12, y: 10)); p.addLine(to: CGPoint(x: 0, y: 20))
                } else {
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 0, y: 20))
                }
            }
            .fill(paper)
            .frame(width: 1, height: 20)
            .offset(y: 26)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

extension TalkBubble where Accessory == EmptyView {
    init(caption: String, text: String, highlight: NSRange? = nil, tailOnLeading: Bool, dim: Bool = false,
         marks: [NSRange] = [], strike: Bool = false, warn: Bool = false, footnote: String? = nil) {
        self.init(caption: caption, text: text, highlight: highlight, tailOnLeading: tailOnLeading, dim: dim,
                  marks: marks, strike: strike, warn: warn, footnote: footnote) { EmptyView() }
    }
}
