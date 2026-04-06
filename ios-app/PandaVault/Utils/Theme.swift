import SwiftUI

/// PandaVault 主题色 — 跟随系统深浅色，只定义强调色
enum PV {
    static let cyan = Color(red: 30/255, green: 180/255, blue: 210/255)
    static let pink = Color.pink
    static let green = Color.green
    static let orange = Color.orange
}

/// 标签胶囊
struct PixelTag: View {
    let text: String
    var color: Color = PV.cyan

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 进度条
struct PixelProgressBar: View {
    let progress: Double
    var color: Color = PV.cyan

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 6)
    }
}

/// 像素风按钮样式
struct PixelButtonStyle: ButtonStyle {
    var color: Color = PV.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .monospaced).bold())
            .tracking(1)
            .foregroundStyle(color == PV.cyan ? Color(.systemBackground) : .primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

/// Section 标题
struct PixelSectionHeader: View {
    let title: String
    var count: String? = nil

    var body: some View {
        HStack {
            Text(title)
            if let count {
                Spacer()
                Text(count)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
