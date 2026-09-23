//
//  BuddyAudioConversionSupport.swift
//  leanring-buddy
//
//  Shared audio conversion helpers for voice transcription providers.
//

import AVFoundation
import Foundation

final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat

    /// Converter for the incoming tap format, cached across callbacks.
    private var inputAudioConverter: AVAudioConverter?
    private var cachedInputFormatDescription: String?

    /// Latched per input format once its converter has been caught returning
    /// silence. See `convertToPCM16Data` for why this exists.
    private var inputFormatNeedsMonoCollapse = false

    /// Everything needed by the manual collapse, which converts from a
    /// DIFFERENT format than the tap's and therefore keeps its own cache. All of
    /// it is discarded together whenever the tap format changes.
    private var monoAudioConverter: AVAudioConverter?
    private var monoCollapseFormat: AVAudioFormat?
    private var monoCollapseBuffer: AVAudioPCMBuffer?

    init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    /// Converts one tap buffer to PCM16 mono at the target sample rate.
    ///
    /// `AVAudioConverter` is asked first and trusted — but its answer is
    /// checked, because it can return **digital silence for an input that
    /// carries speech, and report success while doing it**. The voice-processing
    /// input node (VPIO, enabled on the shared playback engine) reports a
    /// 9-channel format whose channels all carry the same mono signal, and the
    /// converter cannot map that layout. Measured 2026-09-23 by feeding one
    /// known-good clip through both paths in the authentic VPIO format:
    ///
    ///     AVAudioConverter downsamples 9ch → 1ch      rms 0.00000
    ///       → the ASR transcribed the silence as "嗯。"
    ///     collapse to mono by hand, then convert      rms 0.14850
    ///       → the ASR transcribed "你好，我是赵金麦，今天天气不错。"
    ///
    /// The cost of that silence was the whole feature: the energy VAD reads raw
    /// float samples and fired correctly, so the assistant stopped talking on
    /// cue — while the recognizer was fed zeros, so the user's follow-up was
    /// never transcribed, never passed the minimum-length check, and never sent.
    ///
    /// The failure is specific to the 9-channel VPIO layout, not to
    /// multi-channel input as such: push-to-talk taps a 3-channel device format
    /// that the same converter handles correctly today. So the collapse is a
    /// FALLBACK rather than unconditional — a format that already works keeps
    /// taking the path it takes now, byte for byte — and the verdict is latched
    /// (`inputFormatNeedsMonoCollapse`) so the doomed conversion is paid once
    /// per format instead of on every buffer.
    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        refreshInputConverterIfNeeded(for: audioBuffer)

        if inputFormatNeedsMonoCollapse {
            return convertCollapsingToMono(audioBuffer)
        }

        guard let inputAudioConverter else { return nil }
        let convertedData = runConversion(inputAudioConverter, from: audioBuffer)

        if let convertedData,
           !convertedData.isEmpty,
           !(containsOnlyZeroSamples(convertedData) && containsAnyNonZeroSample(audioBuffer)) {
            return convertedData
        }

        // The converter either produced nothing, or produced silence from a
        // buffer that carries signal. Try the manual collapse, and latch the
        // verdict so this format never pays for the doomed conversion again.
        guard audioBuffer.format.channelCount > 1,
              audioBuffer.format.commonFormat == .pcmFormatFloat32,
              let collapsedData = convertCollapsingToMono(audioBuffer) else {
            return convertedData
        }

        inputFormatNeedsMonoCollapse = true
        return collapsedData
    }

    /// Rebuilds the input converter when the tap format changes, and drops the
    /// collapse machinery with it — the mono buffer's sample rate is derived
    /// from the tap format, so both are stale together.
    private func refreshInputConverterIfNeeded(for audioBuffer: AVAudioPCMBuffer) {
        let inputFormatDescription = audioBuffer.format.settings.description
        guard cachedInputFormatDescription != inputFormatDescription else { return }

        inputAudioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
        cachedInputFormatDescription = inputFormatDescription
        inputFormatNeedsMonoCollapse = false

        monoAudioConverter = nil
        monoCollapseFormat = nil
        monoCollapseBuffer = nil
    }

    /// Collapses `audioBuffer` to mono first, then runs the ordinary conversion.
    private func convertCollapsingToMono(_ audioBuffer: AVAudioPCMBuffer) -> Data? {
        guard let monoBuffer = collapseToMonoBuffer(from: audioBuffer) else { return nil }

        if monoAudioConverter == nil {
            monoAudioConverter = AVAudioConverter(from: monoBuffer.format, to: targetAudioFormat)
        }
        guard let monoAudioConverter else { return nil }

        return runConversion(monoAudioConverter, from: monoBuffer)
    }

    /// Runs `converter` over one buffer, returning the PCM16 bytes it produced.
    private func runConversion(_ converter: AVAudioConverter, from sourceBuffer: AVAudioPCMBuffer) -> Data? {
        let sampleRateRatio = targetAudioFormat.sampleRate / sourceBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(sourceBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionStatus != .error,
              let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }

    /// True when the PCM16 payload is digital silence. A real conversion of a
    /// buffer that carries signal never produces this, so it is the one
    /// signature of the failure above that can be checked without guessing.
    private func containsOnlyZeroSamples(_ pcm16Data: Data) -> Bool {
        for byte in pcm16Data where byte != 0 { return false }
        return true
    }

    /// True when the tap buffer carries any non-zero sample at all — the other
    /// half of that signature, so a genuinely quiet room is not mistaken for a
    /// broken converter.
    private func containsAnyNonZeroSample(_ audioBuffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = audioBuffer.floatChannelData else { return false }

        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioBuffer.format.channelCount)

        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount where samples[frameIndex] != 0 {
                return true
            }
        }
        return false
    }

    /// Averages every channel of `audioBuffer` into a reused mono float buffer.
    ///
    /// Averaging rather than picking channel 0 because the two are identical for
    /// VPIO's replicated channels (measured: all 9 peak at the same RMS to five
    /// decimals) while averaging stays correct for a genuinely stereo input,
    /// where the voice is spread across channels. `monoCollapseFormat` keys on
    /// the sample rate, since the channel layout is irrelevant once collapsed.
    private func collapseToMonoBuffer(from audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let monoFormat: AVAudioFormat
        if let existingFormat = monoCollapseFormat,
           existingFormat.sampleRate == audioBuffer.format.sampleRate {
            monoFormat = existingFormat
        } else {
            guard let createdFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioBuffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return nil
            }
            monoCollapseFormat = createdFormat
            monoCollapseBuffer = nil
            monoAudioConverter = nil
            monoFormat = createdFormat
        }

        if let existingBuffer = monoCollapseBuffer,
           existingBuffer.frameCapacity >= audioBuffer.frameLength {
            // Reuse as-is.
        } else if let allocatedBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: audioBuffer.frameCapacity
        ) {
            monoCollapseBuffer = allocatedBuffer
        } else {
            return nil
        }

        guard let monoBuffer = monoCollapseBuffer,
              let sourceChannels = audioBuffer.floatChannelData,
              let destinationChannel = monoBuffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioBuffer.format.channelCount)
        let channelCountAsFloat = Float(channelCount)

        for frameIndex in 0..<frameCount {
            var channelSum: Float = 0
            for channelIndex in 0..<channelCount {
                channelSum += sourceChannels[channelIndex][frameIndex]
            }
            destinationChannel[0][frameIndex] = channelSum / channelCountAsFloat
        }

        monoBuffer.frameLength = audioBuffer.frameLength
        return monoBuffer
    }
}

enum BuddyWAVFileBuilder {
    static func buildWAVData(
        fromPCM16MonoAudio pcm16AudioData: Data,
        sampleRate: Int,
        channelCount: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataChunkSize = UInt32(pcm16AudioData.count)
        let fileSize = UInt32(36) + dataChunkSize

        var wavData = Data()

        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(littleEndianData(from: fileSize))
        wavData.append("WAVE".data(using: .ascii)!)
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(littleEndianData(from: UInt32(16)))
        wavData.append(littleEndianData(from: UInt16(1)))
        wavData.append(littleEndianData(from: UInt16(channelCount)))
        wavData.append(littleEndianData(from: UInt32(sampleRate)))
        wavData.append(littleEndianData(from: UInt32(byteRate)))
        wavData.append(littleEndianData(from: UInt16(blockAlign)))
        wavData.append(littleEndianData(from: UInt16(bitsPerSample)))
        wavData.append("data".data(using: .ascii)!)
        wavData.append(littleEndianData(from: dataChunkSize))
        wavData.append(pcm16AudioData)

        return wavData
    }

    private static func littleEndianData<T: FixedWidthInteger>(from value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
