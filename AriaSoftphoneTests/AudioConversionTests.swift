import XCTest
import AVFoundation
@testable import AriaSoftphone

final class AudioConversionTests: XCTestCase {

    /// 48 kHz float mic audio down to 8 kHz Int16, as the capture path does.
    func testDownsamplesMicAudioToCodecRate() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))

        var produced = 0
        // Ten 20 ms buffers of a 440 Hz tone, streamed through one converter.
        var phase = 0.0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 960))
            buffer.frameLength = 960
            for i in 0..<960 {
                buffer.floatChannelData![0][i] = Float(sin(phase) * 0.5)
                phase += 2 * .pi * 440 / 48_000
            }
            let converted = try XCTUnwrap(iOSAudioBridge.convert(buffer, using: converter))
            XCTAssertEqual(converted.format.sampleRate, 8_000)
            produced += Int(converted.frameLength)
        }

        // 200 ms at 8 kHz, less what the filter is still holding.
        XCTAssertGreaterThan(produced, 1_500)
        XCTAssertLessThanOrEqual(produced, 1_600)
    }

    /// A tone above the 8 kHz Nyquist must not alias back into the band.
    func testFiltersContentAboveTheTargetNyquist() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for i in 0..<4_800 {
            // 7 kHz: decimating by picking every 6th sample aliases it to 1 kHz.
            buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 7_000 * Double(i) / 48_000) * 0.5)
        }
        let converted = try XCTUnwrap(iOSAudioBridge.convert(buffer, using: converter))
        let samples = UnsafeBufferPointer(start: converted.int16ChannelData![0], count: Int(converted.frameLength))
        // Skip the filter's start-up transient.
        let peak = samples.dropFirst(100).map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThan(peak, 1_000, "7 kHz leaked through at \(peak)")
    }

    func testPlaybackUpsamplesCodecAudio() throws {
        let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))

        var produced = 0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 160))
            buffer.frameLength = 160
            let converted = try XCTUnwrap(iOSAudioBridge.convert(buffer, using: converter))
            produced += Int(converted.frameLength)
        }
        XCTAssertGreaterThan(produced, 9_000)
        XCTAssertLessThanOrEqual(produced, 9_600)
    }
}
