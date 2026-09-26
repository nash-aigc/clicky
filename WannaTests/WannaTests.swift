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

    // MARK: - 屏幕右上角那一排临时 agent 的几何（2026-09-26）
    //
    // 这一组锁的是同一条性质，只是位置从刘海左侧搬到了屏幕右上角：**画出来的那一排**
    // 和**点下去命中的矩形**必须重合，而重合是靠"两者读同一批 `NotchSupport` 常量"
    // 做到的 —— 视图那一列右对齐铺满面板，面板的右边缘就是第 0 颗按钮的右边缘，
    // 面板的上边缘就是所有按钮的上边缘。
    //
    // 这个仓库在"画的和点的各算一遍"上被打过三次（D13）：一次是视图读了给展开态窗口
    // 算的中心（差 98.5pt，点了没反应），一次是整排跟着窗口原点平移了 68pt。所以这条
    // 断言不是形式主义 —— 它是那两个 bug 各自的判据。

    /// **面板（画的那块窗口）和按钮的命中矩形必须重合**：右边缘齐、上边缘齐。
    @Test func agentStripPanelAgreesWithTheButtonHitRect() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let panelFrame = NotchSupport.agentStripPanelFrame(on: screen)
        let firstButton = try #require(NotchSupport.agentButtonFrame(on: screen,
                                                                    indexFromTrailingEdge: 0))

        // ① 右边缘：面板的右边缘 = 第 0 颗按钮的右边缘（视图是右对齐铺满的）。
        #expect(abs(panelFrame.maxX - firstButton.maxX) < 0.5)
        // ② 上边缘：面板的顶边 = 按钮那一行的顶边（视图是顶对齐铺满的）。
        #expect(abs(panelFrame.maxY - firstButton.maxY) < 0.5)
        // ③ 面板装得下它自己要画的东西：按钮那一行 + 两张卡片。
        let buttonsRowWidth = CGFloat(NotchSupport.maximumVisibleAgentButtons) * NotchSupport.agentButtonWidth
            + CGFloat(NotchSupport.maximumVisibleAgentButtons - 1) * NotchSupport.agentButtonSpacing
        #expect(panelFrame.width >= buttonsRowWidth)
        // ④ 整块面板落在屏幕里（右边缘还留着那道外沿）。
        #expect(panelFrame.maxX <= screen.frame.maxX - NotchSupport.agentStripOuterMargin + 0.5)
        #expect(panelFrame.minX >= screen.frame.minX)
    }

    /// **这一排贴在菜单栏下面一行，而不是压在菜单栏上。**
    ///
    /// 用户 2026-09-26：「应该放在右侧，电脑屏幕的时间日期这个菜单栏的**下面一行**」——
    /// 所以按钮的顶边是屏幕顶边往下 `menuBarHeight`，而不是屏幕顶边本身。
    @Test func agentStripHangsBelowTheMenuBar() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let menuBarHeight = NotchSupport.menuBarHeight(on: screen)
        #expect(menuBarHeight > 0, "菜单栏高度必须量得到，否则这一排会钻到菜单栏底下")

        let firstButton = try #require(NotchSupport.agentButtonFrame(on: screen,
                                                                    indexFromTrailingEdge: 0))
        #expect(abs(firstButton.maxY - (screen.frame.maxY - menuBarHeight)) < 0.5)
    }

    /// **按钮高度 = 菜单栏高度**（用户：「按钮的高度应该显示到整个菜单栏的高度一样」），
    /// 而且是长方形（宽 > 高）。
    @Test func agentButtonIsAsTallAsTheMenuBar() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let hitRect = try #require(NotchSupport.agentButtonFrame(on: screen,
                                                                 indexFromTrailingEdge: 0))
        #expect(hitRect.height == NotchSupport.menuBarHeight(on: screen))
        #expect(hitRect.height == screen.safeAreaInsets.top)
        #expect(hitRect.width > hitRect.height, "用户要的是长方形（宽 > 高）")
    }

    /// **那一排必须让开刘海那一带最宽的那次右侧展开。**
    ///
    /// 原来这条断言的是"让开录音带在**左侧**多压出来的 100pt"；那一排搬到右上角之后，
    /// 会朝它伸过来的东西变成了刘海**右翼**（语音/播报时滑出的 `trailingWingWidth`）——
    /// 所以判据换成"最左边那颗按钮的左边缘，在刘海右边缘 + 右翼宽度之外"。
    @Test func agentStripClearsTheNotchAndItsRightWing() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let notch = try #require(NotchSupport.notchRect(on: screen))
        let leftmostButton = try #require(
            NotchSupport.agentButtonFrame(on: screen,
                                          indexFromTrailingEdge: NotchSupport.maximumVisibleAgentButtons - 1)
        )
        let notchRightEdge = screen.frame.minX + notch.maxX
        #expect(leftmostButton.minX >= notchRightEdge + NotchSupport.trailingWingWidth,
                "刘海右翼展开时会盖住这一排")
    }

    /// **卡片排在按钮那一行的正下方，右边缘对齐到同一列。**
    ///
    /// 卡片的命中矩形是从按钮那一行往下推出来的（`agentStripRowSpacing`），而视图里
    /// 那个 `VStack(spacing:)` 必须用同一个数 —— 两边各写一个数字的话，改了一边就会
    /// 「画在这、点在那」，而屏幕上完全看不出来。
    @Test func agentCardSitsDirectlyUnderTheButtonRow() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let panelFrame = NotchSupport.agentStripPanelFrame(on: screen)
        let firstButton = try #require(NotchSupport.agentButtonFrame(on: screen,
                                                                    indexFromTrailingEdge: 0))
        let cardFrame = try #require(NotchSupport.agentCardFrame(on: screen))

        #expect(abs(cardFrame.maxY - (firstButton.minY - NotchSupport.agentStripRowSpacing)) < 0.5)
        #expect(abs(cardFrame.minX - panelFrame.minX) < 0.5)
        #expect(abs(cardFrame.maxX - panelFrame.maxX) < 0.5)
        #expect(cardFrame.height == NotchSupport.agentCardHitHeight)
    }

    /// **收起态的刘海窗口仍然左右对称地居中在刘海上。**
    ///
    /// 这条不变量 2026-09-26 破过一次：当时为了让那一排 agent 按钮住在窗口左半边，
    /// 左侧外扩改成了 `restingLeadingFlankWidth`（212pt）、右侧只有 150pt，于是窗口中心
    /// 比刘海中心偏左 31pt，胶囊跟着偏出去、露在硬件缺口左边。那一排现在有自己的面板了，
    /// 两侧都回到 `activeFlankWidth` —— 这条断言把"对称"钉住，以后谁再想单边加宽就会红。
    @Test func restingWindowStaysCenteredOnTheNotch() throws {
        guard let screen = NSScreen.main, NotchSupport.hasNotch(screen) else { return }
        let notchCenterX = try #require(NotchSupport.notchRect(on: screen)).midX + screen.frame.minX
        let windowFrame = try #require(NotchSupport.restingWindowFrame(on: screen))
        #expect(abs((windowFrame.minX + windowFrame.width / 2) - notchCenterX) < 0.5)
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
