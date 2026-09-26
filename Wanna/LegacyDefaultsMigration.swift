//
//  LegacyDefaultsMigration.swift
//  Wanna
//
//  把旧 bundle id 的 `UserDefaults` 搬进当前这个。
//
//  `UserDefaults` 是**按 bundle id 隔离**的。2026-09-26 改 bundle id
//  （`com.yourcompany.leanring-buddy` → `com.nash-aigc.wanna`）那天，整个域被换成了
//  空的：旧域 13 个键，新域 4 个。丢的不是无关紧要的东西 ——
//
//    · `hasScreenContentPermission`（一次性标记，批准过就不再问）
//        → `allPermissionsGranted` 永远 false → `installCompanionPresenceIfReady()`
//          永远早退 → 刘海面板永远不创建。而刘海是这个 app 唯一的入口（没有 dock
//          图标、没有菜单栏图标），所以现象是「进程在跑、日志全正常、屏幕上 0 个窗口」，
//          用户连设置页都进不去、没有任何办法把自己救回来。
//    · `*NotchSheetHeightFraction`（刘海展开高度）
//        → 退回默认值，面板高度变了。
//
//  那天我是用 `defaults` 命令手工迁的。手工的东西换台机器就没了 —— 所以这里补上，
//  让它在代码里、每次启动都幂等执行。
//
//  ## 只搬一次，且只搬新域里没有的键
//
//  新域里已经存在的键**一律不覆盖**：用户在新 bundle id 下改过的设置比旧域的新，
//  盖掉就是拿旧值覆盖用户的当前选择。
//

import Foundation

nonisolated enum LegacyDefaultsMigration {

    /// 这个 app 改名前的 bundle id。**只在这里出现** —— 它的唯一用途是找到那批
    /// 旧数据，别的任何地方都不该再依赖它。
    private static let legacyBundleIdentifier = "com.yourcompany.leanring-buddy"

    /// 键名在改 bundle id 前后一起被改过（`clicky*` → `wanna*`）。
    /// 迁移时要把旧名字映射到新名字，否则搬过来也没人读。
    private static let renamedPrefix = (legacy: "clicky", current: "wanna")

    /// 幂等：跑多少次结果都一样。新域里已经有值的键不碰。
    static func runIfNeeded() {
        guard let legacyDomain = UserDefaults(suiteName: legacyBundleIdentifier) else { return }
        let current = UserDefaults.standard

        var migratedKeys: [String] = []

        for key in legacyDomain.dictionaryRepresentation().keys {
            // 系统自己的键（NSGlobalDomain 那批、Apple* 前缀）不属于这个 app。
            guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), !key.hasPrefix("com.apple.") else { continue }

            let currentKey: String
            if key.hasPrefix(renamedPrefix.legacy) {
                currentKey = renamedPrefix.current + key.dropFirst(renamedPrefix.legacy.count)
            } else {
                currentKey = key
            }

            // 已经有值 = 用户在新 bundle id 下已经设置过，尊重它。
            guard current.object(forKey: currentKey) == nil else { continue }

            current.set(legacyDomain.object(forKey: key), forKey: currentKey)
            migratedKeys.append(currentKey)
        }

        if !migratedKeys.isEmpty {
            print("📦 Wanna: 从旧 bundle id 迁回 \(migratedKeys.count) 个 UserDefaults 键：\(migratedKeys.joined(separator: ", "))")
        }
    }
}
