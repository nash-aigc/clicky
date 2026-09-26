//
//  WorkspaceDirectory.swift
//  Wanna
//
//  The one place that knows where this checkout lives on disk, and the one place
//  that knows what the app's four human-visible output folders are called.
//
//  These paths used to be built at each call site, and every one of them pointed
//  at a `~/Desktop/…` folder of its own. On 2026-09-26 the user moved those
//  folders into the checkout and renamed them `Wanna…`, and asked for the paths
//  to follow — the old literals would otherwise keep writing into folders that
//  are no longer there, and the app would silently start from empty data instead
//  of failing loudly.
//  Same lesson as `AppSupportDirectory`: a rename that misses one site is a
//  rename that leaves one store reading the old directory.
//
//  The root is derived from `#filePath` — this file's own absolute path at compile
//  time — rather than written as a literal. A literal is what broke here: the checkout
//  was renamed on 2026-09-26 and every path built from it kept pointing at a folder that
//  no longer existed, silently, because a missing output directory is not an error the
//  app can notice. `#filePath` follows the sources, so moving or renaming the checkout is
//  a rebuild and nothing else.
//
//  It has to be compile-time, not runtime: the app runs from `/Applications`, from
//  DerivedData, or from a `swiftc` probe directory, and none of those bears any relation
//  to where the sources are, so nothing at runtime can walk its way back to the checkout.
//

import Foundation

nonisolated enum WorkspaceDirectory {

    /// The checkout. `<checkout>/Wanna/WorkspaceDirectory.swift` is this file, so two
    /// levels up from it is the root — and it stays right when the checkout moves.
    static var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Wanna/
            .deletingLastPathComponent()   // the checkout root
    }

    static var rootPath: String { rootURL.path }

    /// A folder directly inside the checkout.
    static func url(_ name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    /// 录音、转写和诊断日志。用户在访达里要能找到、能拖走 —— 所以不放
    /// `Application Support` 那个隐藏目录。
    static var recordingsURL: URL { url("Wanna录音") }

    /// 图形讲解产出的 `.geom` / `.svg`；也是图形 agent 唯一的可写区。
    static var figuresURL: URL { url("Wanna图形") }

    /// 复盘报告落在这里。
    static var reviewsURL: URL { url("Wanna复盘") }

    /// 后台 agent 的默认项目根 —— 每个 agent 一个子目录。
    static var agentsURL: URL { url("WannaAgents") }
}
