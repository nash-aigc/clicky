//
//  MascotAvatar.swift
//  Wanna
//
//  会话头像的配色规则：每个会话按 id 稳定地领一块粉彩底，会话列表的头像盘
//  因此各有其色；主页 hero 固定用第三块粉彩（薄荷绿那块）。
//
//  形象素材本身已从仓库移除 —— 来源不属于本项目。`image(named:)` 缺文件时
//  返回 nil，调用方留空即可，界面因此退化成单纯的粉彩圆盘；这条路径本来就
//  是这个设计（「头像缺一张脸不值得让界面报错」）。
//

import AppKit
import SwiftUI

struct MascotIdentity {
    let imageName: String
    /// 头像盘的粉彩底色——固定的那块粉彩色板（#D7E5FF / #E4DDFF /
    /// #D3F2E0 / #FFEEC8），每只角色配一块。
    let pastelBackground: NSColor
}

enum MascotRoster {

    static let allIdentities: [MascotIdentity] = [
        MascotIdentity(imageName: "mascot-blue", pastelBackground: NSColor(red: 0.843, green: 0.898, blue: 1.000, alpha: 1)),
        MascotIdentity(imageName: "mascot-coral", pastelBackground: NSColor(red: 0.894, green: 0.867, blue: 1.000, alpha: 1)),
        MascotIdentity(imageName: "mascot-mint", pastelBackground: NSColor(red: 0.827, green: 0.949, blue: 0.878, alpha: 1)),
        MascotIdentity(imageName: "mascot-honey", pastelBackground: NSColor(red: 1.000, green: 0.933, blue: 0.784, alpha: 1)),
    ]

    /// 主页 hero 固定角色——用户截图里坐在胶囊上的就是绿色的这只。
    static let homeHero = allIdentities[2]

    /// 按会话 id 的首字节高两位稳定选角：同一个会话永远同一只脸。
    static func identity(forSessionID sessionID: UUID) -> MascotIdentity {
        let firstByte = withUnsafeBytes(of: sessionID.uuid) { $0[0] }
        return allIdentities[Int(firstByte >> 6) % allIdentities.count]
    }

    private static var imageCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    /// 散装资源加载。缺文件返回 nil，调用方留空即可——头像缺一张脸
    /// 不值得让界面报错。
    static func image(named imageName: String) -> NSImage? {
        cacheLock.lock()
        if let cached = imageCache[imageName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let url = Bundle.main.url(forResource: imageName, withExtension: "png"),
              let loaded = NSImage(contentsOf: url) else {
            return nil
        }
        cacheLock.lock()
        imageCache[imageName] = loaded
        cacheLock.unlock()
        return loaded
    }
}

// MARK: - 头像盘

/// 会话列表行的圆形头像：粉彩底 + 角色上半身（顶部对齐的裁切正好框住
/// 脸——素材是全身像，居中裁会把头切掉）。
///
/// 布局尺寸必须只由底盘决定：图片放在 overlay 里（overlay 永远不参与
/// 布局），整块再 clipShape 兜底。不能让 Image 自己 `.frame` + `clipped`
/// ——顶栏把它放进 `Menu` 的 label，macOS 的 Menu 对 label 提议不设上限
/// （实测 2026-09-22：图按素材原始 256pt 炸开，把整条顶栏撑到 255pt 高，
/// 就是用户反复报的「右侧的小人删不掉」）。
struct MascotAvatarDisc: View {

    let identity: MascotIdentity
    var diameter: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Color(identity.pastelBackground))
            .overlay {
                if let nsImage = MascotRoster.image(named: identity.imageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        // 脚底沉进圆盘一点，才是「站在盘里」而不是「贴在盘上」
                        .offset(y: diameter * 0.08)
                }
            }
            .clipShape(Circle())
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - 主页 hero：坐在语音胶囊上的吉祥物

/// 主页的标志构图：一只大号角色带着淡淡
/// 的绿辉光坐在**亮面蓝白胶囊**上，胶囊里是深藏青的麦克风和提示文字
/// （"Hi, how can I help ^_^?"）。角色保留非常轻的上下浮动。
struct HomeHeroMascotPill: View {

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let bobOffset = Self.bobOffset(at: timeline.date)

            ZStack(alignment: .bottom) {
                if let nsImage = MascotRoster.image(named: MascotRoster.homeHero.imageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 118)
                        .offset(y: bobOffset)
                        // 脚踩进胶囊上沿一点，才是「坐」而不是「悬」
                        .offset(y: 22)
                        // 角色自带的一圈绿色辉光
                        .shadow(color: Color(red: 0.45, green: 0.85, blue: 0.55).opacity(0.35), radius: 14)
                }

                voicePill
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    /// 语音胶囊：白→浅蓝渐变底 + 亮蓝描边，内容是深藏青，整体发亮。
    private var voicePill: some View {
        let deepNavy = Color(red: 0.10, green: 0.24, blue: 0.60)
        let brightBlue = Color(red: 0.30, green: 0.50, blue: 0.98)

        return HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(deepNavy)

            Text("按住 ⌃⌥，我能帮你做点什么？")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(deepNavy)
        }
        .padding(.horizontal, 22)
        .frame(height: 48)
        .frame(maxWidth: 360)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.80, green: 0.88, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(brightBlue, lineWidth: 2)
        )
        .shadow(color: brightBlue.opacity(0.35), radius: 10, y: 2)
    }

    /// ±2pt 的正弦浮动，周期约 4 秒。
    private static func bobOffset(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate * 1.6
        return CGFloat(sin(phase) * 2.0)
    }
}
