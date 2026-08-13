import AnypaintKit

/// ScrollBottomLogic：滾輪方向 + 到底探測狀態機（bottomTick 的純核心,regression 熱點）。
nonisolated func scrollBottomLogicTests() {
    // wheelDirection
    T.checkEq("wheelDir: <0→下捲+1", ScrollBottomLogic.wheelDirection(deltaY: -5), 1)
    T.checkEq("wheelDir: >0→上捲-1", ScrollBottomLogic.wheelDirection(deltaY: 5), -1)
    T.checkTrue("wheelDir: 0→nil（維持前值）", ScrollBottomLogic.wheelDirection(deltaY: 0) == nil)

    // bottomTickDecision
    func dec(stalled: Bool = false, framesStalled: Bool = true, wheel: Int = 1, probe: Int = 0,
             doubt: Bool = false, back: Bool = false)
        -> (ScrollBottomLogic.BottomTickResult, Int, Bool) {
        let r = ScrollBottomLogic.bottomTickDecision(stalledTooLong: stalled, framesStalled: framesStalled,
            wheelTicks: wheel, probeCount: probe, hasQualityDoubt: doubt, backscrollRequested: back)
        return (r.result, r.probeCount, r.backscrollRequested)
    }
    // 停滯過久→finish（不論其他）
    T.checkEq("bottom: 停滯過久→finish", dec(stalled: true).0, .finish)
    // 沒滾輪→wait（且 framesStalled 時 probeCount 不動）
    T.checkEq("bottom: 沒滾輪→wait", dec(wheel: 0, probe: 2).0, .wait)
    T.checkEq("bottom: 沒滾輪 framesStalled probe 不變", dec(wheel: 0, probe: 2).1, 2)
    // 影格還在流→wait 且 probeCount 歸零（沒到底）
    T.checkEq("bottom: 影格還在流→wait", dec(framesStalled: false, probe: 2).0, .wait)
    T.checkEq("bottom: 影格還在流→probe 歸零", dec(framesStalled: false, probe: 2).1, 0)
    // 探測累計但未達 3→probe
    T.checkEq("bottom: probe 1→probe", dec(probe: 0).0, .probe)
    T.checkEq("bottom: probe++", dec(probe: 0).1, 1)
    T.checkEq("bottom: probe 2→仍 probe", dec(probe: 1).0, .probe)
    // 達門檻(3)、無疑慮→finish
    T.checkEq("bottom: probe 達 3 無疑慮→finish", dec(probe: 2).0, .finish)
    // 達門檻、有疑慮、未請求過→requestBackscroll（重置 probe、設旗標）
    let rb = dec(probe: 2, doubt: true)
    T.checkEq("bottom: 有疑慮→requestBackscroll", rb.0, .requestBackscroll)
    T.checkEq("bottom: requestBackscroll 重置 probe", rb.1, 0)
    T.checkTrue("bottom: requestBackscroll 設旗標", rb.2)
    // 有疑慮但已請求過→finish（一次性）
    T.checkEq("bottom: 疑慮已請求過→finish", dec(probe: 2, doubt: true, back: true).0, .finish)
}
