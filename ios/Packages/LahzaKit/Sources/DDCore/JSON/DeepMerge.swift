import Foundation

extension JSONValue {
    /// Keys `deepMerge` never copies from a patch (a JavaScript prototype-pollution guard).
    public static let deepMergeIgnoredKeys: Set<String> = ["__proto__", "constructor", "prototype"]

    /// `deepMerge(base, ...patches)`: a JavaScript-compatible recursive merge.
    ///
    /// - Plain objects merge key by key, recursively. An existing key keeps its position; a new key
    ///   is appended (JS property order).
    /// - Arrays, null and scalars replace. A non-object patch replaces the whole result.
    /// - A nil patch is JS `undefined` and is skipped.
    /// - `__proto__`, `constructor` and `prototype` keys in a patch are ignored.
    public static func deepMerge(_ base: JSONValue, _ patches: JSONValue?...) -> JSONValue {
        deepMerge(base, patches: patches)
    }

    /// Array form of ``deepMerge(_:_:)``.
    public static func deepMerge(_ base: JSONValue, patches: [JSONValue?]) -> JSONValue {
        var result = base
        for case let patch? in patches {
            guard case .object(let current) = result, case .object(let patchObject) = patch else {
                result = patch
                continue
            }
            var merged = current
            for (key, value) in patchObject where !isDeepMergeIgnoredKey(key) {
                if case .object = value, let existing = merged[key], case .object = existing {
                    merged[key] = deepMerge(existing, value)
                } else {
                    merged[key] = value
                }
            }
            result = .object(merged)
        }
        return result
    }

    /// `key === "__proto__" || key === "constructor" || key === "prototype"` (code units).
    static func isDeepMergeIgnoredKey(_ key: String) -> Bool {
        deepMergeIgnoredKeys.contains { jsStringEqual($0, key) }
    }

    /// `JSONValue.deepMerge(self, ...patches)`.
    public func deepMerged(with patches: JSONValue?...) -> JSONValue {
        JSONValue.deepMerge(self, patches: patches)
    }
}
