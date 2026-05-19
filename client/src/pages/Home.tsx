import { useState, useEffect, useRef, useCallback } from "react";
import "../hermespet.css";

const ICON_URL = "/manus-storage/AppIcon-new-1024_d481cfb2.png";
const BANNER_URL = "/manus-storage/banner_bff01e21.png";

interface EngineData {
  kicker: string;
  title: string;
  copy: string;
  points: string[];
  href: string;
  linkLabel: string;
}

const engines: Record<string, EngineData> = {
  direct: {
    kicker: "零依赖",
    title: "在线 AI",
    copy: "选择 DeepSeek、智谱、Kimi 或 OpenAI，填入 API Key 就能开始聊天、翻译、写作和看图。",
    points: [
      "适合分发给没有 CLI 环境的用户",
      "配置与 Hermes Gateway 完全独立保存",
      "默认新用户进入这一档，降低上手门槛",
    ],
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/APIClient.swift",
    linkLabel: "查看 APIClient.swift →",
  },
  hermes: {
    kicker: "自托管",
    title: "Hermes Gateway",
    copy: "连接本地或自部署的 OpenAI 兼容 Gateway，把常规对话任务留在用户掌控的后端里。",
    points: [
      "默认地址 http://localhost:8642/v1",
      "健康检查走 /health",
      "适合隐私优先或已有自托管服务的用户",
    ],
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/ProviderPreset.swift",
    linkLabel: "查看 ProviderPreset.swift →",
  },
  claude: {
    kicker: "本地 Agent",
    title: "Claude Code",
    copy: "通过 claude CLI 执行深度编程任务，支持 Read、Edit、Bash 等工具调用，并把进度同步到灵动岛。",
    points: [
      "启动时自动检测真实 PATH",
      "文档附件以绝对路径交给 Claude 自己读",
      "Clawd 桌面陪伴只在这一模式下出现",
    ],
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/ClaudeCodeClient.swift",
    linkLabel: "查看 ClaudeCodeClient.swift →",
  },
  codex: {
    kicker: "代码 + 生图",
    title: "Codex",
    copy: "通过 codex exec 接入 OpenAI Codex，适合代码任务、图片理解和生成图像。",
    points: [
      "每个对话绑定独立 Codex thread",
      "输入图片用 -i 参数传入",
      "生成图片会自动捕获并持久化到消息里",
    ],
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/CodexClient.swift",
    linkLabel: "查看 CodexClient.swift →",
  },
};

const islandStates: [string, string][] = [
  ["HermesPet", "就绪"],
  ["Claude Code", "工具调用中..."],
  ["Codex", "生成图片中..."],
  ["在线 AI", "思考中..."],
];

const engineKeys = ["direct", "hermes", "claude", "codex"] as const;

const timelineEvents = [
  { date: "2026.01", title: "项目构思", desc: "开始构思 macOS 原生 AI 桌面伴侣的概念" },
  { date: "2026.02", title: "v1.0 发布", desc: "首个可用版本，支持 Claude Code 集成和灵动岛" },
  { date: "2026.03", title: "v1.1 多引擎", desc: "加入 Hermes Gateway 和在线 AI 模式" },
  { date: "2026.03", title: "v1.2 桌宠系统", desc: "5 只像素桌宠上线，每个 mode 专属伴侣" },
  { date: "2026.04", title: "v1.2.4 权限 UI", desc: "工具权限确认系统，AI 不替你做主" },
  { date: "2026.05", title: "v1.2.7 传送门", desc: "桌宠跨灵动岛传送门动画，4 只迷你精灵" },
  { date: "2026.05", title: "抖音百万播放", desc: "抖音发布视频，超百万人观看，项目引爆关注" },
  { date: "2026.05", title: "v1.2.9 OpenClaw", desc: "OpenClaw 接入 + fomo 桌宠 + 官方版本验证" },
  { date: "即将到来", title: "Windows 版", desc: "Windows 版本开发中，即将上线" },
];

export default function Home() {
  const [activeEngine, setActiveEngine] = useState("direct");
  const [islandIndex, setIslandIndex] = useState(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    intervalRef.current = setInterval(() => {
      setIslandIndex((prev) => (prev + 1) % islandStates.length);
    }, 2400);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, []);

  const engine = engines[activeEngine] || engines.direct;
  const [islandMode, islandStatus] = islandStates[islandIndex];

  const selectEngine = useCallback((key: string) => {
    setActiveEngine(key);
  }, []);

  return (
    <div className="hermespet-page">
      {/* Header */}
      <header className="site-header">
        <a className="brand" href="#top">
          <img src={ICON_URL} alt="" />
          <span>HermesPet</span>
        </a>
        <nav>
          <a href="#experience">体验</a>
          <a href="#engines">引擎</a>
          <a href="#timeline">历程</a>
          <a href="#privacy">隐私</a>
          <a href="#official">官方</a>
        </nav>
        <a
          className="header-action"
          href="https://github.com/basionwang-bot/HermesPet"
          target="_blank"
          rel="noreferrer"
        >
          GitHub
        </a>
      </header>

      <main id="top">
        {/* Hero */}
        <section className="hero">
          <div className="hero-content">
            <div>
              <div className="hero-badges">
                <span className="hero-badge hero-badge--official">官方网站</span>
                <span className="hero-badge hero-badge--platform">macOS 14+</span>
                <span className="hero-badge hero-badge--win">Windows 即将上线</span>
              </div>
              <h1>HermesPet</h1>
              <p className="hero-lede">
                让 AI 住进 MacBook 刘海里。点一下就聊，按住就说，拖进文件让它自己读。
                纯原生 Swift 6 + SwiftUI 构建，非 Electron，非 WebView。
              </p>
              <div className="hero-cta">
                <a
                  className="btn-primary"
                  href="https://github.com/basionwang-bot/HermesPet/releases/latest"
                  target="_blank"
                  rel="noreferrer"
                >
                  下载最新 DMG
                </a>
                <a className="btn-secondary" href="#experience">
                  了解更多
                </a>
              </div>
              <div className="hero-links">
                <a className="hero-link-card" href="https://github.com/basionwang-bot/HermesPet/tree/main/Sources" target="_blank" rel="noreferrer">
                  <div>
                    <div className="link-label">Sources</div>
                    <div className="link-text">Swift 源码</div>
                  </div>
                </a>
                <a className="hero-link-card" href="https://github.com/basionwang-bot/HermesPet/releases" target="_blank" rel="noreferrer">
                  <div>
                    <div className="link-label">Releases</div>
                    <div className="link-text">版本下载</div>
                  </div>
                </a>
                <a className="hero-link-card" href="https://github.com/basionwang-bot/HermesPet/blob/main/README.md" target="_blank" rel="noreferrer">
                  <div>
                    <div className="link-label">README</div>
                    <div className="link-text">完整文档</div>
                  </div>
                </a>
              </div>
            </div>
            <div className="hero-visual">
              <img src={BANNER_URL} alt="HermesPet 产品展示" />
              {/* Dynamic Island Demo */}
              <div className="dynamic-island" style={{ marginTop: '24px' }}>
                <div className="island-content">
                  <span className="island-dot" style={{ background: 'var(--accent)' }}></span>
                  <span className="island-text">{islandMode}</span>
                  <span style={{ fontSize: '11px', color: 'var(--text-tertiary)' }}>{islandStatus}</span>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* Experience */}
        <section className="section" id="experience">
          <p className="section-label">核心体验</p>
          <h2 className="section-title">它把 AI 从"一个窗口"变成 Mac 顶部的常驻工作入口</h2>
          <div className="experience-grid">
            {[
              { num: "01", title: "点刘海", desc: "灵动岛胶囊呼出聊天窗口，状态、错误、后台任务都在顶部可见。" },
              { num: "02", title: "按住说话", desc: "全局 Push-to-Talk 录音，松开自动发送，屏幕边缘出现 Apple Intelligence 风格光环。" },
              { num: "03", title: "拖进文件", desc: "图片直接传给模型；文档只传本地路径，让 Claude / Codex 按需读取。" },
              { num: "04", title: "并行处理", desc: "每个对话独立锁定 AI 后端，翻译、写代码、生图可以同时跑。" },
            ].map((item) => (
              <article className="exp-card" key={item.num}>
                <span className="card-num">{item.num}</span>
                <h3>{item.title}</h3>
                <p>{item.desc}</p>
              </article>
            ))}
          </div>
        </section>

        {/* Flow */}
        <section className="section flow-section" id="flow">
          <p className="section-label">产品逻辑</p>
          <h2 className="section-title">一条消息从输入到完成的路径</h2>
          <div className="flow-list">
            {[
              { num: "1", title: "入口收集", desc: "聊天框、截图、语音、快问浮窗、桌面拖拽都会进入同一个 ViewModel。" },
              { num: "2", title: "会话绑定", desc: "新对话继承上次使用的模式，发出第一条用户消息后锁定该后端。" },
              { num: "3", title: "后端路由", desc: "在线 API 走 HTTP SSE；Claude / Codex 走本地 CLI 子进程并解析 JSON 流。" },
              { num: "4", title: "状态回传", desc: "工具调用、文件改动、后台完成、错误重试都通过通知驱动灵动岛更新。" },
            ].map((item) => (
              <div className="flow-step" key={item.num}>
                <div className="flow-num">{item.num}</div>
                <div>
                  <h3>{item.title}</h3>
                  <p>{item.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Engines */}
        <section className="section engines-section" id="engines">
          <p className="section-label">多引擎</p>
          <h2 className="section-title">不是切换模型，而是给不同任务安排不同工作台</h2>
          <div className="engine-tabs" role="tablist">
            {engineKeys.map((key) => (
              <button
                key={key}
                className={`engine-tab${activeEngine === key ? " active" : ""}`}
                type="button"
                role="tab"
                aria-selected={activeEngine === key}
                onClick={() => selectEngine(key)}
              >
                {engines[key].title}
              </button>
            ))}
          </div>
          <div className="engine-panel">
            <p className="engine-tag">{engine.kicker}</p>
            <h3>{engine.title}</h3>
            <p className="engine-desc">{engine.copy}</p>
            <ul>
              {engine.points.map((point, i) => (
                <li key={i}>{point}</li>
              ))}
            </ul>
            <a className="engine-link" href={engine.href} target="_blank" rel="noreferrer">
              {engine.linkLabel}
            </a>
          </div>
        </section>

        {/* Features */}
        <section className="section" id="features">
          <p className="section-label">细节能力</p>
          <h2 className="section-title">这些小东西让它真的像桌面伴侣</h2>
          <div className="features-grid">
            {[
              { title: "灵动岛任务状态", desc: "右耳显示加载、工具步骤、文件改动数量和完成对勾，后台任务也会发光提醒。" },
              { title: "全局语音输入", desc: "在任何 app 中按住快捷键说话，SFSpeechRecognizer 识别后直接送进当前对话。" },
              { title: "Spotlight 式快问", desc: "读取当前选中文本，临时问 AI，结果可以复制、回填、Pin 或转成完整聊天。" },
              { title: "桌面 Pin 卡片", desc: "把重要回复钉到桌面右上角，点击即可回到原对话继续处理。" },
              { title: "Clawd 桌面陪伴", desc: "Claude 模式空闲后会跳出刘海漫步，可嗅文件、接收拖拽、靠近鼠标互动。" },
              { title: "每日早报", desc: "本地记录应用使用和提问主题，由用户指定的 AI 生成一份 Markdown 早报。" },
            ].map((item) => (
              <article className="feature-card" key={item.title}>
                <h3>{item.title}</h3>
                <p>{item.desc}</p>
              </article>
            ))}
          </div>
        </section>

        {/* Privacy */}
        <section className="section privacy-section" id="privacy">
          <p className="section-label">技术与隐私</p>
          <h2 className="section-title">纯原生 macOS，数据边界讲得清楚</h2>
          <div className="privacy-grid">
            <div className="privacy-card">
              <h3>技术栈</h3>
              <ul>
                <li>Swift 6 + SwiftUI，非 Electron，非 WebView。</li>
                <li>ScreenCaptureKit 截屏，Carbon Event Manager 注册全局热键。</li>
                <li>Claude / Codex 通过本地 CLI 子进程接入，自动检测真实 PATH。</li>
                <li>流式输出统一回到 ChatViewModel，按会话和消息 ID 精准落位。</li>
              </ul>
            </div>
            <div className="privacy-card">
              <h3>数据边界</h3>
              <ul>
                <li>对话历史保存在 ~/.hermespet/conversations.json。</li>
                <li>图片保存在 ~/.hermespet/images/，JSON 里只存路径。</li>
                <li>Pin 卡片保存在 ~/.hermespet/pins.json。</li>
                <li>AI 调用走用户自己配置的后端，项目本身不代收数据。</li>
              </ul>
            </div>
          </div>
        </section>

        {/* Timeline */}
        <section className="section" id="timeline">
          <p className="section-label">开发历程</p>
          <h2 className="section-title">从第一行代码到现在，每一步都有迹可循</h2>
          <p className="section-desc">所有版本和提交记录均可在 GitHub 仓库中验证</p>
          <div className="timeline-grid">
            {timelineEvents.map((event, i) => (
              <div className="timeline-card" key={i}>
                <div className="timeline-date">{event.date}</div>
                <h4>{event.title}</h4>
                <p>{event.desc}</p>
              </div>
            ))}
          </div>
        </section>

        {/* Windows */}
        <section className="section windows-section">
          <p className="section-label" style={{ color: 'var(--blue)' }}>Windows 版本</p>
          <h2 className="section-title">HermesPet for Windows 马上上线</h2>
          <p className="section-desc">同样的多引擎架构，适配 Windows 原生体验</p>
          <div className="windows-grid">
            {[
              { icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/></svg>, title: "系统托盘集成", desc: "常驻 Windows 系统托盘，快速访问 AI 助手" },
              { icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M18 3a3 3 0 0 0-3 3v12a3 3 0 0 0 3 3 3 3 0 0 0 3-3 3 3 0 0 0-3-3H6a3 3 0 0 0-3 3 3 3 0 0 0 3 3 3 3 0 0 0 3-3V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3 3 3 0 0 0 3 3h12a3 3 0 0 0 3-3 3 3 0 0 0-3-3z"/></svg>, title: "全局快捷键", desc: "自定义全局快捷键，在任何应用中快速唤起" },
              { icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>, title: "多引擎支持", desc: "支持在线 AI、Hermes Gateway、Claude Code 等" },
              { icon: <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>, title: "文件拖拽", desc: "直接拖拽文件或截图到 HermesPet" },
            ].map((item, i) => (
              <div className="windows-card" key={i}>
                <div className="win-icon">{item.icon}</div>
                <h4>{item.title}</h4>
                <p>{item.desc}</p>
              </div>
            ))}
          </div>
        </section>

        {/* Install */}
        <section className="section install-section">
          <p className="section-label">安装</p>
          <h2 className="section-title">拿到 DMG，填一个 API Key，就能让它住进桌面</h2>
          <p className="section-desc">高级能力可以再安装 Claude Code 或 Codex CLI；不装也可以先用在线 AI 完成日常聊天、翻译、写作和看图。</p>
          <div className="install-cta">
            <a className="btn-primary" href="https://github.com/basionwang-bot/HermesPet/releases/latest" target="_blank" rel="noreferrer">
              下载 DMG
            </a>
            <a className="btn-secondary" href="https://github.com/basionwang-bot/HermesPet" target="_blank" rel="noreferrer">
              查看源码
            </a>
          </div>
        </section>

        {/* Official */}
        <section className="section official-section" id="official">
          <div style={{ textAlign: 'center' }}>
            <div className="official-badge">
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M8 0L10 5.5L16 6L11.5 10L13 16L8 12.5L3 16L4.5 10L0 6L6 5.5L8 0Z" fill="currentColor"/></svg>
              官方认证项目
            </div>
          </div>
          <h2 className="section-title">认准官方渠道，远离盗版风险</h2>
          <p className="section-desc">由原作者 Basion Wang 独立开发并维护，以下是唯一官方渠道</p>

          <div className="official-grid">
            <div className="official-card">
              <div className="card-label">原作者</div>
              <h4>Basion Wang</h4>
              <p>GitHub: @basionwang-bot</p>
            </div>
            <div className="official-card">
              <div className="card-label">版本验证</div>
              <h4>codesign 签名</h4>
              <p style={{ fontFamily: 'var(--font-mono)', fontSize: '12px', color: 'var(--accent)' }}>Team ID: R34KL4X4D9</p>
            </div>
            <div className="official-card">
              <div className="card-label">许可证</div>
              <h4>Apache License 2.0</h4>
              <p>使用需保留版权声明和 NOTICE 文件</p>
            </div>
            <div className="official-card">
              <div className="card-label">官方仓库</div>
              <h4>GitHub</h4>
              <p><a href="https://github.com/basionwang-bot/HermesPet" target="_blank" rel="noreferrer">github.com/basionwang-bot/HermesPet</a></p>
            </div>
          </div>

          {/* Stats */}
          <div className="stats-row" style={{ marginTop: '40px' }}>
            {[
              { icon: "⭐", value: "200+", label: "GitHub Stars" },
              { icon: "📦", value: "9+", label: "Releases" },
              { icon: "📝", value: "150+", label: "Commits" },
              { icon: "👨‍💻", value: "1 人", label: "独立开发者" },
            ].map((stat) => (
              <div className="stat-item" key={stat.label}>
                <div className="stat-icon">{stat.icon}</div>
                <div className="stat-value">{stat.value}</div>
                <div className="stat-label">{stat.label}</div>
              </div>
            ))}
          </div>
        </section>
      </main>

      {/* Footer */}
      <footer className="site-footer">
        <div className="footer-content">
          <div>
            <div className="footer-brand">
              <img src={ICON_URL} alt="" />
              <span>HermesPet</span>
            </div>
            <p className="footer-desc">让 AI 住在你 MacBook 的刘海里。由 Basion Wang 独立开发。</p>
          </div>
          <div className="footer-col">
            <h5>资源</h5>
            <a href="https://github.com/basionwang-bot/HermesPet" target="_blank" rel="noreferrer">GitHub 仓库</a>
            <a href="https://github.com/basionwang-bot/HermesPet/releases" target="_blank" rel="noreferrer">下载 Releases</a>
            <a href="https://github.com/basionwang-bot/HermesPet/issues" target="_blank" rel="noreferrer">Issues 反馈</a>
          </div>
          <div className="footer-col">
            <h5>法律</h5>
            <a href="https://github.com/basionwang-bot/HermesPet/blob/main/LICENSE" target="_blank" rel="noreferrer">Apache License 2.0</a>
            <a href="https://github.com/basionwang-bot/HermesPet/blob/main/NOTICE" target="_blank" rel="noreferrer">NOTICE 归属文件</a>
            <a href="https://github.com/basionwang-bot/HermesPet/blob/main/BRAND_GUIDELINES.md" target="_blank" rel="noreferrer">品牌使用指南</a>
          </div>
          <div className="footer-col">
            <h5>支持</h5>
            <a href="https://afdian.com/a/basionwang" target="_blank" rel="noreferrer">爱发电赞助</a>
            <a href="mailto:basionwang@gmail.com">联系作者</a>
            <a href="https://github.com/basionwang-bot/HermesPet/blob/main/CONTRIBUTING.md" target="_blank" rel="noreferrer">贡献指南</a>
          </div>
        </div>
        <div className="footer-bottom">
          <p>&copy; 2024-2026 Basion Wang. All rights reserved. Licensed under Apache License 2.0.</p>
          <p>&ldquo;HermesPet&rdquo; 及其 Logo 为 Basion Wang 的商标。未经授权不得用于商业推广。</p>
        </div>
      </footer>
    </div>
  );
}
