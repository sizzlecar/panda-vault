// Cream 奶油软萌 — aligned to PandaVault real data model
// Folders (nested), Assets (photo/video, size, duration, resolution, shootAt)
// NO projects / favorites / tags / draft-status — those don't exist in code.

const C = {
  bg:     '#F7EFE2',
  paper:  '#FFF9EE',
  ink:    '#3D2E27',
  sub:    '#7A6A60',
  muted:  '#B3A69C',
  peach:  '#E8B89B',
  caramel:'#C68B5F',
  bean:   '#5D453A',
  mint:   '#A8C4A2',
  berry:  '#D07A7A',
  line:   'rgba(61,46,39,0.08)',
  divider:'rgba(61,46,39,0.06)',
};

const cDisplay = { fontFamily: 'Fraunces, "Noto Serif SC", serif' };
const cMono = { fontFamily: 'JetBrains Mono, monospace' };

function CChip({ active, children, tone = C.caramel, dashed }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', height: 28, padding: '0 13px',
      borderRadius: 14, fontSize: 13, fontWeight: 500,
      background: active ? tone : '#fff',
      color: active ? '#fff' : C.sub,
      boxShadow: active ? 'none' : `inset 0 0 0 1px ${C.line}`,
      border: dashed ? `1px dashed ${C.muted}` : 'none',
    }}>{children}</span>
  );
}

function CTabBar({ active = 'lib' }) {
  const items = [
    { id: 'lib',   label: '素材库', icon: Icon.grid },
    { id: 'up',    label: '上传',   icon: Icon.upload },
    { id: 'set',   label: '设置',   icon: Icon.gear },
  ];
  return (
    <div style={{
      position: 'absolute', bottom: 14, left: 16, right: 16, height: 66, zIndex: 50,
      background: '#fff',
      borderRadius: 24,
      boxShadow: '0 8px 24px rgba(61,46,39,0.08), 0 0 0 1px rgba(61,46,39,0.04)',
      display: 'flex', alignItems: 'center', padding: 6,
    }}>
      {items.map(it => {
        const on = it.id === active;
        return (
          <div key={it.id} style={{
            flex: 1, height: 54, borderRadius: 18,
            background: on ? C.caramel : 'transparent',
            color: on ? '#fff' : C.sub,
            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 2,
            transition: 'background .2s',
          }}>
            <it.icon width={22} height={22}/>
            <div style={{ fontSize: 10.5, fontWeight: 600 }}>{it.label}</div>
          </div>
        );
      })}
    </div>
  );
}

function CPandaHi({ size = 36 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: size / 2,
      backgroundImage: 'url("assets/panda-mascot-cropped.png")',
      backgroundSize: '118%',
      backgroundPosition: '50% 42%',
      backgroundColor: '#F1ECE3',
      boxShadow: 'inset 0 0 0 1px rgba(93,69,58,0.12)',
      flexShrink: 0,
    }}/>
  );
}

// Native iOS navbar for drill-down screens (matches NavigationStack)
function CNavBar({ title, left, right, dark }) {
  const fg = dark ? '#fff' : C.ink;
  return (
    <div style={{ height: 44, padding: '0 12px', display: 'flex', alignItems: 'center', color: fg, position: 'relative' }}>
      <div style={{ width: 60, fontSize: 17, color: C.caramel, display: 'flex', alignItems: 'center', gap: 2 }}>
        {left}
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, textAlign: 'center', fontSize: 16, fontWeight: 600, color: fg, pointerEvents: 'none' }}>{title}</div>
      <div style={{ flex: 1 }}/>
      <div style={{ minWidth: 60, display: 'flex', justifyContent: 'flex-end', gap: 14, fontSize: 15, color: C.caramel }}>
        {right}
      </div>
    </div>
  );
}

// iOS-style grouped list section wrapper
function CSection({ header, children, footer }) {
  return (
    <div style={{ marginBottom: 18 }}>
      {header && (
        <div style={{ padding: '0 4px 8px', fontSize: 11, color: C.muted, letterSpacing: 1.5, textTransform: 'uppercase', fontWeight: 600 }}>{header}</div>
      )}
      <div style={{ background: '#fff', borderRadius: 20, boxShadow: `inset 0 0 0 1px ${C.line}`, overflow: 'hidden' }}>
        {children}
      </div>
      {footer && (
        <div style={{ padding: '8px 4px 0', fontSize: 11, color: C.sub, lineHeight: 1.5 }}>{footer}</div>
      )}
    </div>
  );
}

function CRow({ icon, iconTint, title, value, chevron, danger, destructive, dividerBelow = true, onTap }) {
  return (
    <div style={{
      padding: '13px 16px', display: 'flex', alignItems: 'center', gap: 12,
      borderBottom: dividerBelow ? `0.5px solid ${C.divider}` : 'none',
    }}>
      {icon && (
        <div style={{ width: 30, height: 30, borderRadius: 9, background: `${iconTint || C.caramel}22`, color: iconTint || C.caramel, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {React.createElement(icon, { width: 16, height: 16 })}
        </div>
      )}
      <div style={{ flex: 1, fontSize: 14.5, color: destructive ? C.berry : (danger ? C.berry : C.ink), fontWeight: destructive ? 500 : 400 }}>{title}</div>
      {value !== undefined && <div style={{ fontSize: 13, color: C.sub, ...(typeof value === 'string' && value.match(/^[\d.]+\s?(GB|MB|KB|B|件|%)/) ? cMono : {}) }}>{value}</div>}
      {chevron && <Icon.chevronRight width={14} height={14} color={C.muted}/>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 1 · Gallery – Timeline (素材库 · 时间视图)
// Maps to: GalleryView.swift · GalleryTimelineView
// Real features: 年/月快速跳转, 月份 section header, 搜索, 图搜图按钮, 选择
// ★ 新增 UX 改进:
//   - 顶部"熊猫管家问候"(NEW: 需后端 `/api/v1/today/brief` 或本地计算)
//   - "最近活跃文件夹"横滚卡 (NEW: 需后端 `/api/v1/folders/recent?limit=6`)
// ─────────────────────────────────────────────────────────────
function CreamTimeline() {
  const monthAssets = [
    MEDIA[2], MEDIA[3], MEDIA[5],
    MEDIA[7], MEDIA[9], MEDIA[6],
    MEDIA[0], MEDIA[1], MEDIA[11],
  ];
  const prevMonthAssets = [MEDIA[4], MEDIA[8], MEDIA[10]];
  const recentFolders = [
    { name: '2026春节',     cover: MEDIA[2], count: 86,  when: '今天'   },
    { name: '护肤品开箱',   cover: MEDIA[3], count: 42,  when: '昨天'   },
    { name: '咖啡馆探店',   cover: MEDIA[5], count: 127, when: '2 天前' },
    { name: '穿搭 SS26',    cover: MEDIA[8], count: 203, when: '3 天前' },
  ];

  return (
    <Phone bg={C.bg}>
      <StatusBar />
      {/* Navigation title — large title like iOS */}
      <div style={{ padding: '4px 20px 0' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 44 }}>
          {/* 左上：图搜图按钮（camera.viewfinder） */}
          <div style={{ width: 34, height: 34, display: 'flex', alignItems: 'center', justifyContent: 'center', color: C.caramel }}>
            <Icon.scan width={22} height={22}/>
          </div>
          {/* 右上：选择 */}
          <div style={{ fontSize: 15, color: C.caramel, fontWeight: 500 }}>选择</div>
        </div>

        {/* ★ NEW · 熊猫管家问候（今天状态） */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 2 }}>
          <CPandaHi size={42}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ ...cDisplay, fontSize: 22, color: C.ink, letterSpacing: -0.4, lineHeight: 1.15, fontWeight: 500 }}>早上好呀～</div>
            <div style={{ fontSize: 11.5, color: C.sub, marginTop: 1 }}>昨天上传了 18 件 · 还有 3 件没同步</div>
          </div>
        </div>
      </div>

      {/* ★ NEW · 最近活跃文件夹 横滚卡 */}
      <div style={{ padding: '14px 0 0' }}>
        <div style={{ padding: '0 20px 6px', display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
          <div style={{ fontSize: 11, color: C.muted, letterSpacing: 1.5, fontWeight: 600, textTransform: 'uppercase' }}>最近在整理</div>
          <div style={{ fontSize: 11, color: C.caramel, fontWeight: 500 }}>查看全部</div>
        </div>
        <div style={{ display: 'flex', gap: 10, overflowX: 'auto', padding: '2px 20px 4px', scrollbarWidth: 'none' }}>
          {recentFolders.map((f, i) => (
            <div key={i} style={{ flex: '0 0 108px', background: '#fff', borderRadius: 12, padding: 5, boxShadow: `inset 0 0 0 1px ${C.line}` }}>
              <div style={{ height: 68, borderRadius: 8, backgroundImage: `url("${placeholderSvg(f.cover)}")`, backgroundSize: 'cover', backgroundPosition: 'center' }}/>
              <div style={{ padding: '5px 3px 2px' }}>
                <div style={{ fontSize: 11.5, color: C.ink, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</div>
                <div style={{ fontSize: 9.5, color: C.muted, ...cMono, marginTop: 1 }}>{f.when} · {f.count}</div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* 搜索栏（对应 .searchable） */}
      <div style={{ padding: '10px 20px 0' }}>
        <div style={{ height: 36, background: 'rgba(120,100,90,0.08)', borderRadius: 10, display: 'flex', alignItems: 'center', padding: '0 10px', gap: 8, color: C.muted }}>
          <Icon.search width={14} height={14} />
          <span style={{ fontSize: 13.5 }}>搜索素材…</span>
        </div>
      </div>

      {/* 时间/文件夹切换（对应 Picker(.segmented)） */}
      <div style={{ padding: '12px 20px 0' }}>
        <div style={{ height: 32, background: 'rgba(120,100,90,0.1)', borderRadius: 8, padding: 2, display: 'flex' }}>
          {['时间', '文件夹'].map((t, i) => {
            const on = i === 0;
            return (
              <div key={t} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 500, color: on ? C.ink : C.sub, background: on ? '#fff' : 'transparent', borderRadius: 7, boxShadow: on ? '0 1px 3px rgba(0,0,0,0.06)' : 'none' }}>{t}</div>
            );
          })}
        </div>
      </div>

      {/* 年份快速跳转 */}
      <div style={{ padding: '10px 20px 4px' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          {['2026年', '2025年', '2024年'].map((y, i) => (
            <CChip key={y} active={i === 0}>{y}</CChip>
          ))}
        </div>
      </div>

      {/* 月份快速跳转 */}
      <div style={{ padding: '6px 20px 2px' }}>
        <div style={{ display: 'flex', gap: 6, overflow: 'hidden' }}>
          {['4月', '3月', '2月', '1月'].map((m, i) => (
            <CChip key={m} active={i === 0}>{m}</CChip>
          ))}
        </div>
      </div>

      {/* 月份 section header（pinned） */}
      <div style={{ padding: '12px 20px 6px', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', background: C.bg, position: 'sticky', top: 0 }}>
        <div style={{ fontSize: 13, color: C.ink, fontWeight: 600, ...cMono }}>2026年4月</div>
        <div style={{ fontSize: 11, color: C.muted, ...cMono }}>22</div>
      </div>

      {/* 3-col adaptive grid, spacing 2（对应 LazyVGrid adaptive minimum 110） */}
      <div style={{ padding: '0 2px', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 2 }}>
        {monthAssets.map((m, i) => (
          <div key={i} style={{ aspectRatio: '1/1', backgroundImage: `url("${placeholderSvg(m)}")`, backgroundSize: 'cover', backgroundPosition: 'center', position: 'relative' }}>
            {m.kind === 'video' && (
              <div style={{ position: 'absolute', bottom: 4, right: 5, color: '#fff', fontSize: 10, ...cMono, textShadow: '0 1px 2px rgba(0,0,0,0.7)', fontWeight: 500 }}>0:{20 + i * 7}</div>
            )}
          </div>
        ))}
      </div>

      <div style={{ padding: '12px 20px 6px', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <div style={{ fontSize: 13, color: C.ink, fontWeight: 600, ...cMono }}>2026年3月</div>
        <div style={{ fontSize: 11, color: C.muted, ...cMono }}>14</div>
      </div>
      <div style={{ padding: '0 2px', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 2 }}>
        {prevMonthAssets.map((m, i) => (
          <div key={i} style={{ aspectRatio: '1/1', backgroundImage: `url("${placeholderSvg(m)}")`, backgroundSize: 'cover', backgroundPosition: 'center' }}/>
        ))}
      </div>

      <div style={{ height: 100 }}/>
      <CTabBar active="lib" />
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 2 · Gallery – Folders (素材库 · 文件夹视图)
// Maps to: GalleryView.swift · GalleryFoldersView
// Real fields: folder.name, folder.assetCount, folder.totalBytes, folder.updatedAt
//              folder.coverUrl (via api.folderCoverURL)
// Real features: 排序 Menu (名称/大小/最近修改 ↑↓), 点击进入 FolderDetail
// ─────────────────────────────────────────────────────────────
function CreamFolders() {
  const folders = [
    { name: '2026春节',       cover: MEDIA[2], count: 86,  size: '4.8 GB',  when: '今天' },
    { name: '护肤品开箱',     cover: MEDIA[3], count: 42,  size: '1.9 GB',  when: '昨天' },
    { name: '咖啡馆探店',     cover: MEDIA[5], count: 127, size: '6.2 GB',  when: '上周' },
    { name: '穿搭合集 SS26',  cover: MEDIA[8], count: 203, size: '3.4 GB',  when: '3天前' },
    { name: '家里的小猫',     cover: MEDIA[4], count: 56,  size: '2.1 GB',  when: '4月15' },
    { name: 'B-roll 背景板',  cover: MEDIA[11],count: null,size: null,      when: '—' },  // 后端懒计算中
  ];

  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <div style={{ padding: '4px 20px 0' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 44 }}>
          <div style={{ width: 34, height: 34, display: 'flex', alignItems: 'center', justifyContent: 'center', color: C.caramel }}>
            <Icon.scan width={22} height={22}/>
          </div>
          <div style={{ fontSize: 15, color: C.caramel, fontWeight: 500 }}>选择</div>
        </div>
        <div style={{ marginTop: 4 }}>
          <div style={{ ...cDisplay, fontSize: 34, color: C.ink, letterSpacing: -0.6, lineHeight: 1.1, fontWeight: 500 }}>素材库</div>
        </div>
      </div>

      {/* 搜索 */}
      <div style={{ padding: '10px 20px 0' }}>
        <div style={{ height: 36, background: 'rgba(120,100,90,0.08)', borderRadius: 10, display: 'flex', alignItems: 'center', padding: '0 10px', gap: 8, color: C.muted }}>
          <Icon.search width={14} height={14} />
          <span style={{ fontSize: 13.5 }}>搜索素材…</span>
        </div>
      </div>

      {/* segmented */}
      <div style={{ padding: '12px 20px 0' }}>
        <div style={{ height: 32, background: 'rgba(120,100,90,0.1)', borderRadius: 8, padding: 2, display: 'flex' }}>
          {['时间', '文件夹'].map((t, i) => {
            const on = i === 1;
            return (
              <div key={t} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 500, color: on ? C.ink : C.sub, background: on ? '#fff' : 'transparent', borderRadius: 7, boxShadow: on ? '0 1px 3px rgba(0,0,0,0.06)' : 'none' }}>{t}</div>
            );
          })}
        </div>
      </div>

      {/* 排序条（对应 Menu<FolderSortOption>） */}
      <div style={{ padding: '12px 20px 6px' }}>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '5px 12px', background: `${C.caramel}15`, borderRadius: 14, color: C.caramel, fontSize: 12, fontWeight: 600 }}>
          <Icon.sort width={12} height={12}/> 名称 ↑
        </div>
      </div>

      {/* ★ UX: 名字放大加粗 + "相对时间 · 件数" 在前 / 大小次要 / 长按菜单提示 */}
      <div style={{ padding: '0 16px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        {folders.map((f, i) => (
          <div key={i} style={{ background: '#fff', borderRadius: 14, padding: 6, boxShadow: `inset 0 0 0 1px ${C.line}` }}>
            <div style={{
              height: 96, borderRadius: 10, overflow: 'hidden',
              backgroundImage: f.cover ? `url("${placeholderSvg(f.cover)}")` : 'none',
              backgroundSize: 'cover', backgroundPosition: 'center',
              background: f.cover ? undefined : 'rgba(120,100,90,0.08)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              {!f.cover && <Icon.folder width={22} height={22} color={C.muted}/>}
            </div>
            <div style={{ padding: '8px 4px 5px' }}>
              {/* name — primary, bigger, sans-serif (not mono — 名字是给人读的) */}
              <div style={{ fontSize: 14, color: C.ink, fontWeight: 600, letterSpacing: -0.1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</div>
              {/* relative-time · count (secondary) */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 5, marginTop: 3, fontSize: 11 }}>
                {f.count == null ? (
                  <span style={{ color: C.muted, ...cMono }}>计算中…</span>
                ) : (
                  <>
                    <span style={{ color: C.sub }}>{f.when}</span>
                    <span style={{ color: C.muted, opacity: 0.5 }}>·</span>
                    <span style={{ color: C.sub, ...cMono }}>{f.count}</span>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      <div style={{ height: 100 }}/>
      <CTabBar active="lib" />
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 3 · FolderDetail (文件夹详情 · 可嵌套)
// Maps to: FolderDetailView.swift
// Real features:
//   - 面包屑 Root / 子 1 / 子 2
//   - 子文件夹 grid + 资产 grid（混合布局）
//   - 在文件夹内搜索
//   - 排序：文件夹 + 照片 双排序
//   - 工具栏菜单：新建子文件夹 / 重命名 / 删除文件夹
// ─────────────────────────────────────────────────────────────
function CreamFolderDetail() {
  const subfolders = [
    { name: '精修图', count: 28, size: '1.2 GB' },
    { name: '原图',   count: 156, size: '8.4 GB' },
    { name: '花絮',   count: null, size: null },
  ];
  const assets = [MEDIA[2], MEDIA[3], MEDIA[5], MEDIA[7], MEDIA[6], MEDIA[0]];

  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <CNavBar
        title="2026春节"
        left={<><Icon.chevronRight width={18} height={18} style={{ transform: 'rotate(180deg)' }}/><span style={{ fontSize: 16 }}>素材库</span></>}
        right={<><span style={{ fontSize: 15 }}>选择</span><div style={{ width: 22, height: 22, display:'flex', alignItems:'center', justifyContent:'center' }}>⋯</div></>}
      />

      {/* 搜索 */}
      <div style={{ padding: '4px 20px 0' }}>
        <div style={{ height: 36, background: 'rgba(120,100,90,0.08)', borderRadius: 10, display: 'flex', alignItems: 'center', padding: '0 10px', gap: 8, color: C.muted }}>
          <Icon.search width={14} height={14} />
          <span style={{ fontSize: 13.5 }}>在「2026春节」中搜索…</span>
        </div>
      </div>

      {/* 面包屑 */}
      <div style={{ padding: '10px 20px 8px', background: 'rgba(255,255,255,0.5)', display: 'flex', gap: 6, alignItems: 'center', ...cMono, fontSize: 11.5 }}>
        <span style={{ color: C.sub }}>素材库</span>
        <span style={{ color: C.muted }}>/</span>
        <span style={{ color: C.caramel, fontWeight: 600 }}>2026春节</span>
      </div>

      {/* 双排序 */}
      <div style={{ padding: '10px 20px 6px', display: 'flex', gap: 8 }}>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '5px 10px', background: `${C.caramel}15`, borderRadius: 12, color: C.caramel, fontSize: 11, fontWeight: 600 }}>
          <Icon.folder width={11} height={11}/> 文件夹 名称 ↑
        </div>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '5px 10px', background: `${C.caramel}15`, borderRadius: 12, color: C.caramel, fontSize: 11, fontWeight: 600 }}>
          <Icon.photos width={11} height={11}/> 照片 最新 ↓
        </div>
      </div>

      {/* 子文件夹 */}
      <div style={{ padding: '8px 12px 0', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {subfolders.map((f, i) => (
          <div key={i} style={{ background: 'rgba(255,255,255,0.7)', backdropFilter: 'blur(8px)', borderRadius: 10, padding: '12px 10px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
            <Icon.folder width={28} height={28} color={C.caramel}/>
            <div style={{ fontSize: 12, color: C.ink, ...cMono, marginTop: 2 }}>{f.name}</div>
            {f.count == null ? (
              <div style={{ fontSize: 10, color: C.muted, ...cMono }}>计算中…</div>
            ) : (
              <>
                <div style={{ fontSize: 10, color: C.sub, ...cMono }}>{f.count} items</div>
                <div style={{ fontSize: 10, color: C.muted, ...cMono }}>{f.size}</div>
              </>
            )}
          </div>
        ))}
      </div>

      {/* 资产 grid */}
      <div style={{ padding: '12px 2px 0', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 2 }}>
        {assets.map((m, i) => (
          <div key={i} style={{ aspectRatio: '1/1', backgroundImage: `url("${placeholderSvg(m)}")`, backgroundSize: 'cover', backgroundPosition: 'center', position: 'relative' }}>
            {m.kind === 'video' && (
              <div style={{ position: 'absolute', bottom: 4, right: 5, color: '#fff', fontSize: 10, ...cMono, textShadow: '0 1px 2px rgba(0,0,0,0.7)', fontWeight: 500 }}>0:{20 + i * 7}</div>
            )}
          </div>
        ))}
      </div>
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 4 · Asset Detail (素材详情)
// Maps to: AssetDetailView.swift
// Real features:
//   - 黑色全屏背景
//   - 左右切换箭头（currentIndex/assets.count）
//   - 关闭 / 索引 / 删除（顶部三按钮 · 图片版）
//   - filename, shootAt, size, resolution（图片底栏信息）
//   - 保存到相册 / 分享 / 移动（三个大按钮）
// ─────────────────────────────────────────────────────────────
function CreamDetail() {
  const m = MEDIA[2];
  return (
    <Phone bg="#000">
      <StatusBar dark />

      {/* 背景图 */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, backgroundImage: `url("${placeholderSvg(m)}")`, backgroundSize: 'cover', backgroundPosition: 'center' }}/>

      {/* 顶部按钮（图片版）*/}
      <div style={{ position: 'absolute', top: 58, left: 16, right: 16, display: 'flex', justifyContent: 'space-between', alignItems: 'center', zIndex: 10 }}>
        <div style={{ width: 40, height: 40, borderRadius: 20, background: 'rgba(255,255,255,0.2)', backdropFilter: 'blur(20px)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff' }}>
          <Icon.close width={18} height={18}/>
        </div>
        <div style={{ padding: '7px 14px', borderRadius: 20, background: 'rgba(255,255,255,0.2)', backdropFilter: 'blur(20px)', color: '#fff', fontSize: 12.5, ...cMono, fontWeight: 600 }}>
          3 / 58
        </div>
        <div style={{ width: 40, height: 40, borderRadius: 20, background: 'rgba(255,255,255,0.2)', backdropFilter: 'blur(20px)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#ff453a' }}>
          <Icon.trash width={17} height={17}/>
        </div>
      </div>

      {/* 左右切换箭头（当 index > 0 和 < count-1 时显示） */}
      <div style={{ position: 'absolute', top: '50%', left: 12, transform: 'translateY(-50%)', width: 36, height: 36, borderRadius: 18, background: 'rgba(0,0,0,0.3)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'rgba(255,255,255,0.6)', zIndex: 10 }}>
        <Icon.chevronRight width={16} height={16} style={{ transform: 'rotate(180deg)' }}/>
      </div>
      <div style={{ position: 'absolute', top: '50%', right: 12, transform: 'translateY(-50%)', width: 36, height: 36, borderRadius: 18, background: 'rgba(0,0,0,0.3)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'rgba(255,255,255,0.6)', zIndex: 10 }}>
        <Icon.chevronRight width={16} height={16}/>
      </div>

      {/* 底部信息栏 — .ultraThinMaterial 深色 */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, background: 'rgba(20,15,12,0.75)', backdropFilter: 'blur(24px)', padding: '16px 20px 28px', color: '#fff' }}>
        {/* filename · size · resolution */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 11.5, color: 'rgba(255,255,255,0.85)' }}>
          <span style={{ ...cMono, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>IMG_6607.HEIC</span>
          <span style={{ ...cMono }}>4.2 MB</span>
          <span style={{ ...cMono }}>4032×3024</span>
        </div>

        {/* 拍摄时间 · shootAt 有时显示"拍摄" */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 8, fontSize: 11, color: 'rgba(255,255,255,0.6)' }}>
          <Icon.clock width={11} height={11}/>
          <span style={{ ...cMono }}>2026-04-18 15:24</span>
          <span style={{ padding: '1px 6px', background: 'rgba(255,255,255,0.15)', borderRadius: 4, fontSize: 10 }}>拍摄</span>
        </div>

        {/* ★ NEW · 备注 (NEW: 需后端 Asset.note 字段 + PATCH /api/v1/assets/:id) */}
        <div style={{ marginTop: 12, padding: '10px 12px', background: 'rgba(255,255,255,0.09)', borderRadius: 10, display: 'flex', alignItems: 'flex-start', gap: 8 }}>
          <div style={{ fontSize: 14, lineHeight: '20px' }}>💄</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, color: 'rgba(255,255,255,0.92)', lineHeight: 1.4 }}>夜间精华 A 对比 B — 留着剪横屏开箱</div>
            <div style={{ fontSize: 10, color: 'rgba(255,255,255,0.4)', marginTop: 3, ...cMono }}>编辑备注 ›</div>
          </div>
        </div>

        {/* 三按钮 — 保存到相册 / 分享 / 移动 */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginTop: 12 }}>
          {[
            { i: Icon.download, l: '保存到相册' },
            { i: Icon.share,    l: '分享' },
            { i: Icon.move,     l: '移动' },
          ].map(a => (
            <div key={a.l} style={{ height: 44, background: 'rgba(255,255,255,0.15)', borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, fontSize: 13.5, color: '#fff', fontWeight: 500 }}>
              <a.i width={15} height={15}/> {a.l}
            </div>
          ))}
        </div>
      </div>
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 5 · Upload (上传)
// Maps to: UploadView.swift
// Real features:
//   - 目标位置 section: 上传到 (FolderPicker) + 新建文件夹
//   - 从相册选择 button (→ PhotosPicker matches videos+images, max 50)
//   - 上传进度汇总 (PixelProgressBar + 计数)
//   - 进行中 / 失败（可重试） / 已完成 (DisclosureGroup)
//   - 每行状态: 等待 WAIT / 上传中 xx% / 完成 DONE / 重复 EXIST / 失败
// ─────────────────────────────────────────────────────────────
function CreamUpload() {
  const active = [
    { name: 'MVI_6607.MOV',  size: '184 MB', pct: 62, isVideo: true },
    { name: 'IMG_6611.HEIC', size: '4.2 MB',  pct: 100, status: 'done' },
    { name: 'IMG_6614.HEIC', size: '3.8 MB',  pct: 100, status: 'dup' },
    { name: 'MVI_6618.MOV',  size: '92 MB',   pct: 0,   status: 'wait', isVideo: true },
  ];

  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <div style={{ padding: '4px 20px 0' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 44 }}>
          <div/>
          <div style={{ width: 34, height: 34, display: 'flex', alignItems: 'center', justifyContent: 'center', color: C.caramel }}>
            <Icon.plus width={22} height={22}/>
          </div>
        </div>
        <div style={{ marginTop: 4 }}>
          <div style={{ ...cDisplay, fontSize: 34, color: C.ink, letterSpacing: -0.6, lineHeight: 1.1, fontWeight: 500 }}>上传</div>
        </div>
      </div>

      <div style={{ padding: '16px 20px 100px', overflow: 'auto' }}>
        {/* SECTION: 目标位置 */}
        <CSection header="目标位置">
          <CRow
            title="上传到"
            value="/ 2026春节 /"
            chevron
          />
          <CRow
            icon={Icon.folderPlus}
            iconTint={C.caramel}
            title="新建文件夹"
            dividerBelow={false}
          />
        </CSection>

        {/* SECTION: 选择 */}
        <CSection>
          <CRow
            icon={Icon.photos}
            iconTint={C.mint}
            title="从相册选择"
            dividerBelow={false}
          />
        </CSection>

        {/* SECTION: 上传进度 汇总 */}
        <CSection header="上传进度">
          <div style={{ padding: '14px 16px' }}>
            {/* progress bar */}
            <div style={{ height: 8, background: 'rgba(120,100,90,0.12)', borderRadius: 4, overflow: 'hidden' }}>
              <div style={{ width: '62%', height: '100%', background: C.caramel, borderRadius: 4 }}/>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, fontSize: 11.5, ...cMono }}>
              <span style={{ color: C.ink, fontWeight: 700 }}>2/4</span>
              <span style={{ color: C.sub }}>180 MB/284 MB</span>
              <span style={{ display: 'inline-flex', padding: '1px 6px', background: `${C.caramel}22`, color: C.caramel, borderRadius: 4, fontSize: 10, fontWeight: 600 }}>1 UPLOADING</span>
              <span style={{ flex: 1 }}/>
              <span style={{ color: C.muted }}>62%</span>
            </div>
          </div>
        </CSection>

        {/* SECTION: 进行中 */}
        <CSection header={<>进行中 <span style={{ marginLeft: 4, opacity: 0.6 }}>2</span></>}>
          {active.slice(0, 2).map((t, i, a) => (
            <UploadRow key={i} task={t} dividerBelow={i < a.length - 1}/>
          ))}
        </CSection>

        {/* SECTION: 已完成 (DisclosureGroup) */}
        <CSection>
          <div style={{ padding: '13px 16px', display: 'flex', alignItems: 'center' }}>
            <div style={{ flex: 1, fontSize: 11, color: C.muted, letterSpacing: 1.5, textTransform: 'uppercase', fontWeight: 600 }}>已完成 <span style={{ marginLeft: 4, opacity: 0.7 }}>2</span></div>
            <Icon.chevronRight width={14} height={14} color={C.muted} style={{ transform: 'rotate(90deg)' }}/>
          </div>
          {active.slice(2).map((t, i, a) => (
            <UploadRow key={i} task={t} dividerBelow={i < a.length - 1}/>
          ))}
        </CSection>
      </div>

      <CTabBar active="up" />
    </Phone>
  );
}

function UploadRow({ task, dividerBelow }) {
  const statusNode = task.status === 'done' ? (
    <div style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.mint, padding: '1px 6px', background: `${C.mint}22`, borderRadius: 4 }}>DONE</div>
  ) : task.status === 'dup' ? (
    <div style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.caramel, padding: '1px 6px', background: `${C.caramel}22`, borderRadius: 4 }}>EXIST</div>
  ) : task.status === 'wait' ? (
    <div style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.muted, padding: '1px 6px', background: 'rgba(120,100,90,0.12)', borderRadius: 4 }}>WAIT</div>
  ) : (
    <div style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.caramel, padding: '1px 6px', background: `${C.caramel}22`, borderRadius: 4 }}>{task.pct}%</div>
  );
  const rightWidget = task.status === 'done' ? (
    <Icon.check width={16} height={16} color={C.mint}/>
  ) : task.status === 'dup' ? (
    <div style={{ color: C.caramel }}>=</div>
  ) : task.status === 'wait' ? (
    <div style={{ color: C.muted }}>⋯</div>
  ) : (
    // Circular progress
    <svg width="22" height="22" viewBox="0 0 22 22" style={{ transform: 'rotate(-90deg)' }}>
      <circle cx="11" cy="11" r="9" fill="none" stroke="rgba(120,100,90,0.2)" strokeWidth="2.5"/>
      <circle cx="11" cy="11" r="9" fill="none" stroke={C.caramel} strokeWidth="2.5" strokeLinecap="round"
        strokeDasharray={`${2 * Math.PI * 9 * (task.pct / 100)} ${2 * Math.PI * 9}`}/>
    </svg>
  );

  return (
    <div style={{ padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 11, borderBottom: dividerBelow ? `0.5px solid ${C.divider}` : 'none' }}>
      <div style={{ width: 28, height: 28, display: 'flex', alignItems: 'center', justifyContent: 'center', color: task.status === 'done' ? C.mint : task.status === 'dup' ? C.caramel : C.muted }}>
        {task.isVideo ? (
          <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="6" width="15" height="12" rx="2"/><path d="M18 10l3-2v8l-3-2z"/></svg>
        ) : (
          <Icon.photos width={18} height={18}/>
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12.5, color: C.ink, ...cMono, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{task.name}</div>
        <div style={{ display: 'flex', gap: 6, marginTop: 2, alignItems: 'center' }}>
          <span style={{ fontSize: 10.5, color: C.muted, ...cMono }}>{task.size}</span>
          {statusNode}
        </div>
      </div>
      {rightWidget}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 6 · Settings
// Maps to: SettingsView.swift
// Real sections: SERVER · SYNC · STATS · 存储管理 (最近删除/磁盘信息) · ABOUT · 断开连接
// ─────────────────────────────────────────────────────────────
function CreamSettings() {
  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <div style={{ padding: '0 20px', height: 44, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ fontSize: 17, color: C.ink, fontWeight: 600 }}>设置</div>
      </div>

      <div style={{ padding: '14px 20px 120px', overflow: 'auto' }}>
        {/* Hero — 熊猫管家 */}
        <div style={{ background: `linear-gradient(160deg, ${C.peach}55, ${C.caramel}33)`, borderRadius: 20, padding: 16, display: 'flex', gap: 12, alignItems: 'center', marginBottom: 18 }}>
          <CPandaHi size={46}/>
          <div>
            <div style={{ ...cDisplay, fontSize: 17, color: C.ink, letterSpacing: -0.2, fontWeight: 500 }}>你的小熊猫管家</div>
            <div style={{ fontSize: 11.5, color: C.sub, marginTop: 2 }}>今天帮你看着 1,355 件素材</div>
          </div>
        </div>

        {/* SERVER */}
        <CSection header="Server">
          <div style={{ padding: '13px 16px', display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{ flex: 1, fontSize: 13, color: C.ink, ...cMono }}>http://192.168.1.12:8080</div>
            <div style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.mint, padding: '2px 7px', background: `${C.mint}22`, borderRadius: 4, letterSpacing: 0.5 }}>CONNECTED</div>
          </div>
          <div style={{ padding: '12px 16px', textAlign: 'center', borderTop: `0.5px solid ${C.divider}`, fontSize: 13, color: C.caramel, fontWeight: 600, ...cMono, letterSpacing: 2 }}>TEST</div>
        </CSection>

        {/* SYNC */}
        <CSection header="Sync">
          <div style={{ padding: '13px 16px', display: 'flex', alignItems: 'center' }}>
            <div style={{ flex: 1, fontSize: 14, color: C.ink }}>自动备份</div>
            <Toggle on tint={C.caramel}/>
          </div>
          <div style={{ padding: '13px 16px', borderTop: `0.5px solid ${C.divider}`, display: 'flex', alignItems: 'center' }}>
            <div style={{ flex: 1, fontSize: 14, color: C.ink }}>同步文件夹</div>
            <div style={{ fontSize: 13, color: C.sub }}>默认</div>
            <Icon.chevronRight width={14} height={14} color={C.muted} style={{ marginLeft: 6 }}/>
          </div>
          {/* 同步进度中 */}
          <div style={{ padding: '12px 16px', borderTop: `0.5px solid ${C.divider}` }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, ...cMono }}>
              <span style={{ color: C.caramel, fontWeight: 700 }}>1,346/1,355</span>
              <span style={{ flex: 1 }}/>
              <span style={{ color: C.caramel }}>9 失败</span>
            </div>
            <div style={{ marginTop: 6, fontSize: 11, color: C.sub, ...cMono, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>IMG_6620.HEIC</div>
            <div style={{ height: 4, background: 'rgba(120,100,90,0.12)', borderRadius: 2, marginTop: 6, overflow: 'hidden' }}>
              <div style={{ width: '72%', height: '100%', background: C.caramel }}/>
            </div>
          </div>
          <div style={{ padding: '12px 16px', textAlign: 'center', borderTop: `0.5px solid ${C.divider}`, fontSize: 13, color: C.caramel, fontWeight: 600, ...cMono, letterSpacing: 1 }}>立即同步</div>
        </CSection>

        {/* STATS — 4 rows with PixelTag */}
        <CSection>
          {[
            { l: '相册总数', v: '1,364',      tone: C.caramel },
            { l: '已同步',   v: '1,346',     tone: C.mint },
            { l: '待同步',   v: '18',         tone: C.peach },
            { l: '上次同步', v: '04-21 11:56', tone: C.berry },
          ].map((r, i, a) => (
            <div key={r.l} style={{ padding: '12px 16px', display: 'flex', alignItems: 'center', borderBottom: i < a.length - 1 ? `0.5px solid ${C.divider}` : 'none' }}>
              <div style={{ flex: 1, fontSize: 13, color: C.sub, ...cMono }}>{r.l}</div>
              <div style={{ ...cMono, fontSize: 11, fontWeight: 700, color: r.tone, padding: '2px 7px', background: `${r.tone}22`, borderRadius: 4 }}>{r.v}</div>
            </div>
          ))}
        </CSection>

        {/* 存储管理 */}
        <CSection header="存储管理">
          <CRow icon={Icon.trash} iconTint={C.berry} title="最近删除" value="6" chevron/>
          <CRow icon={Icon.disk}  iconTint={C.caramel} title="磁盘信息" chevron dividerBelow={false}/>
        </CSection>

        {/* About */}
        <CSection header="About">
          <div style={{ padding: '13px 16px', display: 'flex', alignItems: 'center' }}>
            <div style={{ flex: 1, fontSize: 13, color: C.sub, ...cMono, letterSpacing: 1 }}>VERSION</div>
            <div style={{ ...cMono, fontSize: 11, fontWeight: 700, color: C.caramel, padding: '2px 7px', background: `${C.caramel}22`, borderRadius: 4 }}>1.0.0</div>
          </div>
        </CSection>

        {/* 断开 */}
        <CSection>
          <div style={{ padding: '13px 16px', textAlign: 'center', fontSize: 14, color: C.berry, fontWeight: 600 }}>断开连接</div>
        </CSection>
      </div>

      <CTabBar active="set" />
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 7 · Trash (最近删除)
// Maps to: TrashView.swift
// Real features: 7 天倒计时 overlay, 选择/全选, 恢复/永久删除/清空
// ─────────────────────────────────────────────────────────────
function CreamTrash() {
  // ★ UX: 按删除时间分组（今天 / 昨天 / 更早），每组可一键全选恢复
  const groups = [
    { label: '今天删除', subtitle: '剩 7 天', assets: [
      { m: MEDIA[2] }, { m: MEDIA[3] },
    ]},
    { label: '昨天删除', subtitle: '剩 6 天', assets: [
      { m: MEDIA[1] }, { m: MEDIA[11] },
    ]},
    { label: '3 天前', subtitle: '剩 4 天', assets: [
      { m: MEDIA[5], sel: true }, { m: MEDIA[7], sel: true }, { m: MEDIA[8] },
    ]},
    { label: '即将清理', subtitle: '今天结束', danger: true, assets: [
      { m: MEDIA[0] }, { m: MEDIA[6] },
    ]},
  ];

  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <CNavBar
        title="最近删除"
        left={<><Icon.chevronRight width={18} height={18} style={{ transform: 'rotate(180deg)' }}/><span style={{ fontSize: 16 }}>设置</span></>}
        right={<><span style={{ fontSize: 15 }}>全选</span><span style={{ fontSize: 15 }}>完成</span></>}
      />

      <div style={{ padding: '0 0 180px' }}>
        {groups.map((g, gi) => (
          <div key={gi}>
            <div style={{ padding: '14px 20px 6px', display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', background: C.bg }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                <div style={{ fontSize: 13, color: g.danger ? C.berry : C.ink, fontWeight: 600 }}>{g.label}</div>
                <div style={{ fontSize: 10.5, color: g.danger ? C.berry : C.muted, ...cMono }}>{g.subtitle} · {g.assets.length}</div>
              </div>
              <div style={{ fontSize: 12, color: C.caramel, fontWeight: 500 }}>全选恢复</div>
            </div>
            <div style={{ padding: '0 2px', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 2 }}>
              {g.assets.map((a, i) => (
                <div key={i} style={{ aspectRatio: '1/1', backgroundImage: `url("${placeholderSvg(a.m)}")`, backgroundSize: 'cover', backgroundPosition: 'center', position: 'relative', opacity: a.sel ? 0.7 : 1 }}>
                  {a.sel && <div style={{ position: 'absolute', inset: 0, border: `2px solid ${C.caramel}` }}/>}
                  <div style={{ position: 'absolute', top: 5, right: 5 }}>
                    {a.sel ? (
                      <div style={{ width: 20, height: 20, borderRadius: 10, background: C.caramel, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.3)' }}>
                        <Icon.check width={11} height={11}/>
                      </div>
                    ) : (
                      <div style={{ width: 20, height: 20, borderRadius: 10, border: '1.5px solid #fff', background: 'rgba(0,0,0,0.25)' }}/>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      {/* bottom bar — 3 按钮 */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, background: 'rgba(255,249,238,0.95)', backdropFilter: 'blur(20px)', borderTop: `0.5px solid ${C.divider}`, padding: '8px 0 26px' }}>
        <div style={{ textAlign: 'center', fontSize: 11.5, color: C.sub, fontWeight: 600, padding: '4px 0' }}>已选 2 项</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', padding: '4px 0' }}>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, color: C.caramel }}>
            <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/></svg>
            <div style={{ fontSize: 11, ...cMono }}>恢复</div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, color: C.berry }}>
            <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 7h16"/><path d="M6 7l1 13a2 2 0 002 2h6a2 2 0 002-2l1-13"/><path d="M3 3l18 18"/></svg>
            <div style={{ fontSize: 11, ...cMono }}>永久删除</div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, color: C.peach }}>
            <Icon.trash width={22} height={22}/>
            <div style={{ fontSize: 11, ...cMono }}>清空</div>
          </div>
        </div>
      </div>
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 8 · DiskInfo (磁盘信息)
// Maps to: DiskInfoView.swift
// Real: VolumeInfo per volume with basePath, usedByAssets, assetCount,
//       totalBytes, diskUsedBytes, freeBytes, diskUsagePercent, isDefault
// ─────────────────────────────────────────────────────────────
function CreamDiskInfo() {
  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <CNavBar
        title="磁盘信息"
        left={<><Icon.chevronRight width={18} height={18} style={{ transform: 'rotate(180deg)' }}/><span style={{ fontSize: 16 }}>设置</span></>}
        right={<Icon.sync width={18} height={18} color={C.caramel}/>}
      />

      <div style={{ padding: '12px 20px 40px', overflow: 'auto' }}>
        {/* ★ NEW · 人味汇总 */}
        <div style={{ background: `linear-gradient(160deg, ${C.peach}44, ${C.caramel}22)`, borderRadius: 16, padding: 14, marginBottom: 16 }}>
          <div style={{ fontSize: 11, color: C.sub, letterSpacing: 1.2, fontWeight: 600, textTransform: 'uppercase' }}>还能装</div>
          <div style={{ ...cDisplay, fontSize: 28, color: C.ink, fontWeight: 500, letterSpacing: -0.4, marginTop: 2 }}>
            约 <span style={{ color: C.caramel }}>234,500</span> 张照片
          </div>
          <div style={{ fontSize: 11.5, color: C.sub, marginTop: 3 }}>按平均 4 MB/张估算 · 938 GB 剩余</div>
        </div>

        {/* 汇总 */}
        <CSection header="汇总">
          <div style={{ padding: '12px 16px', display: 'flex', alignItems: 'center' }}>
            {[
              { l: '卷数',       v: '2',        tone: C.caramel },
              { l: '媒体库占用', v: '14.4 GB',  tone: C.berry },
              { l: '资产数',     v: '1,355',    tone: C.mint },
            ].map((s, i, arr) => (
              <React.Fragment key={s.l}>
                <div style={{ flex: 1, textAlign: 'center' }}>
                  <div style={{ fontSize: 15, color: s.tone, ...cMono, fontWeight: 700 }}>{s.v}</div>
                  <div style={{ fontSize: 10, color: C.sub, ...cMono, marginTop: 3, letterSpacing: 0.5 }}>{s.l}</div>
                </div>
                {i < arr.length - 1 && <div style={{ width: 1, height: 36, background: C.divider }}/>}
              </React.Fragment>
            ))}
          </div>
        </CSection>

        {/* Volume 1 — Default */}
        <CSection
          header={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span>主卷</span>
            <span style={{ ...cMono, fontSize: 10, fontWeight: 700, color: C.caramel, padding: '2px 6px', background: `${C.caramel}22`, borderRadius: 4, textTransform: 'none', letterSpacing: 0 }}>默认</span>
          </div>}
          footer="「整盘已用」包含 macOS 系统、其他应用占用；「媒体库占用」只统计本应用导入的资产。剩余 ≤ 10 GB 时停止写入这块卷。"
        >
          <div style={{ padding: '10px 16px', display: 'flex', alignItems: 'flex-start', gap: 8, borderBottom: `0.5px solid ${C.divider}` }}>
            <Icon.folder width={14} height={14} color={C.sub} style={{ marginTop: 2 }}/>
            <div style={{ fontSize: 11, color: C.sub, ...cMono, wordBreak: 'break-all' }}>/Users/chejinxuande/PandaVault/media</div>
          </div>
          {[
            { l: '媒体库占用', v: '12.4 GB', tone: C.berry },
            { l: '资产数',     v: '1,289',   tone: C.caramel },
            { l: '整盘容量',   v: '500 GB',  tone: C.mint },
            { l: '整盘已用',   v: '342 GB',  tone: C.peach },
            { l: '整盘剩余',   v: '158 GB',  tone: C.caramel },
          ].map((r, i, arr) => (
            <div key={r.l} style={{ padding: '11px 16px', display: 'flex', alignItems: 'center', borderBottom: `0.5px solid ${C.divider}` }}>
              <div style={{ flex: 1, fontSize: 13, color: C.sub, ...cMono }}>{r.l}</div>
              <div style={{ ...cMono, fontSize: 11, fontWeight: 700, color: r.tone, padding: '2px 7px', background: `${r.tone}22`, borderRadius: 4 }}>{r.v}</div>
            </div>
          ))}
          {/* 整盘 progress */}
          <div style={{ padding: '12px 16px' }}>
            <div style={{ height: 8, background: 'rgba(120,100,90,0.12)', borderRadius: 4, overflow: 'hidden' }}>
              <div style={{ width: '68%', height: '100%', background: C.peach }}/>
            </div>
            <div style={{ marginTop: 6, fontSize: 10.5, color: C.sub, ...cMono }}>整盘 68% 已使用</div>
          </div>
        </CSection>

        {/* Volume 2 */}
        <CSection
          header={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span>外接硬盘</span>
          </div>}
        >
          <div style={{ padding: '10px 16px', display: 'flex', alignItems: 'flex-start', gap: 8, borderBottom: `0.5px solid ${C.divider}` }}>
            <Icon.folder width={14} height={14} color={C.sub} style={{ marginTop: 2 }}/>
            <div style={{ fontSize: 11, color: C.sub, ...cMono, wordBreak: 'break-all' }}>/Volumes/SSD-T7/PandaVault</div>
          </div>
          {[
            { l: '媒体库占用', v: '2.0 GB', tone: C.berry },
            { l: '资产数',     v: '66',      tone: C.caramel },
            { l: '整盘容量',   v: '1 TB',   tone: C.mint },
            { l: '整盘剩余',   v: '780 GB', tone: C.caramel },
          ].map((r, i) => (
            <div key={r.l} style={{ padding: '11px 16px', display: 'flex', alignItems: 'center', borderBottom: `0.5px solid ${C.divider}` }}>
              <div style={{ flex: 1, fontSize: 13, color: C.sub, ...cMono }}>{r.l}</div>
              <div style={{ ...cMono, fontSize: 11, fontWeight: 700, color: r.tone, padding: '2px 7px', background: `${r.tone}22`, borderRadius: 4 }}>{r.v}</div>
            </div>
          ))}
          <div style={{ padding: '12px 16px' }}>
            <div style={{ height: 8, background: 'rgba(120,100,90,0.12)', borderRadius: 4, overflow: 'hidden' }}>
              <div style={{ width: '22%', height: '100%', background: C.caramel }}/>
            </div>
            <div style={{ marginTop: 6, fontSize: 10.5, color: C.sub, ...cMono }}>整盘 22% 已使用</div>
          </div>
        </CSection>
      </div>
    </Phone>
  );
}

// ─────────────────────────────────────────────────────────────
// SCREEN 9 · FolderPicker (上传目标文件夹选择器)
// Maps to: UploadView.swift · FolderPickerView
// Real features: 面包屑 + "选择此文件夹" + 子文件夹列表 + 点击下钻
// ─────────────────────────────────────────────────────────────
function CreamFolderPicker() {
  return (
    <Phone bg={C.bg}>
      <StatusBar />
      <CNavBar
        title="选择文件夹"
        left={<span style={{ fontSize: 15 }}>取消</span>}
      />

      {/* 面包屑 */}
      <div style={{ padding: '10px 20px', background: 'rgba(255,255,255,0.5)', display: 'flex', gap: 6, alignItems: 'center', ...cMono, fontSize: 12 }}>
        <span style={{ color: C.sub }}>根目录</span>
        <span style={{ color: C.muted }}>/</span>
        <span style={{ color: C.caramel, fontWeight: 600 }}>2026春节</span>
      </div>

      {/* 选择当前层 */}
      <CSection>
        <div style={{ padding: '14px 16px', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 26, height: 26, borderRadius: 13, background: C.caramel, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon.check width={14} height={14}/>
          </div>
          <div style={{ fontSize: 14, color: C.caramel, fontWeight: 600 }}>选择此文件夹</div>
        </div>
      </CSection>

      {/* 子文件夹列表 */}
      <div style={{ padding: '0 20px' }}>
        <CSection>
          {[
            { name: '精修图', count: 28 },
            { name: '原图',   count: 156 },
            { name: '花絮',   count: 42 },
          ].map((f, i, a) => (
            <div key={f.name} style={{ padding: '13px 16px', display: 'flex', alignItems: 'center', gap: 11, borderBottom: i < a.length - 1 ? `0.5px solid ${C.divider}` : 'none' }}>
              <Icon.folder width={19} height={19} color={C.caramel}/>
              <div style={{ flex: 1, fontSize: 14, color: C.ink }}>{f.name}</div>
              <Icon.chevronRight width={13} height={13} color={C.muted}/>
            </div>
          ))}
        </CSection>
      </div>
    </Phone>
  );
}

function Toggle({ on = false, tint = '#000' }) {
  return (
    <div style={{ width: 44, height: 26, borderRadius: 14, background: on ? tint : '#E5DFD4', position: 'relative', transition: 'background .2s' }}>
      <div style={{ position: 'absolute', top: 2, left: on ? 20 : 2, width: 22, height: 22, borderRadius: 11, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.15)', transition: 'left .2s' }}/>
    </div>
  );
}

Object.assign(window, {
  CreamTimeline, CreamFolders, CreamFolderDetail, CreamDetail,
  CreamUpload, CreamSettings, CreamTrash, CreamDiskInfo, CreamFolderPicker,
});
