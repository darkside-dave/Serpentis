// Original, code-drawn device diagram. No product photograph or Razer logo assets.
import SwiftUI

struct NagaBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 39, y: 47))
        p.addCurve(to: CGPoint(x: 103, y: 9), control1: CGPoint(x: 47, y: 25), control2: CGPoint(x: 76, y: 18))
        p.addLine(to: CGPoint(x: 122, y: 10))
        p.addCurve(to: CGPoint(x: 182, y: 29), control1: CGPoint(x: 149, y: 20), control2: CGPoint(x: 170, y: 16))
        p.addCurve(to: CGPoint(x: 201, y: 102), control1: CGPoint(x: 191, y: 43), control2: CGPoint(x: 182, y: 75))
        p.addCurve(to: CGPoint(x: 231, y: 163), control1: CGPoint(x: 207, y: 122), control2: CGPoint(x: 231, y: 134))
        p.addCurve(to: CGPoint(x: 216, y: 260), control1: CGPoint(x: 233, y: 195), control2: CGPoint(x: 232, y: 231))
        p.addCurve(to: CGPoint(x: 151, y: 311), control1: CGPoint(x: 198, y: 294), control2: CGPoint(x: 177, y: 312))
        p.addCurve(to: CGPoint(x: 57, y: 284), control1: CGPoint(x: 111, y: 317), control2: CGPoint(x: 77, y: 308))
        p.addCurve(to: CGPoint(x: 28, y: 188), control1: CGPoint(x: 34, y: 255), control2: CGPoint(x: 26, y: 216))
        p.addCurve(to: CGPoint(x: 39, y: 47), control1: CGPoint(x: 26, y: 141), control2: CGPoint(x: 28, y: 78))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 240, y: rect.height / 320)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct NagaIllustration: View {
    var wheel = AnyShapeStyle(Color(red: 0.35, green: 0.91, blue: 0.20))
    var logo = AnyShapeStyle(Color(red: 0.35, green: 0.91, blue: 0.20))
    private let edge = Color.white.opacity(0.14)

    var body: some View {
        ZStack(alignment: .topLeading) {
            NagaBodyShape()
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.065), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(NagaBodyShape().stroke(edge, lineWidth: 1.2))
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 6)
            // Broad right finger rest, distinct from the main right-click panel.
            Path { p in
                p.move(to: CGPoint(x: 190, y: 100))
                p.addCurve(to: CGPoint(x: 185, y: 279), control1: CGPoint(x: 214, y: 149), control2: CGPoint(x: 215, y: 230))
                p.addCurve(to: CGPoint(x: 203, y: 285), control1: CGPoint(x: 192, y: 292), control2: CGPoint(x: 198, y: 291))
                p.addCurve(to: CGPoint(x: 226, y: 164), control1: CGPoint(x: 224, y: 249), control2: CGPoint(x: 231, y: 198))
                p.addCurve(to: CGPoint(x: 190, y: 100), control1: CGPoint(x: 224, y: 139), control2: CGPoint(x: 201, y: 120))
            }.fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.045)], startPoint: .leading, endPoint: .trailing))
            Path { p in
                p.move(to: CGPoint(x: 190, y: 100))
                p.addCurve(to: CGPoint(x: 185, y: 279), control1: CGPoint(x: 214, y: 149), control2: CGPoint(x: 215, y: 230))
            }.stroke(Color.black.opacity(0.7), lineWidth: 2)
            // Independent main click panels and a recessed center channel.
            Path { p in
                p.move(to: CGPoint(x: 50, y: 44)); p.addLine(to: CGPoint(x: 103, y: 15))
                p.addLine(to: CGPoint(x: 101, y: 112))
                p.addCurve(to: CGPoint(x: 52, y: 135), control1: CGPoint(x: 83, y: 116), control2: CGPoint(x: 66, y: 124))
                p.closeSubpath()
            }.fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(clickSeams)
            Path { p in
                p.move(to: CGPoint(x: 128, y: 16))
                p.addCurve(to: CGPoint(x: 179, y: 34), control1: CGPoint(x: 152, y: 24), control2: CGPoint(x: 169, y: 23))
                p.addCurve(to: CGPoint(x: 191, y: 118), control1: CGPoint(x: 184, y: 55), control2: CGPoint(x: 181, y: 83))
                p.addLine(to: CGPoint(x: 133, y: 114)); p.closeSubpath()
            }.fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(rightSeam)
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.035)).frame(width: 30, height: 164).position(x: 116, y: 92)
            RoundedRectangle(cornerRadius: 6).fill(wheel).frame(width: 24, height: 62).position(x: 116, y: 65)
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08)).frame(width: 17, height: 60).position(x: 116, y: 65)
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.15)).frame(width: 15, height: 1.5)
                    .position(x: 116, y: 38 + CGFloat(i) * 4.8)
            }
            hardwareKey(width: 22, height: 19).position(x: 116, y: 128)
            hardwareKey(width: 22, height: 19).position(x: 116, y: 153)
            hardwareKey(width: 16, height: 32).rotationEffect(.degrees(12)).position(x: 40, y: 61)
            hardwareKey(width: 16, height: 32).rotationEffect(.degrees(8)).position(x: 34, y: 99)
            ForEach(0..<11, id: \.self) { row in
                ForEach(0..<3, id: \.self) { col in
                    Circle().fill(Color.white.opacity(0.055)).frame(width: 1.4, height: 1.4)
                        .position(x: 208 + CGFloat(col) * 4, y: 161 + CGFloat(row) * 7)
                }
            }
            Image(systemName: "waveform.path").font(.system(size: 30, weight: .light)).foregroundStyle(logo).position(x: 125, y: 244)
            Text("SERPENTIS").font(.system(size: 7, weight: .medium, design: .rounded)).tracking(2)
                .foregroundStyle(Color.white.opacity(0.30)).position(x: 125, y: 270)
        }.frame(width: 240, height: 320)
            .accessibilityHidden(true)
    }

    private func hardwareKey(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)], startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: 1.5)).frame(width: width, height: height)
    }
    private var clickSeams: some View {
        Path { p in
            p.move(to: CGPoint(x: 103, y: 15)); p.addLine(to: CGPoint(x: 101, y: 112))
            p.addCurve(to: CGPoint(x: 52, y: 135), control1: CGPoint(x: 83, y: 116), control2: CGPoint(x: 66, y: 124))
        }.stroke(Color.black.opacity(0.7), lineWidth: 1.5)
    }
    private var rightSeam: some View {
        Path { p in
            p.move(to: CGPoint(x: 128, y: 16)); p.addLine(to: CGPoint(x: 133, y: 114)); p.addLine(to: CGPoint(x: 191, y: 118))
        }.stroke(Color.black.opacity(0.7), lineWidth: 1.5)
    }
}

struct NagaButtonTarget: View {
    @EnvironmentObject var model: SerpentisModel
    let id: UInt8
    let title: String
    @Binding var selected: UInt8
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        let slot = SerpentisModel.slot(id)
        Button { selected = id } label: {
            Text(title).font(.system(size: 11, weight: .bold))
                .foregroundStyle(selected == id ? Color.black : Color.white)
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected == id ? Color.green.opacity(0.9) : Color.white.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected == id ? Color.green : Color.white.opacity(0.55), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if !model.isDefault(slot) { Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 2, y: -2) }
                }
        }.buttonStyle(.plain).help("\(slot.name): \(model.describe(slot))").accessibilityLabel(slot.name)
    }
}
