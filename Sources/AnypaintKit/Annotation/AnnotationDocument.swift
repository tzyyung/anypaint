import Foundation
import CoreGraphics

/// 標註文件：物件集合＋選取狀態＋undo/redo。
/// - 陣列順序＝z-order（越後面越上層）。
/// - Undo 用 Memento 快照雙 stack：值型別之下「拍快照」＝複製陣列，
///   copy-on-write 讓實際記憶體增量≈當次變動的那一個物件。
/// - 所有修改都經過這裡；修改前自動 push 快照。拖曳/文字編輯這類連續操作
///   用 beginChange() 拍一次 + updateWithoutSnapshot() 連續改（整段＝一步 undo）。
public final class AnnotationDocument {
    public private(set) var objects: [Annotation] = []
    /// 目前選取的物件（UI 狀態，不進快照；undo/redo 後清除）。
    public var selectedID: UUID?

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    public init() {}

    public var isEmpty: Bool { objects.isEmpty }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func pushSnapshot() {
        undoStack.append(objects)
        redoStack.removeAll()
    }

    // MARK: 修改（都會自動拍快照）

    public func add(_ annotation: Annotation) {
        pushSnapshot()
        objects.append(annotation)
    }

    public func remove(id: UUID) {
        guard objects.contains(where: { $0.id == id }) else { return }
        pushSnapshot()
        objects.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    /// 單發修改（一次改動＝一步 undo）。
    public func update(id: UUID, _ transform: (inout Annotation) -> Void) {
        guard objects.contains(where: { $0.id == id }) else { return }
        pushSnapshot()
        updateWithoutSnapshot(id: id, transform)
    }

    /// 連續操作開始時呼叫一次（拍一次快照），之後用 updateWithoutSnapshot 連續改。
    public func beginChange() {
        pushSnapshot()
    }

    /// 不拍快照的修改；只能跟在 beginChange() 之後使用。
    public func updateWithoutSnapshot(id: UUID, _ transform: (inout Annotation) -> Void) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        transform(&objects[i])
    }

    // MARK: z-order（陣列搬移；已在目標位置就不拍快照）

    public func bringToFront(id: UUID) {
        guard let i = objects.firstIndex(where: { $0.id == id }), i != objects.count - 1 else { return }
        pushSnapshot()
        let a = objects.remove(at: i)
        objects.append(a)
    }

    public func sendToBack(id: UUID) {
        guard let i = objects.firstIndex(where: { $0.id == id }), i != 0 else { return }
        pushSnapshot()
        let a = objects.remove(at: i)
        objects.insert(a, at: 0)
    }

    // MARK: undo / redo

    public func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(objects)
        objects = last
        selectedID = nil
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(objects)
        objects = next
        selectedID = nil
    }

    // MARK: 查詢

    /// 點選命中：由上往下（陣列尾端優先）。
    public func hitTest(at point: CGPoint, threshold: CGFloat = 8) -> Annotation? {
        objects.reversed().first { $0.hitTest(point, threshold: threshold) }
    }

    /// 序號標記的編號＝「它是文件裡第幾個 counter」（1 起算）。
    /// 渲染時計算、不存死在物件裡 → 刪除/undo 後編號天然正確。
    public func counterNumber(for id: UUID) -> Int? {
        var n = 0
        for a in objects {
            if case .counter = a.shape {
                n += 1
                if a.id == id { return n }
            }
        }
        return nil
    }
}
