import Accelerate
import Foundation

/// Visual prototype: 24 logarithmic bands, 60 Hz ... min(16 kHz, Nyquist).
/// Called by the existing 10 Hz observation task, NEVER by the render callback.
nonisolated final class PlaybackSpectrumAnalyzer {
    static let frameCount = 2048
    static let bandCount = 24
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: frameCount)
    private var real = [Float](repeating: 0, count: frameCount / 2)
    private var imaginary = [Float](repeating: 0, count: frameCount / 2)

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.frameCount), Int32(vDSP_HANN_NORM))
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    func analyze(stereo: [Float], sampleRate: Double) -> (left: [Double], right: [Double]) {
        guard stereo.count == Self.frameCount * 2, sampleRate.isFinite, sampleRate > 120,
              let setup else { return ([], []) }
        func channel(_ channel: Int) -> [Double] {
            for index in 0..<Self.frameCount / 2 {
                real[index] = stereo[index * 4 + channel] * window[index * 2]
                imaginary[index] = stereo[index * 4 + 2 + channel] * window[index * 2 + 1]
            }
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                }
            }
            let upper = min(16_000, sampleRate / 2)
            return (0..<Self.bandCount).map { band in
                let low = 60 * pow(upper / 60, Double(band) / Double(Self.bandCount))
                let high = 60 * pow(upper / 60, Double(band + 1) / Double(Self.bandCount))
                let first = max(1, Int(ceil(low * Double(Self.frameCount) / sampleRate)))
                let end = min(Self.frameCount / 2, max(first + 1, Int(ceil(high * Double(Self.frameCount) / sampleRate))))
                var amplitude: Double = 0
                if first < end {
                    for bin in first..<end {
                        // Real FFT returns 2x coefficients; compensate Hann gain.
                        amplitude = max(amplitude, hypot(Double(real[bin]), Double(imaginary[bin])) * 2 / Double(Self.frameCount))
                    }
                }
                guard amplitude > 0 else { return 0 }
                return min(1, max(0, (20 * log10(amplitude) + 60) / 60))
            }
        }
        return (channel(0), channel(1))
    }
}
