import SwiftUI

/// 像素风主题色彩系统
enum PV {
    // 主色
    static let cyan = Color(red: 50/255, green: 200/255, blue: 220/255)
    static let pink = Color(red: 255/255, green: 140/255, blue: 160/255)
    static let green = Color(red: 80/255, green: 210/255, blue: 130/255)
    static let orange = Color(red: 255/255, green: 180/255, blue: 80/255)
    static let purple = Color(red: 160/255, green: 130/255, blue: 255/255)

    // 背景
    static let bg = Color(red: 18/255, green: 18/255, blue: 24/255)
    static let cardBg = Color(red: 28/255, green: 28/255, blue: 38/255)
    static let surfaceBg = Color(red: 35/255, green: 35/255, blue: 48/255)

    // 文字
    static let textPrimary = Color(red: 240/255, green: 240/255, blue: 245/255)
    static let textSecondary = Color(red: 140/255, green: 140/255, blue: 160/255)
    static let textMuted = Color(red: 80/255, green: 80/255, blue: 100/255)
}

/// 像素风按钮样式
struct PixelButtonStyle: ButtonStyle {
    var color: Color = PV.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .monospaced).weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? color.opacity(0.7) : color, in: RoundedRectangle(cornerRadius: 4))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// 像素风进度条
struct PixelProgressBar: View {
    let progress: Double
    var color: Color = PV.cyan
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(PV.surfaceBg)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}

/// 像素风 Section 标题
struct PixelSectionHeader: View {
    let title: String
    var count: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(PV.cyan)
                .tracking(2)
            if let count {
                Spacer()
                Text(count)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(PV.textMuted)
            }
        }
    }
}

/// 标签胶囊
struct PixelTag: View {
    let text: String
    var color: Color = PV.cyan

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}
