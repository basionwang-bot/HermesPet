import AppKit
import Foundation

/// 屏幕智能体（v1.6「AI 看屏幕」里程碑 3）—— 第一次把 眼·脑·手 串成闭环。
///
/// 单步闭环：**看**（截窗口 + OCR 出带坐标的文字）→ **想**（喂给用户当前选的 AI，让它只回一个高层动作）
/// → **做**（把动作映射成坐标，用 ScreenActuator 真去点 / 打字 / 按键）。
///
/// 里程碑 3 只走**一步**、手动触发。自动多步循环 + 微信场景留到里程碑 4。
///
/// 关键设计（讨论定，见 TODO 里程碑总览）：
/// - 脑 = `viewModel.streamOneShotAsk`（**跟随用户选的 AgentMode**，不绑死在线 AI）。
/// - AI 只说「点哪个**文字标签**」，坐标由本地 OCR 方框查出来 → 纯文本模型也能驱动点击。
enum ScreenAgent {

    /// AI 返回的单个高层动作（严格 JSON）。
    struct AgentAction: Decodable {
        let action: String      // click | type | key | done
        let target: String?     // click：要点击的文字标签（必须是窗口里出现过的文字）
        let text: String?       // type：要输入的文字
        let key: String?        // key：return | tab | esc | space | delete
        let note: String?       // AI 的简短理由 / 说明
    }

    // MARK: - 决策 prompt

    private static func decisionPrompt(goal: String, listing: String) -> String {
        """
        你在帮用户操作一个 macOS 应用窗口。用户的目标是：
        「\(goal)」

        下面是当前窗口里识别到的文字元素（每行：序号. 文字）：
        \(listing)

        请只决定**下一步的一个动作**，并且**只输出一个 JSON 对象**，不要任何解释、不要 markdown 围栏、不要多余文字。可选格式：
        - 点击某个文字（target 必须是上面出现过的文字，尽量用完整一段）：
          {"action":"click","target":"设置","note":"为什么这么做"}
        - 输入文字（会打进当前光标处）：
          {"action":"type","text":"你好","note":"..."}
        - 按一个键（可用 return/tab/esc/space/delete；微信回车即发）：
          {"action":"key","key":"return","note":"..."}
        - 目标已达成、或无需任何操作：
          {"action":"done","note":"原因"}

        只输出那一个 JSON 对象。
        """
    }

    // MARK: - 单步闭环

    /// 对窗口执行一步：看 → 想 → 做。供接管「手动指挥」调用（锁定目标窗口）。
    /// `windowID` 指定目标窗口；nil 时取最前窗口。
    @MainActor
    static func runOnce(goal: String,
                        windowID: CGWindowID? = nil,
                        viewModel: ChatViewModel,
                        announce: @escaping @MainActor (String) -> Void) async {
        guard ScreenActuator.ensureTrusted() else {
            announce("需要「辅助功能」权限，已弹出系统设置——允许后再试")
            return
        }

        // 1. 看：定位目标窗口 → OCR 出带坐标的文字
        let windows = await ScreenCapture.listWindows()
        let target: ScreenCapture.ShareableWindow?
        if let wid = windowID {
            target = windows.first(where: { $0.id == wid })
        } else {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            target = windows.first(where: { $0.pid == frontPID }) ?? windows.first
        }
        guard let target else {
            announce("没找到可操作的窗口")
            return
        }
        let elements = await ScreenPerception.readWindow(id: target.id)
        guard !elements.isEmpty else {
            announce("「\(target.title)」里没认出文字，无法决策")
            return
        }
        announce("看了「\(target.title)」，认出 \(elements.count) 段文字，正在让 AI 决策…")

        // 2. 想：把文字清单 + 目标喂给用户当前选的 AI（不写入活动记录）
        let listing = elements.prefix(80)
            .map { "\($0.id + 1). \($0.text)" }
            .joined(separator: "\n")
        let prompt = decisionPrompt(goal: goal, listing: listing)

        var reply = ""
        do {
            for try await chunk in viewModel.streamOneShotAsk(prompt: prompt, recordToActivity: false) {
                reply += chunk
            }
        } catch {
            announce("AI 决策失败：\(error.localizedDescription)")
            return
        }

        guard let act = parseAction(reply) else {
            announce("没读懂 AI 返回的动作：\(reply.prefix(120))")
            return
        }

        // 3. 做：执行前**先激活目标窗口** —— 否则 type/click 会打到当前焦点 app
        //    （之前 bug：发指令的输入框属于 HermesPet，确定后焦点在 HermesPet，结果文字打进了它自己的输入框）
        // 审计 #12：目标 app 已退出时 activate 静默 no-op，会把操作打进当前焦点 app → 取不到就中止。
        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            announce("目标 app 已退出，取消操作")
            return
        }
        app.activate(options: [])
        try? await Task.sleep(nanoseconds: 250_000_000)
        await execute(act, elements: elements, announce: announce)
    }

    /// 执行单个动作。
    @MainActor
    static func execute(_ act: AgentAction,
                        elements: [ScreenPerception.TextElement],
                        announce: @escaping @MainActor (String) -> Void) async {
        switch act.action.lowercased() {
        case "click":
            guard let label = act.target,
                  let el = ScreenPerception.findElement(matching: label, in: elements) else {
                announce("AI 想点「\(act.target ?? "?")」，但窗口里没找到这段文字")
                return
            }
            let why = act.note.map { "（\($0)）" } ?? ""
            announce("AI 决定：点击「\(el.text)」\(why)")
            ScreenActuator.click(at: el.center)
            announce("已点击 ✓")

        case "type":
            let t = act.text ?? ""
            announce("AI 决定：输入「\(t)」")
            ScreenActuator.typeText(t)
            announce("已输入 ✓")

        case "key":
            announce("AI 决定：按键 \(act.key ?? "?")")
            pressNamedKey(act.key)
            announce("已按键 ✓")

        case "done":
            announce("AI 判断：完成 ✓ \(act.note ?? "")")

        default:
            announce("AI 返回了未知动作：\(act.action)")
        }
    }

    // MARK: - 工具

    /// 从 AI 回复里抠出第一个 JSON 对象并解析（容忍 ```json 围栏 / 前后多余文字 / 推理）。
    static func parseAction(_ raw: String) -> AgentAction? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonStr = String(raw[start...end])
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentAction.self, from: data)
    }

    /// 把动作名映射成实际按键。
    private static func pressNamedKey(_ name: String?) {
        switch (name ?? "").lowercased() {
        case "return", "enter": ScreenActuator.pressReturn()
        case "tab":             ScreenActuator.pressKey(ScreenActuator.Key.tab)
        case "esc", "escape":   ScreenActuator.pressKey(ScreenActuator.Key.escape)
        case "space":           ScreenActuator.pressKey(ScreenActuator.Key.space)
        case "delete", "backspace": ScreenActuator.pressKey(ScreenActuator.Key.delete)
        default:                ScreenActuator.pressReturn()
        }
    }
}
