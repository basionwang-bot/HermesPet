# HermesPet 聆听态星云动效 · Claude Code 执行规格

> 把这份文件放进 HermesPet 仓库(建议 `docs/specs/listening-nebula.md`),
> 然后对 Claude Code 说:**"按照 docs/specs/listening-nebula.md 实现聆听态动效"**。

---

## 1. 目标

为 HermesPet 实现一个「正在聆听」状态的粒子动效,渲染在刘海(notch)下方的胶囊区域内。
视觉效果:**中央星云**——大量细碎的发光粒子聚拢在胶囊中段,向两端快速淡出,
整体缓慢横向流动并带有个体闪烁,传达"实时接收声音"的状态。

视觉参考已在浏览器原型中确认,参数已锁定(见 §3),**不要改动默认值**,
但所有参数必须通过 `NebulaConfig` 暴露,便于后续微调。

## 2. 技术选型

- **首选:SwiftUI `TimelineView(.animation)` + `Canvas`**,粒子用
  `context.blendMode = .plusLighter` 做加色混合。
- 粒子数 900 在 Apple Silicon 上 Canvas 可以稳定 60fps,但这是常驻刘海的动效,
  必须满足 §6 的能耗约束;如果 Instruments 实测 CPU 占用 > 8%,降级方案:
  1. 先把粒子绘制从径向渐变改为预渲染的单张辉光贴图(`Image`)按 alpha 绘制;
  2. 仍不达标再迁移 `CAMetalLayer` + 简单 point sprite shader。
- **不要引入第三方依赖。**
- ⚠️ 项目历史上有 SwiftUI 布局递归崩溃记录(见 GitHub issues)。本视图内部
  **禁止**在 body 中读取会触发自身重布局的状态;动画驱动只走 TimelineView 的
  时间参数,粒子状态放在 `@State` 之外的引用类型容器(class)里,避免每帧
  invalidate 整棵视图树。

## 3. 锁定参数(来自原型调参,作为 NebulaConfig 默认值)

```swift
struct NebulaConfig {
    var speed: Double        = 1.5    // 原型值 2.8 偏快,落地默认 1.5;保留注释说明
    var particleCount: Int   = 900    // 粒子总数;低功耗模式减半(§6)
    var glowSize: Double     = 0.5    // 粒子辉光半径系数 → 细碎星点
    var waveAmplitude: Double = 20    // 中心线正弦波幅(pt)
    var verticalSpread: Double = 30   // 纵向发散(pt)→ 星云的"高"
    var focusRange: Double   = 0.12   // 高斯聚光 σ = 宽度 × 0.12 → 聚在中段
    var coreWhiteness: Double = 1.0   // 粒子核心趋白程度(0~1)
    var color: (r: Double, g: Double, b: Double) = (95/255, 217/255, 245/255) // #5FD9F5
}
```

## 4. 算法(与原型逐条对应,必须一致)

每个粒子持有:
- `x ∈ [0,1)`:沿胶囊宽度的归一化位置
- `off ∈ [-1,1]`:纵向偏移基准
- `drift`:个体相位(随机 0~2π)
- `size`:0.4 + rand×0.9
- `tw`:闪烁速度 0.5 + rand×1.8
- `v`:个体流速 0.5 + rand×0.9

每帧(t 为秒):
1. **流动**:`x += speed × 0.0012 × v`,超过 1 回绕到 0。
2. **绘制坐标**:
   - `px = padX + x × (W − 2·padX)`,其中 `padX = W × 0.16`(两端留白)
   - 中心线:`waveY = sin(x·3π + t·1.4) × waveAmplitude`
   - 高斯包络:`env = exp(−(px−cx)² / (2σ²))`,`σ = W × focusRange`
   - 抖动:`jitter = sin(t·tw + drift) × 0.5`
   - `py = midY + waveY + (off + jitter) × verticalSpread × (0.4 + env)`
3. **亮度**:`alpha = env × (0.55 + 0.45·sin(t·tw·1.6 + drift)) × 0.9`,
   alpha < 0.01 直接跳过(两端粒子大量被剔除,这是性能关键)。
4. **半径**:`rad = (1.1 + size×glowSize) + env×glowSize×1.4`。
5. **颜色**:核心色 = 基础色向白色插值 `coreWhiteness`;
   径向渐变三档:核心(alpha)→ 基础色(alpha×0.5, 40%处)→ 透明。
   加色混合(plusLighter)。
6. **底层柔光**:中心一个半径 σ×1.1 的径向渐变,峰值 alpha 0.08,基础色。

## 5. 集成点

- 新增 `Views/Effects/ListeningNebulaView.swift`,对外接口:
  ```swift
  ListeningNebulaView(config: NebulaConfig = .init(), isActive: Bool)
  ```
- `isActive == false` 时粒子在 0.4s 内淡出并**停止 TimelineView 驱动**
  (用 `.paused` schedule 或条件渲染),不允许后台空转。
- 挂接到现有的宠物状态机:进入「聆听/语音输入」状态时 `isActive = true`。
  具体状态名以仓库现有代码为准,先 grep 状态枚举再接线,不要新造状态。

## 6. 能耗与稳定性约束(验收门槛)

- 动效激活时 CPU < 8%(M 系芯片,Activity Monitor 或 Instruments Time Profiler)。
- `ProcessInfo.processInfo.isLowPowerModeEnabled == true` 时:
  粒子数减半、帧率目标降到 30fps。
- 系统「减弱动态效果」(`accessibilityReduceMotion`)开启时:
  粒子静止,只保留缓慢的整体 alpha 呼吸(2s 周期)。
- 连续运行 10 分钟无内存增长(粒子数组一次分配,帧循环零分配——
  不要在每帧创建数组或闭包捕获)。
- 不得触发 SwiftUI 布局重入:用 Xcode 的 `Self._printChanges()` 抽查,
  确认每帧只有 TimelineView 时间变化,无其他依赖失效。

## 7. 验收清单

- [ ] 视觉与原型截图一致:中央星云、两端全黑、细碎星点、缓慢流动+闪烁
- [ ] isActive 切换有 0.4s 淡入淡出,关闭后零 CPU 占用
- [ ] 低功耗模式与减弱动态效果两条路径均验证
- [ ] CPU/内存达标(附 Instruments 截图到 PR)
- [ ] 深色/浅色外观下背景均为纯黑胶囊(此动效只为深色设计,浅色下同样用深底)

---

> 实现备注(2026-06-10,Claude Code):本仓库为扁平 `Sources/` 结构,实际落地文件为
> `Sources/ListeningNebulaView.swift`(代替规格建议的 `Views/Effects/` 路径);
> 挂接点 = `VoiceChatController.swift` 语音陪聊卡片,`isActive = (state.phase == .listening)`。
