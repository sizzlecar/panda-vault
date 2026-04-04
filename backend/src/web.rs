use axum::response::{Html, IntoResponse};

pub async fn index() -> impl IntoResponse {
    // 一期最小可用：移动端多文件上传 + 简单进度
    Html(
        r#"<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>HomeMediaCloud 上传</title>
  <style>
    body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial;max-width:720px;margin:24px auto;padding:0 16px;line-height:1.5}
    .card{border:1px solid #e5e7eb;border-radius:12px;padding:16px}
    .row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}
    button{background:#111827;color:#fff;border:0;border-radius:10px;padding:10px 14px;font-weight:600}
    input[type=file]{width:100%}
    .muted{color:#6b7280;font-size:13px}
    .log{white-space:pre-wrap;background:#0b1020;color:#e5e7eb;border-radius:12px;padding:12px;min-height:120px}
    progress{width:100%}
  </style>
</head>
<body>
  <h2>上传素材</h2>
  <div class="card">
    <div class="row">
      <input id="files" type="file" multiple />
      <button id="btn">开始上传</button>
    </div>
    <p class="muted">建议保持屏幕常亮；二期可接入 Wake Lock。</p>
    <progress id="pg" value="0" max="100"></progress>
    <div class="log" id="log"></div>
  </div>

  <script>
    const logEl = document.getElementById('log');
    const pg = document.getElementById('pg');
    function log(s){ logEl.textContent += s + "\\n"; }

    async function uploadOne(file) {
      const fd = new FormData();
      fd.append('file', file, file.name);
      const resp = await fetch('/api/upload', { method:'POST', body: fd });
      const j = await resp.json();
      if(!resp.ok) throw new Error(j.error || resp.statusText);
      return j;
    }

    document.getElementById('btn').onclick = async () => {
      const files = Array.from(document.getElementById('files').files || []);
      if(files.length === 0) return log('请选择文件');
      pg.value = 0;
      logEl.textContent = '';
      let done = 0;
      for(const f of files){
        log('上传: ' + f.name + ' (' + Math.round(f.size/1024/1024) + 'MB)');
        const res = await uploadOne(f);
        log('完成: asset_id=' + res.asset.id + (res.deduped ? ' (去重命中)' : ''));
        done++;
        pg.value = Math.round(done * 100 / files.length);
      }
      log('全部完成');
    };
  </script>
</body>
</html>"#,
    )
}


