//
//  SpeechSpeedControl.swift
//  Wanna
//
//  「语速」那颗按钮与它点开的那一列档位 —— **一处定义，两页共用**。
//
//  用户 2026-09-26：「无论哪一种模式，文本、图文、语音、视频，输入框上方都应该有一个
//  "连续对话 / 临时对话 / 新建"的按钮，右侧都应该有一个"声音语速"的按钮」。
//  语速原先只长在语音页的页头里（还有它自己那套浮层定位），现在两页的输入框上方都要有它。
//
//  档位表**只在这里写一遍**：它和 `AppSettings.speechPlaybackRate` 是同一件事的两面
//  （1…10 档 ↔ 0.75…1.5 倍速），两处各写一份必然会漂 —— 而「说（播报）」那一页读的也是
//  同一个设置，所以档位错了是**三处同时错**，最难查。
//

import SwiftUI

/// 十档语速。档位 ↔ 倍率的换算只在这里。
nonisolated enum SpeechSpeedLevels {

    static let all: [(level: Int, rate: Double)] = {
        (1...10).map { level in
            (level, 0.75 + Double(level - 1) * (1.5 - 0.75) / 9)
        }
    }()

    /// 当前设置落在哪一档（最近的一档 —— 手改过 JSON 的值也能读出个档位）。
    static func currentLevel(forRate rate: Double) -> Int {
        all.min(by: { abs($0.rate - rate) < abs($1.rate - rate) })?.level ?? 5
    }

    static func rate(forLevel level: Int) -> Double {
        all.first(where: { $0.level == level })?.rate ?? 1.0
    }
}

/// 输入框那一行里的「语速」：两个字 + 当前档位，点开在它上面弹出十档。
///
/// 面板画在**上面**（`VStack` 里排在按钮之前），与语音页的浮层不同 —— 内容列底部没有
/// 空间往下弹，而往上弹不需要任何锚点测量：它就长在这一行自己的上方。
struct SpeechSpeedChip: View {

    /// 由调用方持有，这样面板与按钮的开关是同一份状态。
    @Binding var isPanelOpen: Bool

    var body: some View {
        let level = SpeechSpeedLevels.currentLevel(
            forRate: AppSettingsStore.snapshot().speechPlaybackRate)

        Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            isPanelOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.needle").font(.system(size: 10.5))
                Text("语速 \(level)").font(.system(size: 11.5))
                Image(systemName: isPanelOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(isPanelOpen ? DS.Colors.success : .white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isPanelOpen ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isPanelOpen ? DS.Colors.success.opacity(0.5)
                                              : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("十档语速，直接改全局「说（播报）」的语速")
    }

    /// 十档列表。选中那档打勾，点一下落到 `speechPlaybackRate` 并收起。
    static func panel(isPanelOpen: Binding<Bool>) -> some View {
        let current = SpeechSpeedLevels.currentLevel(
            forRate: AppSettingsStore.snapshot().speechPlaybackRate)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(SpeechSpeedLevels.all, id: \.level) { entry in
                Button {
                    var settings = AppSettingsStore.snapshot()
                    settings.speechPlaybackRate = entry.rate
                    try? AppSettingsStore.save(settings)
                    isPanelOpen.wrappedValue = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.level == current ? "checkmark" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(entry.level == current ? DS.Colors.success
                                                                   : .white.opacity(0.25))
                        Text("\(entry.level) 档")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Spacer(minLength: 8)
                        Text(String(format: "%.2f×", entry.rate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("把播报语速设为 \(entry.level) 档")
            }
        }
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}
