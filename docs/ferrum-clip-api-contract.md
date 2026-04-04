# Ferrum Embedding API 接口协议

panda-vault 后端 ↔ ferrum 推理服务之间的接口约定。

## 基本信息

- **传输协议**: HTTP
- **默认端口**: 8000
- **API 格式**: OpenAI `/v1/embeddings` 标准，扩展支持图片输入
- **向量维度**: 512 (base 模型) 或 768 (large 模型)
- **模型**: Chinese-CLIP (OFA-Sys/chinese-clip-vit-base-patch16 或同等)

---

## 接口定义

### 1. 文本 → 向量

OpenAI 标准格式，所有 OpenAI SDK 直接兼容。

```
POST /v1/embeddings
Content-Type: application/json
```

**Request:**
```json
{
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "input": "海边日落"
}
```

**批量:**
```json
{
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "input": ["海边日落", "城市夜景", "雪山"]
}
```

**Response 200:**
```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "embedding": [0.046, 0.020, -0.008, ...],
      "index": 0
    }
  ],
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "usage": {
    "prompt_tokens": 4,
    "total_tokens": 4
  }
}
```

---

### 2. 图片 → 向量

同一 endpoint，使用对象格式传入图片路径（Jina 扩展格式）。

```
POST /v1/embeddings
Content-Type: application/json
```

**文件路径（共享存储卷）:**
```json
{
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "input": { "image": "/data/raw/2025/01/photo.jpg" }
}
```

**Base64:**
```json
{
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "input": { "image": "data:image/jpeg;base64,/9j/4AAQ..." }
}
```

**Response 200:** 同上格式。

---

### 3. 混合批量

单次请求同时处理文本和图片：

```json
{
  "model": "OFA-Sys/chinese-clip-vit-base-patch16",
  "input": [
    { "text": "海边日落" },
    { "image": "/data/raw/2025/01/sunset.jpg" },
    { "text": "城市夜景" }
  ]
}
```

每个 item 返回对应 index 的 embedding。

---

### 4. 已有通用接口

| 接口 | 说明 |
|------|------|
| `GET /v1/models` | 返回已加载模型信息 |
| `GET /health` | 健康检查 |

---

## 约束

1. **embedding 已 L2 归一化** — 后端可直接用余弦相似度（pgvector `<=>` 运算符）
2. **图片和文本的向量在同一空间** — CLIP 核心特性，跨模态检索可行
3. **路径安全** — ferrum 应校验 path 在允许的目录范围内（如 `/data` 前缀），拒绝路径穿越
4. **超时** — 后端调用超时设为 120 秒
5. **并发** — ferrum 能处理少量并发（2-3 个）

## Docker Compose 集成

```yaml
services:
  ferrum:
    image: ferrum-clip:latest
    container_name: media_server_ferrum
    restart: unless-stopped
    ports:
      - "8000:8000"
    volumes:
      - /mnt/media_storage:/data:ro
    command: ["ferrum", "serve", "--model", "OFA-Sys/chinese-clip-vit-base-patch16", "--port", "8000"]
```

后端通过环境变量 `AI_SERVICE_URL=http://ferrum:8000` 连接。

## 与旧接口的变更

| 旧接口 | 新接口 | 说明 |
|--------|--------|------|
| `GET /v1/clip/health` | `GET /health` + `GET /v1/models` | 通用接口，不再 CLIP 专属 |
| `POST /v1/clip/embed/image` | `POST /v1/embeddings` + `{"input":{"image":"..."}}` | 统一 endpoint |
| `POST /v1/clip/embed/text` | `POST /v1/embeddings` + `{"input":"..."}` | OpenAI 标准格式 |
