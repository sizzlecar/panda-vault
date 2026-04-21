# PandaVault · 奶油软萌方向 — 设计交付

> 给未来的自己 / Claude Code / 接手开发者的一份对齐文档。
> 原型文件：`素材库 Redesign.html`（9 屏 iPhone 设计，对齐当前 SwiftUI 代码的真实数据模型）。

---

## 0 · 一分钟速览

- **风格定位**：奶油色 · 软萌 · 手写感衬线 + 等宽数字 · 柔和阴影 · 无荧光色
- **对齐代码**：基于现有 `Asset` / `Folder` / `UploadTask` 数据模型，**不**引入 Projects / Favorites / Tags 等代码里不存在的概念
- **9 屏**：素材库(时间/文件夹) · 文件夹详情 · 素材详情 · 上传 · 上传文件夹选择器 · 设置 · 最近删除 · 磁盘信息
- **输出保真度**：hi-fi prototype（非最终视觉稿）。字号、间距、圆角、色值都按 iOS HIG 对齐；可直接按图改 SwiftUI。

---

## 1 · 设计令牌 (Design Tokens)

把这一节塞进 `Theme.swift` 即可替换现有像素风 theme。

### 1.1 颜色
| Token | Hex | 用途 |
|---|---|---|
| `bg`       | `#F7EFE2` | 页面底色（奶油） |
| `paper`    | `#FFF9EE` | 卡片/列表底 |
| `ink`      | `#3D2E27` | 主要文字（深棕，非纯黑） |
| `sub`      | `#7A6A60` | 次要文字 |
| `muted`    | `#B3A69C` | 禁用/占位文字 |
| `line`     | `rgba(61,46,39,0.08)` | 描边/分割 |
| `divider`  | `rgba(61,46,39,0.06)` | 更细的分割线 |
| `peach`    | `#E8B89B` | 强调 1 — 柔桃 |
| `caramel`  | `#C68B5F` | 强调 2 — 焦糖（主 CTA / 选中 tab） |
| `bean`     | `#5D453A` | 强调 3 — 黑豆（文本强调 / 选中态） |
| `mint`     | `#A8C4A2` | 正向（已同步 / 成功） |
| `berry`    | `#D07A7A` | 破坏（删除 / 离线 / 倒计时） |

> ⚠️ 原 `Theme.swift` 是像素冷色 cyan/pink/green/orange — **全部替换**。

### 1.2 字体
```swift
// Display (标题 / 大数字)
Fraunces 500 opsz 72   — 时间视图 month 标题
Fraunces 500 opsz 56   — 磁盘用量大数字
Fraunces 500 opsz 20   — 卡片标题

// Body (中文正文 / UI)
HarmonyOS Sans SC / PingFang SC / Noto Sans SC
Regular 15/22 · Medium 13/18 · Semibold 11 CAPS 作为 section header

// Mono (文件名 / 尺寸 / 时长 / 校验码)
JetBrains Mono 500 — 12–14pt
```

### 1.3 圆角 · 间距 · 阴影
- **圆角**：8（chip） · 14（按钮 / 输入框） · 20（卡片 / iOS section） · 24（tab bar / 浮层） · 28（底部大卡片）
- **间距**：4 · 8 · 12 · 16 · 20 · 24 · 32（按 iOS 16pt 栅格）
- **卡片阴影**：`0 8px 24px rgba(61,46,39,0.08)` + `inset 0 0 0 1px rgba(61,46,39,0.04)`
- **浮层阴影**：`0 20px 50px rgba(61,46,39,0.15)`

---

## 2 · 9 屏清单（对应 SwiftUI View）

| # | 原型 artboard | 对应 SwiftUI View | 状态 | 备注 |
|---|---|---|---|---|
| 1 | `CreamTimeline` — 素材库 · 时间视图 | `GalleryView`（timeline 模式） | 已实现 | 按月分组，月标题用 Fraunces 大字 |
| 2 | `CreamFolders` — 素材库 · 文件夹 | `GalleryView`（folder 模式） | 已实现 | 顶级 folder 卡片网格 |
| 3 | `CreamFolderDetail` — 文件夹详情 | `FolderDetailView` | 已实现 | 面包屑 + 支持嵌套文件夹 + 子资产网格 |
| 4 | `CreamDetail` — 素材详情 | `AssetDetailView` | 已实现 | 沉浸模式（深底），底部抽屉含元信息 |
| 5 | `CreamUpload` — 上传 | `UploadView` | 已实现 | 正在上传 / 等待 / 已完成 三段 |
| 6 | `CreamFolderPicker` — 上传目标选择 | **待新增** `FolderPickerSheet` | 🆕 新设计 | 上传前选目标文件夹的 sheet |
| 7 | `CreamSettings` — 设置 | `SettingsView` | 已实现 | iOS grouped list 风格 |
| 8 | `CreamTrash` — 最近删除 | `TrashView` | 已实现 | 7 天倒计时 chip (berry 色) |
| 9 | `CreamDiskInfo` — 磁盘信息 | `DiskInfoView` | 已实现 | 多卷 · 大数字用量 · 清理入口 |

---

## 3 · 组件规范

### 3.1 Tab Bar (`CTabBar`)
- 浮在底部，16pt 左右间距，距底 14pt
- 白色圆角 24 容器，内部 3 个 flex 项
- **选中**：焦糖色填充 + 白字 / 图标
- **未选中**：透明 + `sub` 色
- 高度 66，内部 tab 高 54

### 3.2 Nav Bar (`CNavBar`)
- 44pt 高，左 Back（焦糖色 "< 返回"）、中标题、右 action
- 不加毛玻璃 —— 和奶油底直接融合
- 深色页面（`CreamDetail`）用白字

### 3.3 iOS Grouped List (`CSection` / `CRow`)
- Section header：11pt 全大写 letterSpacing 1.5 muted 色
- Card 白底 圆角 20 inset 描边
- Row 13/16pt padding · icon 22×22 · title 15pt · value 14pt `sub` 色 · `>` chevron

### 3.4 Panda Mascot (`CPandaHi`)
- 用 `assets/panda-mascot-cropped.png`
- 圆形裁切 · 默认 36pt · 仅在问候语 / 空状态使用
- **不要**做成应用图标（那条路走不通，单独处理）

### 3.5 Chip (`CChip`)
- 28pt 高 · 圆角 14 · 13pt 500
- active: 实心焦糖白字 / default: 白底 inset 描边 sub 色 / dashed: 虚线边（"+ 新建"用）

---

## 4 · 数据模型对齐（重要）

原型里所有假数据都基于真实 model 字段，改代码时字段能直接对上：

```swift
struct Asset {
    let id: UUID
    let kind: AssetKind        // .photo / .video
    let width: Int
    let height: Int
    let durationSec: Double?   // 仅 video
    let sizeBytes: Int64
    let shootAt: Date?         // 拍摄时间（驱动时间视图）
    let importedAt: Date
    let folderId: UUID?
    // ...
}

struct Folder {
    let id: UUID
    let name: String
    let parentId: UUID?        // 支持嵌套
    let assetCount: Int
    let totalBytes: Int64
}
```

原型里**不存在**的概念（不要加进代码）：
- ❌ Projects / 项目
- ❌ Favorites / 收藏
- ❌ Tags / 标签
- ❌ Draft / 草稿状态
- ❌ 单资产评论

---

## 5 · 6 屏 — 待新增：文件夹选择器

原 `UploadView` 上传时需要一个「选择目标文件夹」的入口，当前代码里没有。原型里 `CreamFolderPicker` 给出了参考：

- sheet 形式 presentation
- 顶部搜索 + "新建文件夹" 按钮
- 列表支持层级展开（用缩进 + chevron）
- 选中后 checkmark · 底部 "选择" CTA（焦糖色）

建议在 SwiftUI 里加：`FolderPickerSheet(selected: $folderId)`，`UploadView` 触发。

---

## 6 · 已知缺口 & 下一步

- [ ] **App Icon** — 单独处理（像素风 or 奶油风待定）
- [ ] **空状态插画** — 目前用 panda-mascot 占位，后续需要 2–3 张场景插图（空素材库 / 空回收站 / 空文件夹）
- [ ] **Loading / 骨架屏** — 原型里省略，实现时用 line / divider 色做 shimmer
- [ ] **深色模式** — 当前所有屏仅浅色。深色版可用 `bean` 作底 + `paper` 作卡片，下次迭代
- [ ] **无障碍** — 字号可缩放（用 SwiftUI `.dynamicTypeSize`）· 焦糖/白对比度 AA 通过 · 破坏按钮配图标不仅靠颜色

---

## 7 · 文件索引

```
素材库 Redesign.html        ← 打开即见完整原型
design-canvas.jsx           ← 画布（可拖拽排序 artboard · 双击放大）
ios-frame.jsx               ← iPhone 外框
src/shared.jsx              ← StatusBar / Phone / Icon / PandaGlyph / placeholder 数据
src/cream.jsx               ← 9 屏全部组件 (1036 行)
assets/panda-mascot-*.png   ← 吉祥物素材
HANDOFF.md                  ← 本文档
```

---

## 8 · 给 Claude Code 的迁移 prompt 模板

```
请把 PandaVault 现有 SwiftUI 代码从像素风切换到「奶油软萌」方向。

1. 替换 Theme.swift —— 参考 HANDOFF.md 第 1 节的 Design Tokens
2. 全局字体：Display 用 Fraunces，Body 用 HarmonyOS Sans SC，Mono 用 JetBrains Mono
3. 逐屏对照 HANDOFF.md 第 2 节的对应表，调整每个 View 的颜色 / 字体 / 间距 / 圆角
4. 新增 FolderPickerSheet（参考原型中 CreamFolderPicker）
5. 禁止引入原型中不存在的功能：无 Projects / Favorites / Tags / Draft

原型可视参考：打开项目里的 "素材库 Redesign.html"，对应截图见各 artboard。
```
