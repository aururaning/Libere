import Foundation

public struct NotebookCell: Identifiable {
    public let id: String
    public let index: Int
    public let kind: String
    public let source: String
    public let executionCount: Int?
    public let outputs: [[String: Any]]
}

/// Keep all notebook/cell metadata and MIME representations, including unknown extension fields.
public struct NotebookDocument {
    private var object: [String: Any]
    private var runtimeCellIDs: [String]
    private var pendingClear: Set<Int> = []
    private var displays: [String: [(cell: Int, output: Int)]] = [:]
    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["nbformat"] as? Int == 4, root["cells"] is [[String: Any]] else { throw AttachmentFormat.PreviewError.notebook }
        object = root
        var used: Set<String> = []
        runtimeCellIDs = (root["cells"] as! [[String: Any]]).map { cell in
            if let id = cell["id"] as? String, !id.isEmpty, used.insert(id).inserted { return id }
            let id = UUID().uuidString.lowercased(); used.insert(id); return id
        }
    }
    public var kernelName: String? { (object["metadata"] as? [String: Any])?["kernelspec"].flatMap { ($0 as? [String: Any])?["name"] as? String } }
    private var rawCells: [[String: Any]] {
        get { object["cells"] as? [[String: Any]] ?? [] }
        set { object["cells"] = newValue }
    }
    public var cells: [NotebookCell] {
        rawCells.enumerated().map { i, cell in
            NotebookCell(id: runtimeCellIDs[i], index: i, kind: cell["cell_type"] as? String ?? "raw",
                         source: Self.text(cell["source"]), executionCount: cell["execution_count"] as? Int,
                         outputs: cell["outputs"] as? [[String: Any]] ?? [])
        }
    }
    public func index(ofCellID id: String) -> Int? { runtimeCellIDs.firstIndex(of: id) }
    public func serialized() throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) }
    public static func text(_ value: Any?) -> String { (value as? String) ?? (value as? [String])?.joined() ?? "" }
    public mutating func setSource(_ source: String, at index: Int) {
        var cells = rawCells; guard cells.indices.contains(index) else { return }
        cells[index]["source"] = source; rawCells = cells
    }
    public mutating func addCodeCell() {
        insertCell(at: rawCells.count, kind: "code")
    }
    /// Assign stable identities only when a structural edit is requested, keeping
    /// untouched legacy notebooks byte-structure compatible on ordinary load/save.
    private mutating func prepareStructure() {
        var cells = rawCells
        for i in cells.indices { cells[i]["id"] = runtimeCellIDs[i] }
        rawCells = cells
    }
    private mutating func remapExecutionState(from old: [[String: Any]]) {
        let newIndex = Dictionary(rawCells.enumerated().compactMap { i, cell in (cell["id"] as? String).map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        func target(_ i: Int) -> Int? { guard old.indices.contains(i), let id = old[i]["id"] as? String else { return nil }; return newIndex[id] }
        pendingClear = Set(pendingClear.compactMap(target))
        for key in Array(displays.keys) {
            displays[key] = displays[key]?.compactMap { location in target(location.cell).map { (cell: $0, output: location.output) } }
        }
    }
    public mutating func insertCell(at index: Int, kind: String = "code") {
        guard ["code", "markdown"].contains(kind) else { return }
        prepareStructure(); var cells = rawCells; let before = cells
        var cell: [String: Any] = ["id": UUID().uuidString.lowercased(), "cell_type": kind, "source": "", "metadata": [:]]
        if kind == "code" { cell["outputs"] = []; cell["execution_count"] = NSNull() }
        let destination = min(max(0, index), cells.count)
        runtimeCellIDs.insert(cell["id"] as! String, at: destination)
        cells.insert(cell, at: destination); rawCells = cells; remapExecutionState(from: before)
    }
    public mutating func removeCell(at index: Int) {
        guard rawCells.indices.contains(index) else { return }
        prepareStructure(); var cells = rawCells; let before = cells
        cells.remove(at: index); runtimeCellIDs.remove(at: index); rawCells = cells; remapExecutionState(from: before)
    }
    public mutating func moveCell(at index: Int, by delta: Int) {
        let (destination, overflow) = index.addingReportingOverflow(delta)
        guard !overflow, rawCells.indices.contains(index), rawCells.indices.contains(destination), delta != 0 else { return }
        prepareStructure(); var cells = rawCells; let before = cells; let cell = cells.remove(at: index)
        let identity = runtimeCellIDs.remove(at: index); runtimeCellIDs.insert(identity, at: destination)
        cells.insert(cell, at: destination); rawCells = cells; remapExecutionState(from: before)
    }
    public mutating func convertCell(at index: Int, to kind: String) {
        guard rawCells.indices.contains(index), ["code", "markdown"].contains(kind) else { return }
        prepareStructure(); var cells = rawCells; guard cells[index]["cell_type"] as? String != kind else { return }
        clear(index)
        cells[index]["cell_type"] = kind
        if kind == "code" { cells[index]["outputs"] = []; cells[index]["execution_count"] = NSNull() }
        else { cells[index].removeValue(forKey: "outputs"); cells[index].removeValue(forKey: "execution_count") }
        rawCells = cells
    }
    public mutating func clearOutputs(at index: Int? = nil) {
        let indices = index.map { [$0] } ?? Array(rawCells.indices)
        for i in indices where rawCells.indices.contains(i) && rawCells[i]["cell_type"] as? String == "code" {
            clear(i); var cells = rawCells; cells[i]["execution_count"] = NSNull(); rawCells = cells
        }
    }
    public mutating func beginExecution(at index: Int) {
        clear(index)
        var cells = rawCells; guard cells.indices.contains(index) else { return }
        cells[index]["execution_count"] = NSNull(); rawCells = cells
    }
    private mutating func clear(_ index: Int) {
        var cells = rawCells; guard cells.indices.contains(index) else { return }
        cells[index]["outputs"] = []; rawCells = cells; pendingClear.remove(index)
        for key in Array(displays.keys) { displays[key]?.removeAll { $0.cell == index } }
    }
    public mutating func apply(_ type: String, content: [String: Any], at index: Int) {
        guard rawCells.indices.contains(index) else { return }
        if type == "clear_output" {
            if content["wait"] as? Bool == true { pendingClear.insert(index) } else { clear(index) }
            return
        }
        if type == "execute_input" || type == "execute_reply" {
            if let count = content["execution_count"] as? Int {
                var cells = rawCells; cells[index]["execution_count"] = count; rawCells = cells
            }
            return
        }
        guard ["stream", "error", "execute_result", "display_data", "update_display_data"].contains(type) else { return }
        if pendingClear.contains(index) { clear(index) }
        if type == "update_display_data" {
            guard let displayID = (content["transient"] as? [String: Any])?["display_id"] as? String else { return }
            var cells = rawCells
            for location in displays[displayID] ?? [] {
                guard cells.indices.contains(location.cell), var outputs = cells[location.cell]["outputs"] as? [[String: Any]], outputs.indices.contains(location.output) else { continue }
                outputs[location.output]["data"] = content["data"] ?? [:]
                outputs[location.output]["metadata"] = content["metadata"] ?? [:]
                cells[location.cell]["outputs"] = outputs
            }
            rawCells = cells; return
        }
        var output = content; output["output_type"] = type
        let displayID = (output.removeValue(forKey: "transient") as? [String: Any])?["display_id"] as? String
        var cells = rawCells, outputs = cells[index]["outputs"] as? [[String: Any]] ?? []
        if type == "stream", let last = outputs.last, last["output_type"] as? String == "stream", last["name"] as? String == content["name"] as? String {
            outputs[outputs.count - 1]["text"] = Self.text(last["text"]) + Self.text(content["text"])
        } else {
            if let displayID { displays[displayID, default: []].append((index, outputs.count)) }
            outputs.append(output)
        }
        cells[index]["outputs"] = outputs; rawCells = cells
    }
}
