import SwiftUI

// ========== Design Tokens (Cream 奶油软萌) ==========
// 对应 design/HANDOFF.md 第 1 节

enum PV {
    // 背景与纸面
    static let bg      = Color(hex: 0xF7EFE2)   // 页面奶油底
    static let paper   = Color(hex: 0xFFF9EE)   // 卡片/列表底

    // 文字层级
    static let ink     = Color(hex: 0x3D2E27)   // 主要文字（深棕，非纯黑）
    static let sub     = Color(hex: 0x7A6A60)   // 次要
    static let muted   = Color(hex: 0xB3A69C)   // 占位/禁用

    // 线条
    static let line    = Color(hex: 0x3D2E27, alpha: 0.08)
    static let divider = Color(hex: 0x3D2E27, alpha: 0.06)

    // 强调
    static let peach   = Color(hex: 0xE8B89B)   // 柔桃（次要强调）
    static let caramel = Color(hex: 0xC68B5F)   // 焦糖（主 CTA / 选中）
    static let bean    = Color(hex: 0x5D453A)   // 黑豆（文本重强调）

    // 语义
    static let mint    = Color(hex: 0xA8C4A2)   // 正向（已同步 / 成功）
    static let berry   = Color(hex: 0xD07A7A)   // 破坏（删除 / 离线 / 倒计时）

    // ---------- 兼容别名（逐步迁移用，勿在新代码使用） ----------
    static let cyan    = caramel   // 旧 "主色"
    static let pink    = berry     // 旧 "失败"
    static let green   = mint      // 旧 "成功"
    static let orange  = peach     // 旧 "警告"
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// ========== 字体系统 ==========
// 对应 HANDOFF 第 1.2 节
//   Display → Fraunces （variable font, 用 opsz 做"大标题肥大+小尺寸收敛"）
//   Mono    → JetBrainsMono（文件名/尺寸/时长/校验码）
//   Body    → PingFang SC / system（HANDOFF 把 PingFang SC 列为 HarmonyOS 的可接受 fallback）

enum PVFont {
    /// Display 衬线（Fraunces）。通常用于大标题、月份 header、大数字用量
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.custom("Fraunces", size: size).weight(weight)
    }

    /// 等宽（JetBrainsMono）。用于文件名、尺寸、时长、计数、时间戳等"数据值"
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight.rawValue >= Font.Weight.medium.rawValue
            ? "JetBrainsMono-Medium"
            : "JetBrainsMono-Regular"
        return Font.custom(name, size: size)
    }

    /// 正文（系统 + PingFang SC 自动落盘）
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// 小全大写 section header（11pt letterSpacing 1.5 semibold muted）
    static var sectionHeader: Font {
        .system(size: 11, weight: .semibold, design: .default)
    }
}

private extension Font.Weight {
    /// 比较用数值（不精确但够区分 regular/medium）
    var rawValue: Double {
        switch self {
        case .ultraLight: return 100
        case .thin:       return 200
        case .light:      return 300
        case .regular:    return 400
        case .medium:     return 500
        case .semibold:   return 600
        case .bold:       return 700
        case .heavy:      return 800
        case .black:      return 900
        default:          return 400
        }
    }
}

// ========== 组件原语 ==========
// 对应 cream.jsx 的 CChip / CSection / CRow / CNavBar / CPandaHi / CProgressBar / CButtonStyle

/// 圆角 chip（28pt 高，13pt 500，active 焦糖填充白字）
struct CChip: View {
    let text: String
    var active: Bool = false
    var tone: Color = PV.caramel
    var dashed: Bool = false
    var mono: Bool = false

    var body: some View {
        Text(text)
            .font(mono ? PVFont.mono(13, weight: .medium) : PVFont.body(13, weight: .medium))
            .foregroundStyle(active ? .white : PV.sub)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(
                Group {
                    if active { Capsule().fill(tone) }
                    else { Capsule().fill(Color.white) }
                }
            )
            .overlay(
                Group {
                    if dashed {
                        Capsule().strokeBorder(PV.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else if !active {
                        Capsule().strokeBorder(PV.line, lineWidth: 1)
                    }
                }
            )
    }
}

/// iOS grouped list section 包装器
struct CSection<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header.uppercased())
                    .font(PVFont.sectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(PV.muted)
                    .padding(.leading, 4)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(PV.line, lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(PV.sub)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .lineSpacing(1.5)
            }
        }
        .padding(.bottom, 18)
    }
}

/// 列表行（icon tint 圆角小方块 + title + value + chevron）
struct CRow<Trailing: View>: View {
    let icon: String?
    var iconTint: Color = PV.caramel
    let title: String
    var titleColor: Color? = nil
    var isDestructive: Bool = false
    var dividerBelow: Bool = true
    @ViewBuilder let trailing: () -> Trailing
    var onTap: (() -> Void)? = nil

    init(
        icon: String? = nil,
        iconTint: Color = PV.caramel,
        title: String,
        titleColor: Color? = nil,
        isDestructive: Bool = false,
        dividerBelow: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        onTap: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.titleColor = titleColor
        self.isDestructive = isDestructive
        self.dividerBelow = dividerBelow
        self.trailing = trailing
        self.onTap = onTap
    }

    var body: some View {
        let titleFg: Color = isDestructive ? PV.berry : (titleColor ?? PV.ink)
        HStack(spacing: 12) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(iconTint.opacity(0.13))
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                .frame(width: 30, height: 30)
            }
            Text(title)
                .font(PVFont.body(14.5, weight: isDestructive ? .medium : .regular))
                .foregroundStyle(titleFg)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .overlay(alignment: .bottom) {
            if dividerBelow {
                Rectangle().fill(PV.divider).frame(height: 0.5).padding(.leading, icon == nil ? 16 : 58)
            }
        }
    }
}

/// 圆形裁切熊猫头像（用于问候/空状态，**不**做成 App Icon）
struct CPandaHi: View {
    var size: CGFloat = 36

    var body: some View {
        Image("PandaMascot")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(PV.bean.opacity(0.12), lineWidth: 1))
            .background(Circle().fill(Color(hex: 0xF1ECE3)))
    }
}

/// 奶油风格进度条（焦糖填充，圆角 capsule，6pt 高）
struct CProgressBar: View {
    let progress: Double
    var color: Color = PV.caramel
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PV.line)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}

/// 主 CTA 按钮样式（焦糖实心 / pill 圆角 14）
struct CButtonStyle: ButtonStyle {
    var tone: Color = PV.caramel
    var filled: Bool = true
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        configuration.label
            .font(PVFont.body(15, weight: .semibold))
            .foregroundStyle(filled ? .white : tone)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? tone : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(filled ? Color.clear : PV.line, lineWidth: 1)
            )
            .opacity(isPressed ? 0.85 : 1.0)
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

// ========== 大标题（Fraunces 34pt）==========
// 对应 cream.jsx 里所有 "素材库 / 上传 / 设置" 等页面顶部的大标题
// 配合 `.toolbar(.hidden, for: .navigationBar)` 一起用，替代系统 `.navigationTitle`

struct CLargeTitle: View {
    let text: String
    var trailing: (() -> AnyView)? = nil

    init(_ text: String) { self.text = text }

    init<Trailing: View>(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.text = text
        self.trailing = { AnyView(trailing()) }
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(text)
                .font(PVFont.display(34, weight: .medium))
                .foregroundStyle(PV.ink)
                .kerning(-0.6)
            Spacer()
            if let t = trailing { t() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

// ========== Cream 搜索胶囊 ==========

struct CSearchPill: View {
    @Binding var text: String
    var prompt: String = "搜索素材…"
    var onSubmit: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PV.muted)
            TextField(prompt, text: $text)
                .font(PVFont.body(13.5))
                .tint(PV.caramel)
                .foregroundStyle(PV.ink)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(PV.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PV.ink.opacity(0.065))
        )
    }
}

// ========== 兼容层 ==========
// 下列组件在旧代码里大量使用；换皮但保留 API，避免一次性大改。
// 迁移完后可以逐步替换成新组件（CChip/CSection 等）。

/// [兼容] 胶囊标签 —— 重绘为奶油 chip
struct PixelTag: View {
    let text: String
    var color: Color = PV.caramel

    var body: some View {
        Text(text)
            .font(PVFont.mono(11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

/// [兼容] 进度条
typealias PixelProgressBar = CProgressBar

/// [兼容] 按钮样式
struct PixelButtonStyle: ButtonStyle {
    var color: Color = PV.caramel

    func makeBody(configuration: Configuration) -> some View {
        CButtonStyle(tone: color, filled: true, height: 44)
            .makeBody(configuration: configuration)
    }
}

/// [兼容] Section 标题
struct PixelSectionHeader: View {
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(PVFont.sectionHeader)
                .tracking(1.5)
                .foregroundStyle(PV.muted)
            if let count {
                Spacer()
                Text(count)
                    .font(PVFont.mono(11))
                    .foregroundStyle(PV.muted)
            }
        }
    }
}
