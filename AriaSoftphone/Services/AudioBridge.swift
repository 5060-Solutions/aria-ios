import AVFoundation

/// Platform audio bridge for Aria mobile calls on iOS.
///
/// Routes decoded RTP audio to the speaker via AVAudioEngine output,
/// and captures microphone audio via AVAudioEngine input for sending.
class iOSAudioBridge: PlatformAudioBridge {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isStarted = false
    private let lock = NSLock()

    // Buffer for mic capture — filled by the input tap, drained by onCaptureAudio
    private var captureBuffer: [Int16] = []
    private let captureLock = NSLock()

    func onPlaybackAudio(samples: [Int16], sampleRate: UInt32) {
        ensureStarted(sampleRate: Int(sampleRate))

        guard let playerNode = playerNode,
              let audioEngine = audioEngine,
              audioEngine.isRunning else { return }

        // Convert Int16 samples to AVAudioPCMBuffer
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.int16ChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func onCaptureAudio(sampleRate: UInt32, frameSize: UInt32) -> [Int16] {
        captureLock.lock()
        defer { captureLock.unlock() }

        let needed = Int(frameSize)
        if captureBuffer.count >= needed {
            let result = Array(captureBuffer.prefix(needed))
            captureBuffer.removeFirst(needed)
            return result
        }
        return []
    }

    private func ensureStarted(sampleRate: Int) {
        lock.lock()
        defer { lock.unlock() }

        if isStarted { return }
        isStarted = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(Double(sampleRate))
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

            // Install microphone tap
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(sampleRate / 50), format: inputFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer, inputSampleRate: inputFormat.sampleRate, targetSampleRate: Double(sampleRate))
            }

            try engine.start()
            player.play()

            self.audioEngine = engine
            self.playerNode = player

            print("[AudioBridge] Started at \(sampleRate)Hz")
        } catch {
            print("[AudioBridge] Failed to start: \(error)")
        }
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, inputSampleRate: Double, targetSampleRate: Double) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, floatData[0][i]))
            samples[i] = Int16(clamped * 32767)
        }

        // Simple resample if needed (input is typically 48kHz, we need 8kHz)
        if inputSampleRate != targetSampleRate {
            let ratio = inputSampleRate / targetSampleRate
            let newCount = Int(Double(samples.count) / ratio)
            var resampled = [Int16](repeating: 0, count: newCount)
            for i in 0..<newCount {
                let srcIdx = min(Int(Double(i) * ratio), samples.count - 1)
                resampled[i] = samples[srcIdx]
            }
            samples = resampled
        }

        captureLock.lock()
        captureBuffer.append(contentsOf: samples)
        // Keep buffer bounded (max ~500ms)
        let maxSamples = Int(targetSampleRate) / 2
        if captureBuffer.count > maxSamples {
            captureBuffer.removeFirst(captureBuffer.count - maxSamples)
        }
        captureLock.unlock()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        playerNode?.stop()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        playerNode = nil
        isStarted = false

        print("[AudioBridge] Stopped")
    }
}
