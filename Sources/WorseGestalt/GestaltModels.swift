//
//  GestaltModels.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum PlistValueKind: String, CaseIterable, Identifiable {
    case string, integer, float, boolean, data, array, dictionary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .string: "String"
        case .integer: "Integer"
        case .float: "Float"
        case .boolean: "Boolean"
        case .data: "Data (Base64)"
        case .array: "Array (JSON)"
        case .dictionary: "Dictionary (JSON)"
        }
    }

    static func kind(of value: Any?) -> PlistValueKind {
        switch value {
        case is String: .string
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .boolean
                : (CFNumberIsFloatType(number) ? .float : .integer)
        case is Data: .data
        case is NSArray: .array
        case is NSDictionary: .dictionary
        default: .string
        }
    }

    static func encode(_ value: Any?, as kind: PlistValueKind) -> String {
        switch kind {
        case .string:
            return value as? String ?? ""
        case .integer, .float:
            return (value as? NSNumber)?.stringValue ?? ""
        case .boolean:
            return ((value as? NSNumber)?.boolValue ?? false) ? "true" : "false"
        case .data:
            return (value as? Data)?.base64EncodedString() ?? ""
        case .array, .dictionary:
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    static func parse(_ text: String, as kind: PlistValueKind) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .string: return text
        case .integer:
            guard let n = Int64(trimmed) else { throw PlistValueError("Invalid integer.") }
            return NSNumber(value: n)
        case .float:
            guard let d = Double(trimmed) else { throw PlistValueError("Invalid float.") }
            return NSNumber(value: d)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1", "yes": return NSNumber(value: true)
            case "false", "0", "no": return NSNumber(value: false)
            default: throw PlistValueError("Enter true or false.")
            }
        case .data:
            guard let data = Data(base64Encoded: trimmed) else { throw PlistValueError("Invalid Base64.") }
            return data
        case .array, .dictionary:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                throw PlistValueError("Invalid JSON.")
            }
            if kind == .array, !(object is [Any]) { throw PlistValueError("Expected a JSON array.") }
            if kind == .dictionary, !(object is [String: Any]) { throw PlistValueError("Expected a JSON object.") }
            return object
        }
    }
}

struct PlistValueError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One CacheExtra row as shown in the UI.
struct GestaltEntry: Identifiable, Equatable {
    let key: String
    let kind: PlistValueKind
    let summary: String

    var id: String { key }

    /// Human-readable name from the Apple Wiki key map, when known.
    var readableName: String {
        GestaltKeyMap.names[key] ?? key
    }

    /// Human-readable description from the Apple Wiki key map, when known.
    var readableDescription: String {
        key.count == 22 ? (GestaltKeyMap.descriptions[key] ?? "") : ""
    }

    static func summary(of value: Any?, kind: PlistValueKind) -> String {
        switch kind {
        case .string:
            let text = (value as? String) ?? ""
            return text.isEmpty ? "(empty)" : text
        case .integer, .float, .boolean:
            return PlistValueKind.encode(value, as: kind)
        case .data:
            let data = value as? Data
            return "Data (\(data?.count ?? 0) bytes)"
        case .array:
            return "Array (\((value as? [Any])?.count ?? 0))"
        case .dictionary:
            return "Dictionary (\((value as? [String: Any])?.count ?? 0))"
        }
    }}

/// A named backup of the raw MobileGestalt plist, stored in the app container.
struct GestaltBackup: Identifiable, Hashable {
    let fileName: String
    let date: Date

    var id: String { fileName }
    var displayName: String { String(fileName.dropSuffix(".plist")) }

    static let directoryName = "Backups"

    static var directory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    var url: URL { Self.directory.appendingPathComponent(fileName) }

    static func make() throws -> GestaltBackup {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "\(formatter.string(from: Date())).plist"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return GestaltBackup(fileName: name, date: Date())
    }

    static func list() throws -> [GestaltBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0.hasSuffix(".plist") }
            .sorted(by: >)
            .compactMap { name in
                // yyyy-MM-dd_HH-mm-ss-SSS
                let datePart = String(name.dropSuffix(".plist"))
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
                guard let date = formatter.date(from: datePart) else { return nil }
                return GestaltBackup(fileName: name, date: date)
            }
    }
}

private extension String {
    func dropSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
