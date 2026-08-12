import Foundation
import AnypaintKit

nonisolated func goertzelTests() {
    let sr = 48000.0
    let tone = (0..<48000).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) * 0.5 }
    let silence = [Float](repeating: 0, count: 48000)
    let noiseless440 = RecordMath.goertzelPower(samples: tone, sampleRate: sr, targetHz: 440)
    let off880 = RecordMath.goertzelPower(samples: tone, sampleRate: sr, targetHz: 880)
    T.checkTrue("goertzel: 440Hz 音在 440 檢測點能量高", noiseless440 > 0.01)
    T.checkTrue("goertzel: 440Hz 音在 880 檢測點能量低", off880 < noiseless440 / 100)
    T.checkTrue("goertzel: 靜音能量≈0",
                RecordMath.goertzelPower(samples: silence, sampleRate: sr, targetHz: 440) < 1e-9)
}
