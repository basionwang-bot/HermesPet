import { useEffect, useRef, useState, useCallback } from "react";
import "../hermespet.css";

const ICON_URL = "/manus-storage/AppIcon-1024_b61c80df.png";

interface EngineData {
  mark: string;
  kicker: string;
  title: string;
  copy: string;
  points: string[];
  color: string;
  href: string;
  linkLabel: string;
}

const engines: Record<string, EngineData> = {
  direct: {
    mark: "云",
    kicker: "零依赖",
    title: "在线 AI",
    copy: "选择 DeepSeek、智谱、Kimi 或 OpenAI，填入 API Key 就能开始聊天、翻译、写作和看图。",
    points: [
      "适合分发给没有 CLI 环境的用户",
      "配置与 Hermes Gateway 完全独立保存",
      "默认新用户进入这一档，降低上手门槛",
    ],
    color: "direct",
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/APIClient.swift",
    linkLabel: "查看 APIClient.swift",
  },
  hermes: {
    mark: "H",
    kicker: "自托管",
    title: "Hermes Gateway",
    copy: "连接本地或自部署的 OpenAI 兼容 Gateway，把常规对话任务留在用户掌控的后端里。",
    points: [
      "默认地址 http://localhost:8642/v1",
      "健康检查走 /health",
      "适合隐私优先或已有自托管服务的用户",
    ],
    color: "hermes",
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/ProviderPreset.swift",
    linkLabel: "查看 ProviderPreset.swift",
  },
  claude: {
    mark: "⌘",
    kicker: "本地 Agent",
    title: "Claude Code",
    copy: "通过 claude CLI 执行深度编程任务，支持 Read、Edit、Bash 等工具调用，并把进度同步到灵动岛。",
    points: [
      "启动时自动检测真实 PATH",
      "文档附件以绝对路径交给 Claude 自己读",
      "Clawd 桌面陪伴只在这一模式下出现",
    ],
    color: "claude",
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/ClaudeCodeClient.swift",
    linkLabel: "查看 ClaudeCodeClient.swift",
  },
  codex: {
    mark: "</>",
    kicker: "代码 + 生图",
    title: "Codex",
    copy: "通过 codex exec 接入 OpenAI Codex，适合代码任务、图片理解和生成图像。",
    points: [
      "每个对话绑定独立 Codex thread",
      "输入图片用 -i 参数传入",
      "生成图片会自动捕获并持久化到消息里",
    ],
    color: "codex",
    href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/CodexClient.swift",
    linkLabel: "查看 CodexClient.swift",
  },
};

const islandStates: [string, string][] = [
  ["HermesPet", "状态示意"],
  ["Claude Code", "工具调用示意"],
  ["Codex", "生图能力示意"],
  ["在线 AI", "API 模式示意"],
];

const engineKeys = ["direct", "hermes", "claude", "codex"] as const;

export default function Home() {
  const [activeEngine, setActiveEngine] = useState("direct");
  const [islandIndex, setIslandIndex] = useState(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    intervalRef.current = setInterval(() => {
      setIslandIndex((prev) => (prev + 1) % islandStates.length);
    }, 2200);
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
    <div className="hermespet-page" style={{ scrollBehavior: "smooth" }}>
      <header className="site-header">
        <a className="brand" href="#top" aria-label="HermesPet 首页">
          <img src={ICON_URL} alt="" />
          <span>HermesPet</span>
        </a>
        <nav aria-label="页面导航">
          <a href="#experience">体验</a>
          <a href="#engines">引擎</a>
          <a href="#privacy">隐私</a>
          <a href="#install">安装</a>
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
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-media" aria-hidden="true"></div>
          <div className="hero-vignette" aria-hidden="true"></div>
          <div className="hero-content">
            <p className="eyebrow">Swift 6 / SwiftUI / macOS 14+</p>
            <h1 id="hero-title">HermesPet</h1>
            <p className="hero-lede">
              让 AI 住进 MacBook 刘海里。点一下就聊，按住就说，拖进文件让它自己读。
            </p>
            <div className="hero-actions" aria-label="主要操作">
              <a
                className="primary-link"
                href="https://github.com/basionwang-bot/HermesPet/releases/latest"
                target="_blank"
                rel="noreferrer"
              >
                下载最新 DMG
              </a>
              <a className="secondary-link" href="#flow">
                看消息流转
              </a>
            </div>
            <div className="source-links" aria-label="资料来源与真实跳转">
              <a
                href="https://github.com/basionwang-bot/HermesPet/blob/main/README.md"
                target="_blank"
                rel="noreferrer"
              >
                <span>README</span>
                <strong>功能描述来源</strong>
              </a>
              <a
                href="https://github.com/basionwang-bot/HermesPet/tree/main/Sources"
                target="_blank"
                rel="noreferrer"
              >
                <span>Sources</span>
                <strong>Swift 源码入口</strong>
              </a>
              <a
                href="https://github.com/basionwang-bot/HermesPet/releases/latest"
                target="_blank"
                rel="noreferrer"
              >
                <span>Releases</span>
                <strong>下载与版本</strong>
              </a>
            </div>
            <p className="source-note">
              静态介绍页，内容来自仓库 README 与源码梳理，不是实时数据看板。
            </p>
          </div>
          <aside className="island-demo" aria-label="灵动岛状态示意">
            <div className="notch"></div>
            <div className="island-pill">
              <span className="pixel-pet" aria-hidden="true"></span>
              <strong>{islandMode}</strong>
              <span>{islandStatus}</span>
            </div>
          </aside>
        </section>

        {/* Experience */}
        <section
          className="section intro-strip"
          id="experience"
          aria-labelledby="experience-title"
        >
          <div className="section-heading">
            <p className="eyebrow">核心体验</p>
            <h2 id="experience-title">
              它把 AI 从"一个窗口"变成 Mac 顶部的常驻工作入口
            </h2>
          </div>
          <div className="experience-grid">
            {[
              {
                num: "01",
                title: "点刘海",
                desc: "灵动岛胶囊呼出聊天窗口，状态、错误、后台任务都在顶部可见。",
              },
              {
                num: "02",
                title: "按住说话",
                desc: "全局 Push-to-Talk 录音，松开自动发送，屏幕边缘出现 Apple Intelligence 风格光环。",
              },
              {
                num: "03",
                title: "拖进文件",
                desc: "图片直接传给模型；文档只传本地路径，让 Claude / Codex 按需读取，不把全文塞进上下文。",
              },
              {
                num: "04",
                title: "并行处理",
                desc: "每个对话独立锁定 AI 后端，翻译、写代码、生图可以同时跑，不互相污染。",
              },
            ].map((item) => (
              <article className="experience-card" key={item.num}>
                <span>{item.num}</span>
                <h3>{item.title}</h3>
                <p>{item.desc}</p>
              </article>
            ))}
          </div>
        </section>

        {/* Flow */}
        <section
          className="section flow-section"
          id="flow"
          aria-labelledby="flow-title"
        >
          <div className="section-heading">
            <p className="eyebrow">产品逻辑</p>
            <h2 id="flow-title">一条消息从输入到完成的路径</h2>
          </div>
          <ol className="flow">
            {[
              {
                num: "1",
                title: "入口收集",
                desc: "聊天框、截图、语音、快问浮窗、桌面拖拽都会进入同一个 ViewModel。",
              },
              {
                num: "2",
                title: "会话绑定",
                desc: "新对话继承上次使用的模式，发出第一条用户消息后锁定该后端。",
              },
              {
                num: "3",
                title: "后端路由",
                desc: "在线 API 走 HTTP SSE；Claude / Codex 走本地 CLI 子进程并解析 JSON 流。",
              },
              {
                num: "4",
                title: "状态回传",
                desc: "工具调用、文件改动、后台完成、错误重试都通过通知驱动灵动岛更新。",
              },
            ].map((item) => (
              <li key={item.num}>
                <span>{item.num}</span>
                <h3>{item.title}</h3>
                <p>{item.desc}</p>
              </li>
            ))}
          </ol>
        </section>

        {/* Engines */}
        <section
          className="section engine-section"
          id="engines"
          aria-labelledby="engines-title"
        >
          <div className="section-heading">
            <p className="eyebrow">多引擎</p>
            <h2 id="engines-title">
              不是切换模型，而是给不同任务安排不同工作台
            </h2>
          </div>
          <div className="engine-layout">
            <div className="engine-tabs" role="tablist" aria-label="AI 后端模式">
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
            <article
              className="engine-panel"
              data-engine={engine.color}
              aria-live="polite"
            >
              <div className="engine-mark">{engine.mark}</div>
              <div>
                <p className="eyebrow">{engine.kicker}</p>
                <h3>{engine.title}</h3>
                <p>{engine.copy}</p>
              </div>
              <ul>
                {engine.points.map((point, i) => (
                  <li key={i}>{point}</li>
                ))}
              </ul>
              <a
                className="engine-link"
                href={engine.href}
                target="_blank"
                rel="noreferrer"
              >
                {engine.linkLabel}
              </a>
            </article>
          </div>
        </section>

        {/* Features */}
        <section
          className="section feature-section"
          aria-labelledby="features-title"
        >
          <div className="section-heading">
            <p className="eyebrow">细节能力</p>
            <h2 id="features-title">这些小东西让它真的像桌面伴侣</h2>
          </div>
          <div className="feature-grid">
            {[
              {
                icon: "DI",
                iconColor: "red",
                title: "灵动岛任务状态",
                desc: "右耳显示加载、工具步骤、文件改动数量和完成对勾，后台任务也会发光提醒。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/DynamicIslandController.swift",
              },
              {
                icon: "VO",
                iconColor: "amber",
                title: "全局语音输入",
                desc: "在任何 app 中按住快捷键说话，SFSpeechRecognizer 识别后直接送进当前对话。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/VoiceInputController.swift",
              },
              {
                icon: "QA",
                iconColor: "blue",
                title: "Spotlight 式快问",
                desc: "读取当前选中文本，临时问 AI，结果可以复制、回填、Pin 或转成完整聊天。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/QuickAskWindow.swift",
              },
              {
                icon: "PN",
                iconColor: "green",
                title: "桌面 Pin 卡片",
                desc: "把重要回复钉到桌面右上角，点击即可回到原对话继续处理。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/PinCardOverlay.swift",
              },
              {
                icon: "CL",
                iconColor: "red",
                title: "Clawd 桌面陪伴",
                desc: "Claude 模式空闲后会跳出刘海漫步，可嗅文件、接收拖拽、靠近鼠标互动。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/ClawdWalkOverlay.swift",
              },
              {
                icon: "AM",
                iconColor: "amber",
                title: "每日早报",
                desc: "本地记录应用使用和提问主题，由用户指定的 AI 生成一份 Markdown 早报。",
                href: "https://github.com/basionwang-bot/HermesPet/blob/main/Sources/MorningBriefingService.swift",
              },
            ].map((item) => (
              <a
                key={item.icon}
                className="feature-card"
                href={item.href}
                target="_blank"
                rel="noreferrer"
              >
                <span className={`feature-icon ${item.iconColor}`}>
                  {item.icon}
                </span>
                <h3>{item.title}</h3>
                <p>{item.desc}</p>
                <span className="card-link">查看对应源码</span>
              </a>
            ))}
          </div>
        </section>

        {/* Privacy */}
        <section
          className="section privacy-section"
          id="privacy"
          aria-labelledby="privacy-title"
        >
          <div className="section-heading">
            <p className="eyebrow">技术与隐私</p>
            <h2 id="privacy-title">纯原生 macOS，数据边界讲得清楚</h2>
          </div>
          <div className="privacy-layout">
            <article className="tech-panel">
              <h3>技术栈</h3>
              <ul>
                <li>Swift 6 + SwiftUI，非 Electron，非 WebView。</li>
                <li>
                  ScreenCaptureKit 截屏，Carbon Event Manager 注册全局热键。
                </li>
                <li>
                  Claude / Codex 通过本地 CLI 子进程接入，自动检测真实 PATH。
                </li>
                <li>
                  流式输出统一回到 ChatViewModel，按会话和消息 ID 精准落位。
                </li>
              </ul>
            </article>
            <article className="tech-panel">
              <h3>数据边界</h3>
              <ul>
                <li>
                  对话历史保存在{" "}
                  <code>~/.hermespet/conversations.json</code>。
                </li>
                <li>
                  图片保存在 <code>~/.hermespet/images/</code>
                  ，JSON 里只存路径。
                </li>
                <li>
                  Pin 卡片保存在 <code>~/.hermespet/pins.json</code>。
                </li>
                <li>AI 调用走用户自己配置的后端，项目本身不代收数据。</li>
              </ul>
            </article>
          </div>
        </section>

        {/* Install */}
        <section
          className="install-section"
          id="install"
          aria-labelledby="install-title"
        >
          <div>
            <p className="eyebrow">安装</p>
            <h2 id="install-title">
              拿到 DMG，填一个 API Key，就能让它住进桌面
            </h2>
            <p>
              高级能力可以再安装 Claude Code 或 Codex
              CLI；不装也可以先用在线 AI 完成日常聊天、翻译、写作和看图。
            </p>
          </div>
          <div className="install-actions">
            <a
              className="primary-link"
              href="https://github.com/basionwang-bot/HermesPet/releases/latest"
              target="_blank"
              rel="noreferrer"
            >
              下载 DMG
            </a>
            <a
              className="secondary-link"
              href="https://github.com/basionwang-bot/HermesPet"
              target="_blank"
              rel="noreferrer"
            >
              查看源码
            </a>
          </div>
        </section>
      </main>
    </div>
  );
}
