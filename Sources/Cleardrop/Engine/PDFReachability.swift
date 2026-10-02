import Foundation

/// Which objects the document still uses.
enum PDFReachability {
    /// Object numbers reachable from the trailer by following indirect references.
    static func reachableObjects(in graph: PDFDocumentGraph) -> Set<Int> {
        var reached = Set<Int>()
        // Explicit worklist: the graph can be deep and wide, and recursion would follow it.
        var pending: [PDFValue] = []
        for (key, value) in graph.trailer where key != "Prev" && key != "XRefStm" {
            pending.append(value)
        }
        while let value = pending.popLast() {
            switch value {
            case .ref(let ref):
                guard reached.insert(ref.obj).inserted,
                      let target = graph.objects[ref.obj]
                else { continue }
                pending.append(target.value)
            case .array(let items):
                pending.append(contentsOf: items)
            case .dict(let dict), .stream(let dict, _):
                pending.append(contentsOf: dict.values)
            default:
                break
            }
        }
        return reached
    }

    /// Drop every object nothing references. After the stripper has detached metadata, this
    /// is what actually removes it from the file: the writer emits whatever is in the map.
    static func sweep(_ graph: inout PDFDocumentGraph) {
        let reached = reachableObjects(in: graph)
        graph.objects = graph.objects.filter { reached.contains($0.key) }
    }
}
