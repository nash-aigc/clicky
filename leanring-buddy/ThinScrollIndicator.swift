//
//  ThinScrollIndicator.swift
//  leanring-buddy
//
//  把右列（对话 / Agent / 语音聊天）滚动时的滚动条换成**一条白色细线**。
//
//  用户 2026-09-24：「在右侧边滑动的时候，把这个滑动条改成一条细线，一条白色的
//  细线」。系统的覆盖式滚动条是灰胶囊、带轨道感，与面板的暗色风格不搭。
//
//  实现：SwiftUI 的 `ScrollView` 在 macOS 上背后就是一个 `NSScrollView` ——
//  挂一个空视图，`onAppear` 沿着视图树向上找到它，把滚动条设成 **overlay 样式
//  + 白色旋钮**（`scrollerKnobStyle = .light`）。那是 AppKit 的一等能力，
//  不需要 `onScrollGeometry`（那是 macOS 15 的 API，本 target 是 14.2）。
//

import AppKit
import SwiftUI

private struct ScrollbarTuner: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let probeView = NSView()
        // 布局发生在之后，所以等一拍再找 —— 找到的是包含本 ScrollView 的
        // 那一个 NSScrollView，不会误伤别的列。
        DispatchQueue.main.async {
            var current: NSView? = probeView.superview
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView {
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = true
                    scrollView.scrollerStyle = .overlay
                    // `.light` = 白色旋钮。overlay 样式本身就是一条细线。
                    scrollView.scrollerKnobStyle = .light
                    scrollView.verticalScroller?.knobProportion = 0.2
                    break
                }
                current = candidate.superview
            }
        }
        return probeView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ThinWhiteScrollIndicator: ViewModifier {

    func body(content: Content) -> some View {
        content
            .background(ScrollbarTuner())
    }
}

extension View {
    /// 右列滚动条 → 一条白色细线。见 `ScrollbarTuner`。
    func thinWhiteScrollIndicator() -> some View {
        modifier(ThinWhiteScrollIndicator())
    }
}
