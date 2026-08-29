/// Provider-neutral, mono, non-interleaved Float32 PCM audio.
nonisolated struct AudioFrame: Sendable {
    let samples: [Float]
    let sampleRate: Double
}
