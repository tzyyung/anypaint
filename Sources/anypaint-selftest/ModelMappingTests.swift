import AnypaintKit

/// model 型別的純對應（displayName）＋ LumaPlane.cropped 幾何。
/// displayName 由 SelectionToolbar.colorName / ControlSettings.actionName 搬回 model 型別後可直測。
nonisolated func modelMappingTests() {
    // AnnotationColor.displayName：7 色全對
    T.checkEq("colorName: red", AnnotationColor.red.displayName, "紅色")
    T.checkEq("colorName: orange", AnnotationColor.orange.displayName, "橘色")
    T.checkEq("colorName: yellow", AnnotationColor.yellow.displayName, "黃色")
    T.checkEq("colorName: green", AnnotationColor.green.displayName, "綠色")
    T.checkEq("colorName: blue", AnnotationColor.blue.displayName, "藍色")
    T.checkEq("colorName: black", AnnotationColor.black.displayName, "黑色")
    T.checkEq("colorName: white", AnnotationColor.white.displayName, "白色")
    // 全案例都有非空名（CaseIterable 巡一遍，未來新增 case 忘了補會被抓到）
    T.checkTrue("colorName: 全 case 非空",
                AnnotationColor.allCases.allSatisfy { !$0.displayName.isEmpty })

    // OverlayAction.displayName：6 動作全對
    T.checkEq("actionName: reshoot", OverlayAction.reshoot.displayName, "重拍")
    T.checkEq("actionName: pickColor", OverlayAction.pickColor.displayName, "取色")
    T.checkEq("actionName: save", OverlayAction.save.displayName, "存檔")
    T.checkEq("actionName: saveAs", OverlayAction.saveAs.displayName, "另存為")
    T.checkEq("actionName: saveAndOpen", OverlayAction.saveAndOpen.displayName, "存檔並開啟")
    T.checkEq("actionName: recognizeText", OverlayAction.recognizeText.displayName, "辨識文字")
    T.checkTrue("actionName: 全 case 非空",
                OverlayAction.allCases.allSatisfy { !$0.displayName.isEmpty })

    // LumaPlane.cropped：4×4 遞增值,裁掉各 1 邊 → 2×2 中央區,尺寸與內容都對
    // v[r*4+c] = r*4+c（0..15）；cropped(top:1,bottom:1,left:1,right:1) → 取列1..2、欄1..2
    let src = LumaPlane(width: 4, height: 4, v: (0..<16).map { Float($0) })
    let c = src.cropped(top: 1, bottom: 1, left: 1, right: 1)
    T.checkEq("lumaCrop: 尺寸 2×2", [c.width, c.height], [2, 2])
    // 列1: [5,6]（原 v[5],v[6]）；列2: [9,10]
    T.checkEq("lumaCrop: 內容左上=v[5]", c.v[0], 5)
    T.checkEq("lumaCrop: 內容右上=v[6]", c.v[1], 6)
    T.checkEq("lumaCrop: 內容左下=v[9]", c.v[2], 9)
    T.checkEq("lumaCrop: 內容右下=v[10]", c.v[3], 10)
    // 非對稱裁切：只裁上 2 列 → 2×4
    let c2 = src.cropped(top: 2, bottom: 0, left: 0, right: 0)
    T.checkEq("lumaCrop: 非對稱 2×4", [c2.width, c2.height], [4, 2])
    T.checkEq("lumaCrop: 非對稱首值=v[8]", c2.v[0], 8)
}
