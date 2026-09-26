//
//  WannaTests.swift
//  WannaTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Testing
@testable import Wanna

/// **`@MainActor` 是必须的**：App 侧的 `WindowPositionManager`、`NotchSupport`
/// 这些静态方法都带主 actor 隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），
/// 不标的话这些测试根本编不过 —— 这个测试目标在此之前就是这样（三个测试全红）。
@MainActor
struct WannaTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    // MARK: - 刘海左侧那一排临时 agent 按钮的几何（2026-09-26）

    /// **画出来的位置**和**点下去命中的矩形**必须是同一个地方，而且在「静止窗口」和
    /// 「展开面板」两个状态下都是。
    ///
    /// 这条测试锁的是一个已经各错过一次的东西：视图原来读的是**给展开态窗口算的**
    /// notch 中心，于是按钮被画到距刘海 20pt 的地方、而命中区在 96pt 外（差 98.5pt，
    /// 用户点它没有任何反应）；修的时候又把它写成"静止窗口坐标"，展开那一刻整排
    /// 跟着窗口原点平移 68pt（实测按钮画到 x=566，命中区在 622–662）。
    ///
    /// 锁的性质是：**两种窗口都居中在刘海中心上**，所以「容器中心 + 相对刘海中心的
    /// 偏移」在两个宽度下算出来的是同一个屏幕位置 —— 谁把某一侧的外扩改得不对称，
    /// 这条就会红。
    @Test func agentStripLandsInTheSamePlaceInBothWindowStates() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let notchCenterX = try #require(NotchSupport.notchRect(on: screen)).midX + screen.frame.minX
        let hitRect = try #require(NotchSupport.agentButtonFrame(on: screen, indexFromNotch: 0))
        let trailingOffset = try #require(NotchSupport.agentStripTrailingXFromNotchCenter(on: screen))

        for windowFrame in [try #require(NotchSupport.restingWindowFrame(on: screen)),
                            NotchSupport.expandedSheetFrame(on: screen)] {
            // ① 前提：窗口中心落在刘海中心上（静止窗口两侧外扩必须等宽）。
            #expect(abs((windowFrame.minX + windowFrame.width / 2) - notchCenterX) < 0.5)
            // ② 结论：视图那套算法画出来的右边缘 = 命中矩形的右边缘。
            let drawnRightEdge = windowFrame.minX + windowFrame.width / 2 + trailingOffset
            #expect(abs(drawnRightEdge - hitRect.maxX) < 0.5)
        }
    }

    /// 那一排必须让开**最宽的那次左侧展开**：录音那条带 = 左翼 + 圆角重叠（86 + 14）。
    @Test func agentStripClearsTheWidestLeftExpansion() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let notch = try #require(NotchSupport.notchRect(on: screen))
        let hitRect = try #require(NotchSupport.agentButtonFrame(on: screen, indexFromNotch: 0))
        let widestLeftExpansion = NotchSupport.leadingWingWidth + NotchSupport.recordingBandLeadingOverlap
        #expect((screen.frame.minX + notch.minX) - hitRect.maxX >= widestLeftExpansion,
                "录音展开时会把这一排盖住")
    }

    /// 按钮高度 = 菜单栏高度（= 刘海那一条），且**顶对齐**。
    ///
    /// 高度是用户 2026-09-26 明确要的（「按钮的高度应该显示到整个菜单栏的高度一样」）；
    /// 顶对齐是因为视图挂在 `.overlay(alignment: .topLeading)` 上 —— 命中矩形原来
    /// "竖直居中在刘海带里"，比画出来的位置低 5pt，点按钮上半部分会落空。
    @Test func agentButtonIsAsTallAsTheMenuBarAndTopAligned() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let hitRect = try #require(NotchSupport.agentButtonFrame(on: screen, indexFromNotch: 0))
        #expect(hitRect.height == screen.safeAreaInsets.top)
        #expect(abs(hitRect.maxY - screen.frame.maxY) < 0.5)
        #expect(hitRect.width > hitRect.height, "用户要的是长方形（宽 > 高）")
    }

    /// **自动核验的三态判定。**
    ///
    /// 用户 2026-09-26：「总是显示缺少验证…应该让 AI 自动验证吧」。判据的核心是
    /// **不听模型说，听证据**：说成功但给出的路径不存在 → 没做成（他踩过的正是这个：
    /// 说「文件建好了」，桌面上什么都没有）；证据核对不了（"界面上显示了"）→ 停在未核验；
    /// 没按格式答 → 当"说不清"，**不是失败**（否则一堆本来成功的任务会被判死）。
    @Test func jobVerificationChecksTheEvidenceItself() async throws {
        #expect(JobVerification.status(for: JobVerification.parse("结果=成功；证据=/tmp"))
                == .doneVerified)
        #expect(JobVerification.status(for: JobVerification.parse("结果=成功；证据=/tmp/绝对不存在的文件-xyz.txt"))
                == .failed)
        #expect(JobVerification.status(for: JobVerification.parse("结果=成功；证据=界面上显示了那个文件夹"))
                == .doneUnverified)
        #expect(JobVerification.status(for: JobVerification.parse("结果=失败；证据=报错"))
                == .failed)
        #expect(JobVerification.status(for: JobVerification.parse("我看了一下，应该成了吧"))
                == .doneUnverified)
    }

    /// **同一个目标派出去的多个 agent = 侧栏里的一个文件夹。**
    ///
    /// 用户 2026-09-26：「一个目标需要同时调用多个 agent 来执行…那在左侧列表是不是应该
    /// 去做一个关联？自动创建一个文件夹、一个分组，把同一个任务派发出来的多个子 agent
    /// 全部放在这一组上」。判据有两条，缺一条都不算对：**同组的折在一起**、
    /// **没组的自己一行且不画成文件夹**。
    @Test func tasksFromOneGoalAreGrouped() async throws {
        let board = AgentActivityBoard.shared
        let groupID = UUID().uuidString
        let first = board.beginTask(request: "第一个子任务", groupID: groupID)
        let second = board.beginTask(request: "第二个子任务", groupID: groupID)
        let solo = board.beginTask(request: "没分组的独立任务")

        let groups = board.sidebarGroups
        let folder = groups.first { $0.members.contains { $0.id == first } }
        #expect(folder?.members.count == 2, "同组两个应该在一个文件夹里")
        #expect(folder?.members.contains { $0.id == second } == true)
        #expect(folder?.isFolder == true, "多于一个就该按文件夹画")

        let soloGroup = groups.first { $0.members.contains { $0.id == solo } }
        #expect(soloGroup?.members.count == 1)
        #expect(soloGroup?.isFolder == false, "没组的自己一行，不该画成文件夹")

        for id in [first, second, solo] { board.finishTask(id, status: .doneVerified) }
    }

    /// **点那一排小按钮 → 弹出面板**，这条链必须真的通。
    ///
    /// 2026-09-26 它两半都是坏的：命中矩形离按钮 98.5pt（几何，上面那条锁着），
    /// 以及 `AgentPanelController` —— 那个"监听 `manualPanelID` 一变就开面板"的
    /// 单例 —— **在全仓没有任何引用**。懒汉单例没人碰就没人创建，`init` 里那条订阅
    /// 从来没装上：`togglePanel` 把 id 写进去了，**没人在听**，于是用户看到的是
    /// 「点击它之后没有下拉菜单」。
    ///
    /// 这条测的就是"有没有人在听"：先让看板 toggle 一次，再看面板有没有认下这个
    /// agent。**关键在断言时才去碰 `AgentPanelController.shared` 已经是事后** ——
    /// 它不能把缺失的订阅补上（订阅只在 `init` 里装，而 `manualPanelID` 那次变化
    /// 早就过去了），所以启动时没装，这里一定是 nil。
    ///
    /// 修法是 `CompanionManager.start()` 里那行 `_ = AgentPanelController.shared`。
    @Test func togglingAnAgentOpensThePanel() async throws {
        let board = AgentActivityBoard.shared
        let agentID = board.beginTask(request: "这条测试是假的：只为验证面板会不会开")
        board.togglePanel(agentID)
        // **等一拍。** 那条订阅是 `.receive(on: DispatchQueue.main)`，投递发生在
        // 下一个主队列回合 —— 不等的话断言跑在投递之前，测的就是噪音。
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(AgentPanelController.shared.shownAgentID == agentID,
                "面板没开 —— AgentPanelController 的订阅没装上（看 CompanionManager.start() 里那行）")
        // 收尾：判成"核验过"，它会自己退场，不在看板上留东西。
        board.togglePanel(agentID)
        board.finishTask(agentID, status: .doneVerified)
    }

}
