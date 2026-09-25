import Combine
import SwiftUI

/// 摄像头小窗要显示的东西，**单独一个 ObservableObject**。
///
/// ## 为什么要单独一个，而不是挂在 `LongFormRecorderController` 上
///
/// 那是这次「12 帧/秒还是很卡」的根因。`NotchRecordingBandView` 观察的是
/// `LongFormRecorderController`，所以**控制器上任何一个 `@Published` 变化，都会让整条
/// 刘海重新求值一次** —— 包括那块字幕跑马灯、左右两翼、以及所有子视图。
///
/// 预览是 12 帧/秒，也就是**每秒把整条刘海重建 12 次**。而且这些帧里绝大多数根本
/// 不会发给模型，纯粹是给眼睛看的。
///
/// 把预览单独放一个对象之后，12 帧/秒只让**那一小块视图**重算，刘海带完全不参与。
@MainActor
final class CameraPreviewModel: ObservableObject {
    /// 当前这一帧。用 `CGImage` 而不是 JPEG `Data` —— 预览不需要编码再解码。
    @Published private(set) var frame: CGImage?
    /// 已经抓了多少帧（送模型的那个计数）。绿点旁边那个数字。
    @Published private(set) var capturedFrameCount = 0

    /// 预览要不要左右镜像。**默认开**。
    ///
    /// 用户 2026-09-26：「先帮我把摄像头镜像一下，现在画面是反的，太丑了……
    /// 允许用户自行镜像，但默认要调整为镜像」。没镜像时你抬手是往右，画面里却往左 ——
    /// 自拍视角里那才叫「反的」。
    ///
    /// **只作用于预览，不作用于发给模型的帧。** 镜像会把文字翻过来，而用户会举着
    /// 纸让模型读 —— 那样读出来的字是反的。所以屏幕上是他习惯的自拍视角，
    /// 送出去的是文字可读的原始帧。
    @Published var isMirrored = true

    func update(frame: CGImage) {
        self.frame = frame
    }

    func update(capturedFrameCount: Int) {
        self.capturedFrameCount = capturedFrameCount
    }

    func reset() {
        frame = nil
        capturedFrameCount = 0
    }
}
