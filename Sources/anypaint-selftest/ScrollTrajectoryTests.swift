import AnypaintKit

/// ScrollTrajectory 全 7 個純方法的直接單元測試。此型別先前零直測（只由 engine 端到端間接跑到），
/// 這裡把它的每條不變式釘死——尤其 `commit` 的「餘額保留」與 `mustCommitNow` 的「再等一格會不會爆」，
/// 兩者都是實機自檢付代價換來的 regression（44% 內容遺失、達成率卡 83%）。
nonisolated func scrollTrajectoryTests() {
    // init：全部歸零/nil
    let t0 = ScrollTrajectory()
    T.checkEq("traj init: pendingDy=0", t0.pendingDy, 0)
    T.checkEq("traj init: totalTracked=0", t0.totalTracked, 0)
    T.checkEq("traj init: totalCommitted=0", t0.totalCommitted, 0)
    T.checkEq("traj init: assumedRun=0", t0.assumedRun, 0)
    T.checkTrue("traj init: lastStep=nil", t0.lastStep == nil)

    // recordStep：累積 pendingDy/totalTracked、lastStep=dy、assumedRun 歸零
    var t = ScrollTrajectory()
    t.recordStep(10)
    t.recordStep(6)
    T.checkEq("traj recordStep: pendingDy 累積", t.pendingDy, 16)
    T.checkEq("traj recordStep: totalTracked 累積", t.totalTracked, 16)
    T.checkEq("traj recordStep: lastStep=最後一次", t.lastStep, 6)

    // recordAssumedStep：有速度基準時 pendingDy+=lastStep、lastStep 不變、assumedRun++
    var ta = ScrollTrajectory()
    ta.recordStep(20)              // lastStep=20, pending=20, assumedRun=0
    let ok1 = ta.recordAssumedStep(maxConsecutive: 2)
    T.checkTrue("traj assumed: 有基準→true", ok1)
    T.checkEq("traj assumed: pendingDy+=lastStep", ta.pendingDy, 40)
    T.checkEq("traj assumed: lastStep 不變（基準仍來自真匹配）", ta.lastStep, 20)
    T.checkEq("traj assumed: assumedRun++", ta.assumedRun, 1)
    let ok2 = ta.recordAssumedStep(maxConsecutive: 2)
    T.checkTrue("traj assumed: 第 2 次仍在上限內→true", ok2)
    let ok3 = ta.recordAssumedStep(maxConsecutive: 2)
    T.checkTrue("traj assumed: 達連續上限→false（停止盲推）", !ok3)
    T.checkEq("traj assumed: 上限後 pendingDy 不再增", ta.pendingDy, 60)
    // recordStep 之後 assumedRun 重置，可再盲推
    ta.recordStep(5)
    T.checkEq("traj assumed: recordStep 後 assumedRun 歸零", ta.assumedRun, 0)
    // 無速度基準（開場）→ false
    var tb = ScrollTrajectory()
    T.checkTrue("traj assumed: 開場無 lastStep→false", !tb.recordAssumedStep(maxConsecutive: 3))
    // lastStep=0 → false（不盲推靜止）
    tb.recordStep(0)
    T.checkTrue("traj assumed: lastStep=0→false", !tb.recordAssumedStep(maxConsecutive: 3))

    // commit：餘額 < minTrustworthy → 當 drift 清掉；≥ → 保留（44% 遺失 regression）
    var tc = ScrollTrajectory()
    tc.recordStep(180)                       // pending=180
    tc.commit(actualDy: 178, minTrustworthy: 14)   // 餘額 2 < 14 → 清掉（吸收 drift）
    T.checkEq("traj commit: 小餘額當 drift 清零", tc.pendingDy, 0)
    T.checkEq("traj commit: totalCommitted 累加", tc.totalCommitted, 178)
    var td = ScrollTrajectory()
    td.recordStep(180)                       // pending=180（f2f 估對）
    td.commit(actualDy: 132, minTrustworthy: 14)   // 只接上 132，餘 48 ≥ 14 → 保留（不可歸零丟失）
    T.checkEq("traj commit: 大餘額保留給下一格（不丟內容）", td.pendingDy, 48)
    T.checkEq("traj commit: totalCommitted=實際接上量", td.totalCommitted, 132)
    // 負向裁尾也累加
    var tn = ScrollTrajectory()
    tn.recordStep(-30)
    tn.commit(actualDy: -30, minTrustworthy: 14)
    T.checkEq("traj commit: 負向 totalCommitted", tn.totalCommitted, -30)

    // resetToOrigin：pendingDy=0、lastStep=nil
    var tr = ScrollTrajectory()
    tr.recordStep(50)
    tr.resetToOrigin()
    T.checkEq("traj reset: pendingDy=0", tr.pendingDy, 0)
    T.checkTrue("traj reset: lastStep=nil", tr.lastStep == nil)

    // stepSearchWindow：nil lastStep→(0,0)；否則 (last, max(minRadius, |last|/2))
    let w0 = ScrollTrajectory().stepSearchWindow(minRadius: 12)
    T.checkEq("traj window: 無 lastStep center=0", w0.center, 0)
    T.checkEq("traj window: 無 lastStep radius=0（走全域小掃）", w0.radius, 0)
    var tw = ScrollTrajectory()
    tw.recordStep(8)
    let w1 = tw.stepSearchWindow(minRadius: 12)
    T.checkEq("traj window: center=lastStep", w1.center, 8)
    T.checkEq("traj window: 小步進用 minRadius 地板", w1.radius, 12)
    tw.recordStep(40)
    let w2 = tw.stepSearchWindow(minRadius: 12)
    T.checkEq("traj window: 大步進 radius=|last|/2", w2.radius, 20)

    // mustCommitNow：maxDy≤0→false；|pending|+|lastStep| ≥ maxDy（180/228 爆格 regression）
    T.checkTrue("traj mustCommit: maxDy≤0→false", !ScrollTrajectory().mustCommitNow(maxDy: 0))
    var tm = ScrollTrajectory()
    tm.recordStep(180)                       // pending=180, lastStep=180；再等一格→360 > 228
    T.checkTrue("traj mustCommit: 再等一格會爆→現在就接", tm.mustCommitNow(maxDy: 228))
    var tm2 = ScrollTrajectory()
    tm2.recordStep(20)                       // pending=20, lastStep=20；再等一格→40 < 228
    T.checkTrue("traj mustCommit: 還有餘裕→false", !tm2.mustCommitNow(maxDy: 228))
}
