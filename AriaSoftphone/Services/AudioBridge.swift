import AVFoundation

/// Platform audio bridge for Aria mobile calls on iOS.
///
/// Routes decoded RTP audio to the speaker via AVAudioEngine output,
/// and captures microphone audio via AVAudioEngine input for sending.
///
/// CallKit owns the audio session. The bridge never sets the category or
/// activates the session: `CallManager` starts it from
/// `provider(_:didActivate:)` and stops it from `didDeactivate` and at the end
/// of every call. Audio the core delivers before then is dropped.
class iOSAudioBridge: PlatformAudioBridge {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    /// What the player node is connected with: float mono at the hardware rate.
    private var playbackFormat: AVAudioFormat?
    /// Codec-rate Int16 -> `playbackFormat`. Rebuilt if the codec rate changes.
    private var playbackConverter: AVAudioConverter?
    private let lock = NSLock()

    // Buffer for mic capture — filled by the input tap, drained by onCaptureAudio
    private var captureBuffer: [Int16] = []
    /// Microphone format -> Int16 mono at `captureSampleRate`.
    private var captureConverter: AVAudioConverter?
    /// The rate the core last asked for capture at. Until it asks, assume
    /// narrowband, which is what the old resampler assumed too.
    private var captureSampleRate: Double = 8000
    private let captureLock = NSLock()

    // MARK: - Lifecycle

    /// Start the audio engine. Call once CallKit has activated the session.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Echo cancellation and gain control: without them the far end hears
        // itself whenever the speaker is on.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("[AudioBridge] Voice processing unavailable: \(error)")
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[AudioBridge] No usable input format; is the session active?")
            return
        }

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareRate > 0 ? hardwareRate : inputFormat.sampleRate,
            channels: 1
        ) else { return }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        // ~20 ms per tap callback.
        let tapSize = AVAudioFrameCount(max(inputFormat.sampleRate / 50, 160))
        inputNode.installTap(onBus: 0, bufferSize: tapSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            inputNode.removeTap(onBus: 0)
            print("[AudioBridge] Failed to start: \(error)")
            return
        }

        audioEngine = engine
        playerNode = player
        playbackFormat = outputFormat
        playbackConverter = nil

        print("[AudioBridge] Started at \(outputFormat.sampleRate)Hz")
    }

    /// Stop the audio engine and drop any buffered audio. Safe to call when
    /// already stopped; called between calls so nothing carries over.
    func stop() {
        lock.lock()
        let wasRunning = audioEngine != nil
        playerNode?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        playbackFormat = nil
        playbackConverter = nil
        lock.unlock()

        captureLock.lock()
        captureBuffer.removeAll()
        captureConverter = nil
        captureLock.unlock()

        if wasRunning {
            print("[AudioBridge] Stopped")
        }
    }

    // MARK: - PlatformAudioBridge

    func onPlaybackAudio(samples: [Int16], sampleRate: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        guard !samples.isEmpty,
              let playerNode = playerNode,
              let audioEngine = audioEngine,
              let outputFormat = playbackFormat,
              audioEngine.isRunning,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: true
              ),
              let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channelData = source.int16ChannelData else { return }

        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }

        if playbackConverter?.inputFormat != sourceFormat {
            playbackConverter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        }
        guard let converter = playbackConverter,
              let converted = Self.convert(source, using: converter),
              converted.frameLength > 0 else { return }

        playerNode.scheduleBuffer(converted, completionHandler: nil)
    }

    func onCaptureAudio(sampleRate: UInt32, frameSize: UInt32) -> [Int16] {
        captureLock.lock()
        defer { captureLock.unlock() }

        let rate = Double(sampleRate)
        if rate > 0 && rate != captureSampleRate {
            // The codec changed: what is buffered is at the wrong rate.
            captureSampleRate = rate
            captureConverter = nil
            captureBuffer.removeAll()
        }

        let needed = Int(frameSize)
        if captureBuffer.count >= needed {
            let result = Array(captureBuffer.prefix(needed))
            captureBuffer.removeFirst(needed)
            return result
        }
        return []
    }

    // MARK: - Capture

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        captureLock.lock()
        defer { captureLock.unlock() }

        if captureConverter == nil
            || captureConverter?.inputFormat != buffer.format
            || captureConverter?.outputFormat.sampleRate != captureSampleRate {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: captureSampleRate,
                channels: 1,
                interleaved: true
            ) else { return }
            captureConverter = AVAudioConverter(from: buffer.format, to: target)
            captureConverter?.downmix = true
        }

        // A filtering sample-rate converter, in place of picking every Nth
        // sample: decimating 48 kHz to 8 kHz without a low-pass aliased
        // everything above 4 kHz back into the voice band.
        guard let converter = captureConverter,
              let converted = Self.convert(buffer, using: converter),
              let data = converted.int16ChannelData else { return }

        captureBuffer.append(
            contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))
        )
        // Keep buffer bounded (max ~500ms)
        let maxSamples = Int(captureSampleRate) / 2
        if captureBuffer.count > maxSamples {
            captureBuffer.removeFirst(captureBuffer.count - maxSamples)
        }
    }

    // MARK: - Conversion

    /// Run one buffer through a streaming converter.
    ///
    /// The input block reports `.noDataNow` after handing over the buffer,
    /// rather than end-of-stream, so the converter keeps its filter state
    /// between calls and consecutive buffers join without a seam.
    static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil else {
            print("[AudioBridge] Conversion failed: \(String(describing: error))")
            return nil
        }
        return output
    }
}
