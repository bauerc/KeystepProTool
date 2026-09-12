// Regenerate swift/Sources/KSPKit/BulkPlan.swift from Arturia's device descriptor.

import Foundation

let vendor = URL(filePath: "/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json")
let target = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "swift/Sources/KSPKit/BulkPlan.swift")

/// Stands in for the enclosing multibulk index inside a dimension.
let idx = -1

struct Leaf {
    let item: Int
    let params: [Int]
    let dims: [[Int]]
    let count: Int?
}

struct Group {
    let low: Int
    let high: Int
    let leaves: [Leaf]
}

let head = """
    /// Which addresses to ask the device for, and in what order (spec 7).
    enum BulkPlan {
        /// Stands in for the enclosing multibulk index inside a dimension.
        static let idx = -1

        struct Leaf {
            let item: Int
            let params: [Int]
            let dims: [[Int]]
            /// nil is the index-less short form.
            let count: Int?

            init(_ item: Int, _ params: [Int], _ dims: [[Int]], _ count: Int?) {
                self.item = item
                self.params = params
                self.dims = dims
                self.count = count
            }
        }

        struct Group {
            let low: Int
            let high: Int
            let leaves: [Leaf]

            init(_ low: Int, _ high: Int, _ leaves: [Leaf]) {
                self.low = low
                self.high = high
                self.leaves = leaves
            }
        }

        static let plan: [Group] = [

    """

struct DescriptorError: Error, CustomStringConvertible {
    let description: String
}

func number(_ value: Any) throws -> Int {
    guard let number = value as? Int else {
        throw DescriptorError(description: "expected a number, found \(value)")
    }
    return number
}

func dimension(_ element: Any) throws -> [Int] {
    if element as? String == "IDX" {
        return [idx]
    }
    if let values = element as? [Any] {
        return try values.map { $0 as? String == "IDX" ? idx : try number($0) }
    }
    throw DescriptorError(description: "unexpected template element \(element)")
}

/// One `bulkItemId` list into `(item, dims, count)`.
func normalise(_ template: [Any]) throws -> (Int, [[Int]], Int) {
    guard let head = template.first as? [Any], let first = head.first else {
        throw DescriptorError(description: "template \(template) has no item")
    }
    var body = Array(template.dropFirst())
    var trailing: [Int] = []
    while let last = body.last, !(last is [Any]), !(last is String) {
        trailing.insert(try number(last), at: 0)
        body.removeLast()
    }
    var dims = try body.map(dimension)
    if trailing.count == 2 {
        dims.append([trailing[0]])
        return (try number(first), dims, trailing[1])
    }
    guard let count = trailing.first else {
        throw DescriptorError(description: "template \(template) has no count")
    }
    return (try number(first), dims, count)
}

func leaves(_ node: Any) -> [[String: Any]] {
    if let dictionary = node as? [String: Any] {
        var found: [[String: Any]] = []
        if dictionary["bulkParamIds"] != nil {
            found.append(dictionary)
        }
        if let multibulk = dictionary["multibulk"] {
            found += leaves(multibulk)
        }
        return found
    }
    if let list = node as? [Any] {
        return list.flatMap(leaves)
    }
    return []
}

func build(_ descriptor: [String: Any]) throws -> [Group] {
    guard let operations = descriptor["bulkOperation"] as? [[String: Any]] else {
        throw DescriptorError(description: "no bulkOperation in \(vendor.path)")
    }
    return try operations.map { entry in
        let range = try (entry["multibulk_idx"] as? [Any] ?? [0, 0]).map(number)
        let rows = try leaves(entry).map { leaf in
            let params = try (leaf["bulkParamIds"] as? [Any] ?? []).map(number)
            if let template = leaf["bulkItemId"] as? [Any] {
                let (item, dims, count) = try normalise(template)
                return Leaf(item: item, params: params, dims: dims, count: count)
            }
            return Leaf(
                item: try number(leaf["bulkItemId"] ?? ""), params: params, dims: [], count: nil)
        }
        return Group(low: range[0], high: range[1], leaves: rows)
    }
}

/// The request count MCC's walk expands the plan to, for the summary line.
func requestCount(_ plan: [Group]) -> Int {
    plan.reduce(0) { total, group in
        let perIndex = group.leaves.reduce(0) { sum, leaf in
            sum + leaf.params.count
                * (leaf.count == nil ? 1 : leaf.dims.reduce(1) { $0 * $1.count })
        }
        return total + perIndex * (group.high - group.low + 1)
    }
}

func list(_ values: [Int]) -> String {
    "[" + values.map { $0 == idx ? "idx" : String($0) }.joined(separator: ", ") + "]"
}

func render(_ plan: [Group]) -> String {
    var body = head
    for group in plan {
        body += "        Group(\n            \(group.low), \(group.high),\n            [\n"
        for leaf in group.leaves {
            let dims = "[" + leaf.dims.map(list).joined(separator: ", ") + "]"
            let count = leaf.count.map(String.init) ?? "nil"
            body += "                Leaf(\(leaf.item), \(list(leaf.params)), \(dims), \(count)),\n"
        }
        body += "            ]),\n"
    }
    return body + "    ]\n}\n"
}

guard FileManager.default.fileExists(atPath: vendor.path) else {
    FileHandle.standardError.write(
        Data("\(vendor.path) not found -- MIDI Control Center is not installed\n".utf8))
    exit(2)
}

let text = String(decoding: try Data(contentsOf: vendor), as: UTF8.self)
let trailingComma = try NSRegularExpression(pattern: #",(\s*[}\]])"#)
let strict = trailingComma.stringByReplacingMatches(
    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
guard let descriptor = try JSONSerialization.jsonObject(with: Data(strict.utf8)) as? [String: Any]
else {
    throw DescriptorError(description: "\(vendor.path) is not a JSON object")
}

let plan = try build(descriptor)
try render(plan).write(to: target, atomically: true, encoding: .utf8)

let format = Process()
format.executableURL = URL(filePath: "/usr/bin/env")
format.arguments = ["swift", "format", "--in-place", target.path]
try format.run()
format.waitUntilExit()
guard format.terminationStatus == 0 else {
    throw DescriptorError(description: "swift format failed on \(target.path)")
}
print("wrote \(target.path): \(plan.count) groups, \(requestCount(plan)) requests")
