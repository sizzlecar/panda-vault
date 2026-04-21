// Shared: Phone shell, status bar, tab bar primitives, and placeholder
// image generator. All three directions use the same phone hardware —
// only the interior differs.

// Abstract placeholder image generator — varied colored rectangles,
// NOT photoreal, clearly communicates "media placeholder". We use SVG
// data URIs so there are zero external assets.
function placeholderSvg({ hue = 180, sat = 40, light = 70, label = '', kind = 'photo', accent = null }) {
  // kind: photo | video | doc | chat | poster
  const bg1 = `hsl(${hue}, ${sat}%, ${light}%)`;
  const bg2 = `hsl(${(hue + 20) % 360}, ${sat - 5}%, ${Math.max(light - 10, 40)}%)`;
  const stripe = `hsl(${hue}, ${sat - 10}%, ${Math.max(light - 18, 30)}%)`;
  let inner = '';
  if (kind === 'video') {
    inner = `<circle cx='50%' cy='50%' r='28' fill='rgba(0,0,0,0.35)'/><polygon points='46,40 46,60 64,50' fill='white'/>`;
  } else if (kind === 'doc') {
    inner = Array.from({length:5}).map((_,i)=>`<rect x='18' y='${24+i*14}' width='${90-i*10}' height='6' rx='2' fill='rgba(255,255,255,0.7)'/>`).join('');
  } else if (kind === 'chat') {
    inner = `<rect x='14' y='22' width='80' height='18' rx='9' fill='rgba(255,255,255,0.85)'/><rect x='30' y='46' width='70' height='18' rx='9' fill='rgba(255,255,255,0.6)'/><rect x='14' y='70' width='60' height='18' rx='9' fill='rgba(255,255,255,0.85)'/>`;
  } else if (kind === 'poster') {
    inner = `<text x='50%' y='44%' font-family='serif' font-size='22' font-weight='700' fill='${accent||'#fff'}' text-anchor='middle'>${label||'海报'}</text><rect x='30%' y='58%' width='40%' height='2' fill='${accent||'#fff'}'/>`;
  } else {
    // photo: two softly overlapping rounded rects → abstract scene
    inner = `<rect x='-10' y='60%' width='70%' height='60%' fill='${stripe}' opacity='0.65'/><circle cx='78%' cy='32%' r='18' fill='rgba(255,255,255,0.7)'/>`;
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" preserveAspectRatio="xMidYMid slice">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${bg1}"/><stop offset="1" stop-color="${bg2}"/>
    </linearGradient></defs>
    <rect width="120" height="120" fill="url(%23g)"/>
    ${inner.replace(/'/g, '"')}
  </svg>`;
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg).replace(/'/g, '%27')}`;
}

// A curated set of placeholder "memories" — same data drives every
// direction so the visual comparison is apples-to-apples.
const MEDIA = [
  { id:'m1',  kind:'doc',    hue:40,  sat:22, light:92, ratio:1,    label:'清单' },
  { id:'m2',  kind:'chat',   hue:210, sat:30, light:88, ratio:1,    label:'聊天' },
  { id:'m3',  kind:'photo',  hue:150, sat:28, light:58, ratio:1,    label:'瀑布' },
  { id:'m4',  kind:'photo',  hue:350, sat:30, light:45, ratio:1,    label:'肖像' },
  { id:'m5',  kind:'doc',    hue:30,  sat:18, light:94, ratio:1,    label:'笔记' },
  { id:'m6',  kind:'photo',  hue:90,  sat:35, light:72, ratio:1,    label:'花' },
  { id:'m7',  kind:'poster', hue:210, sat:60, light:40, ratio:1,    label:'人民论坛' },
  { id:'m8',  kind:'photo',  hue:30,  sat:20, light:30, ratio:1,    label:'室内' },
  { id:'m9',  kind:'doc',    hue:220, sat:10, light:22, ratio:1,    label:'代码' },
  { id:'m10', kind:'video',  hue:0,   sat:0,  light:12, ratio:1,    label:'4370.mov' },
  { id:'m11', kind:'doc',    hue:0,   sat:0,  light:18, ratio:1,    label:'文件夹' },
  { id:'m12', kind:'photo',  hue:200, sat:12, light:60, ratio:1,    label:'衣物' },
];

// Minimal status bar (light or dark glyphs). We don't need full iOS 26;
// just a clean topbar.
function StatusBar({ dark = false, time = '11:56', tint }) {
  const c = tint || (dark ? '#fff' : '#141414');
  return (
    <div style={{ height: 54, padding: '18px 28px 0', display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontFamily: '-apple-system, "SF Pro", system-ui', fontWeight: 600, fontSize: 16, color: c, position: 'relative', zIndex: 30 }}>
      <span>{time}</span>
      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
        <svg width="18" height="11" viewBox="0 0 18 11"><rect x="0" y="7" width="3" height="4" rx="0.6" fill={c}/><rect x="5" y="5" width="3" height="6" rx="0.6" fill={c}/><rect x="10" y="3" width="3" height="8" rx="0.6" fill={c}/><rect x="15" y="0" width="3" height="11" rx="0.6" fill={c}/></svg>
        <svg width="16" height="11" viewBox="0 0 16 11"><path d="M8 3C10.2 3 12.2 3.8 13.7 5.2L14.7 4.2C13 2.5 10.6 1.4 8 1.4C5.4 1.4 3 2.5 1.3 4.2L2.3 5.2C3.8 3.8 5.8 3 8 3Z" fill={c}/><path d="M8 6.3C9.3 6.3 10.4 6.8 11.3 7.6L12.3 6.6C11 5.5 9.6 4.8 8 4.8C6.4 4.8 5 5.5 3.7 6.6L4.7 7.6C5.6 6.8 6.7 6.3 8 6.3Z" fill={c}/><circle cx="8" cy="9.5" r="1.4" fill={c}/></svg>
        <div style={{ width: 26, height: 12, border: `1.2px solid ${c}`, borderRadius: 3.5, position: 'relative', opacity: 0.95 }}>
          <div style={{ position: 'absolute', top: 1.5, left: 1.5, bottom: 1.5, width: 18, background: '#30d158', borderRadius: 1.5 }} />
          <svg style={{ position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%,-50%)' }} width="8" height="8" viewBox="0 0 8 8"><path d="M4 1v3H2l2 3V4h2L4 1z" fill="#fff"/></svg>
          <div style={{ position: 'absolute', right: -3, top: 3.5, bottom: 3.5, width: 1.5, background: c, borderRadius: 1 }} />
        </div>
      </div>
    </div>
  );
}

// Phone frame — rounded bezel, body is your slot
function Phone({ children, bg = '#fff', bezel = '#1a1a1a', width = 390, height = 844 }) {
  return (
    <div style={{
      width, height, borderRadius: 48, background: bg,
      position: 'relative', overflow: 'hidden',
      boxShadow: `0 0 0 6px ${bezel}, 0 0 0 8px rgba(0,0,0,0.5), 0 40px 80px rgba(0,0,0,0.18)`,
      border: `0.5px solid rgba(0,0,0,0.1)`,
      boxSizing: 'border-box',
      fontFamily: '"HarmonyOS Sans SC", "PingFang SC", -apple-system, "Noto Sans SC", system-ui, sans-serif',
      WebkitFontSmoothing: 'antialiased',
    }}>
      {/* dynamic island */}
      <div style={{ position: 'absolute', top: 9, left: '50%', transform: 'translateX(-50%)', width: 118, height: 34, borderRadius: 20, background: '#000', zIndex: 60 }} />
      <div style={{ position: 'relative', width: '100%', height: '100%', display: 'flex', flexDirection: 'column' }}>
        {children}
      </div>
      {/* home indicator */}
      <div style={{ position: 'absolute', bottom: 8, left: '50%', transform: 'translateX(-50%)', width: 130, height: 5, borderRadius: 3, background: 'rgba(0,0,0,0.25)', zIndex: 70 }} />
    </div>
  );
}

// Tiny icon primitives used across directions (stroke-based so they
// inherit currentColor)
const Icon = {
  grid:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><rect x="3" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.5"/></svg>,
  upload: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M12 18V5"/><path d="M6 11l6-6 6 6"/><path d="M4 21h16"/></svg>,
  gear:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" {...p}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 01-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 010-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3h0a1.7 1.7 0 001-1.5V3a2 2 0 014 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8v0a1.7 1.7 0 001.5 1H21a2 2 0 010 4h-.1a1.7 1.7 0 00-1.5 1z"/></svg>,
  search: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" {...p}><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>,
  scan:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 7V5a2 2 0 012-2h2M21 7V5a2 2 0 00-2-2h-2M3 17v2a2 2 0 002 2h2M21 17v2a2 2 0 01-2 2h-2"/><circle cx="12" cy="12" r="4"/></svg>,
  plus:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" {...p}><path d="M12 5v14M5 12h14"/></svg>,
  folder: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/></svg>,
  folderPlus: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/><path d="M12 11v6M9 14h6"/></svg>,
  photos: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="11" r="1.6"/><path d="M3 17l5-4 4 3 3-2 6 5"/></svg>,
  share:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M12 3v13M7 8l5-5 5 5"/><path d="M5 14v5a2 2 0 002 2h10a2 2 0 002-2v-5"/></svg>,
  trash:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M4 7h16"/><path d="M6 7l1 13a2 2 0 002 2h6a2 2 0 002-2l1-13"/><path d="M9 7V5a2 2 0 012-2h2a2 2 0 012 2v2"/></svg>,
  download:(p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M12 4v12"/><path d="M6 10l6 6 6-6"/><path d="M4 20h16"/></svg>,
  move:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><path d="M9 13h8M14 10l3 3-3 3"/></svg>,
  sort:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M7 5v14M3 15l4 4 4-4"/><path d="M17 19V5M13 9l4-4 4 4"/></svg>,
  close:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" {...p}><path d="M6 6l12 12M18 6L6 18"/></svg>,
  chevronRight: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M9 6l6 6-6 6"/></svg>,
  calendar: (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>,
  clock:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>,
  cloud:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M7 17a5 5 0 110-10 6 6 0 0111.5 2A4 4 0 0117 17H7z"/></svg>,
  check:  (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M4 12l6 6L20 6"/></svg>,
  sync:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><path d="M4 12a8 8 0 0114-5.3L20 8"/><path d="M20 4v4h-4"/><path d="M20 12a8 8 0 01-14 5.3L4 16"/><path d="M4 20v-4h4"/></svg>,
  disk:   (p={}) => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" {...p}><ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12a8 3 0 0016 0V6"/><path d="M4 12a8 3 0 0016 0"/></svg>,
  play:   (p={}) => <svg viewBox="0 0 24 24" fill="currentColor" {...p}><path d="M8 5v14l11-7z"/></svg>,
};

// Panda glyph — used in tab-bar brand / empty states. Keeping it simple
// and geometric, NOT a cute illustration SVG.
function PandaGlyph({ size = 28, stroke = '#1b1b1b', fill = '#fff' }) {
  // Rounded-square head with two ears and a face.
  return (
    <svg width={size} height={size} viewBox="0 0 40 40">
      {/* ears */}
      <circle cx="9" cy="10" r="5" fill={stroke}/>
      <circle cx="31" cy="10" r="5" fill={stroke}/>
      {/* head */}
      <rect x="5" y="8" width="30" height="26" rx="13" fill={fill} stroke={stroke} strokeWidth="1.6"/>
      {/* eye patches */}
      <ellipse cx="14" cy="20" rx="3.2" ry="4" fill={stroke} transform="rotate(-12 14 20)"/>
      <ellipse cx="26" cy="20" rx="3.2" ry="4" fill={stroke} transform="rotate(12 26 20)"/>
      {/* eyes */}
      <circle cx="14" cy="21" r="1" fill={fill}/>
      <circle cx="26" cy="21" r="1" fill={fill}/>
      {/* nose */}
      <ellipse cx="20" cy="26" rx="1.4" ry="1" fill={stroke}/>
    </svg>
  );
}

// Expose
Object.assign(window, {
  placeholderSvg, MEDIA, StatusBar, Phone, Icon, PandaGlyph,
});
