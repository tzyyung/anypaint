import AnypaintKit

nonisolated func micHALRMSTests() {
    // 全 0.5 的訊號：RMS = 0.5
    let half = [Float](repeating: 0.5, count: 1024)
    let r1 = half.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkTrue("rms: 定值 0.5 → RMS≈0.5", abs(r1 - 0.5) < 1e-4)
    // 靜音 → 0
    let zero = [Float](repeating: 0, count: 512)
    let r2 = zero.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkEq("rms: 靜音 → 0", r2, 0)
    // 空輸入不 crash、回 0
    let r3 = [Float]().withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkEq("rms: 空輸入 → 0", r3, 0)
    // ±1 交替：RMS = 1
    let alt = (0..<1000).map { $0 % 2 == 0 ? Float(1) : Float(-1) }
    let r4 = alt.withUnsafeBufferPointer { RecordMath.rms($0) }
    T.checkTrue("rms: ±1 交替 → RMS≈1", abs(r4 - 1) < 1e-4)
}
