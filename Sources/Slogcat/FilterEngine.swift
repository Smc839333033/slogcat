import Foundation

/// Compiles a FilterSpec into a reusable matcher and tests entries against it.
///
/// Each rule targets a field (message / tag / pid) with a mode (include / exclude / regex).
/// Includes are OR (any match shows); excludes are OR with priority (any match drops).
enum FilterEngine {
    struct Compiled: Sendable {
        let enabledLevels: Set<LogLevel>
        let msgIncludes: [NSRegularExpression]
        let msgExcludes: [NSRegularExpression]
        let tagIncludes: [NSRegularExpression]
        let tagExcludes: [NSRegularExpression]
        let pidEquals: [Int]
    }

    private static func makeRegex(_ s: String, regex: Bool) -> NSRegularExpression? {
        let pattern = regex ? s : NSRegularExpression.escapedPattern(for: s)
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func compile(_ spec: FilterSpec) -> Compiled {
        var msgInc: [NSRegularExpression] = []
        var msgExc: [NSRegularExpression] = []
        var tagInc: [NSRegularExpression] = []
        var tagExc: [NSRegularExpression] = []
        var pids: [Int] = []

        for rule in spec.rules {
            guard rule.enabled, !rule.text.isEmpty else { continue }
            switch rule.kind {
            case .msgInclude:    if let re = makeRegex(rule.text, regex: false) { msgInc.append(re) }
            case .msgExclude:    if let re = makeRegex(rule.text, regex: false) { msgExc.append(re) }
            case .msgIncludeRx:  if let re = makeRegex(rule.text, regex: true)  { msgInc.append(re) }
            case .msgExcludeRx:  if let re = makeRegex(rule.text, regex: true)  { msgExc.append(re) }
            case .tagInclude:    if let re = makeRegex(rule.text, regex: false) { tagInc.append(re) }
            case .tagExclude:    if let re = makeRegex(rule.text, regex: false) { tagExc.append(re) }
            case .tagIncludeRx:  if let re = makeRegex(rule.text, regex: true)  { tagInc.append(re) }
            case .tagExcludeRx:  if let re = makeRegex(rule.text, regex: true)  { tagExc.append(re) }
            case .pidEquals:     if let p = Int(rule.text) { pids.append(p) }
            }
        }

        return Compiled(
            enabledLevels: spec.enabledLevels,
            msgIncludes: msgInc,
            msgExcludes: msgExc,
            tagIncludes: tagInc,
            tagExcludes: tagExc,
            pidEquals: pids
        )
    }

    static func test(_ entry: LogEntry, against c: Compiled) -> Bool {
        guard c.enabledLevels.contains(entry.level) else { return false }

        let msg = entry.message as NSString
        let msgRange = NSRange(location: 0, length: msg.length)
        let tag = entry.tag as NSString
        let tagRange = NSRange(location: 0, length: tag.length)

        // Excludes have priority: any match drops the line.
        for r in c.msgExcludes { if r.firstMatch(in: entry.message, range: msgRange) != nil { return false } }
        for r in c.tagExcludes { if r.firstMatch(in: entry.tag, range: tagRange) != nil { return false } }

        // Includes are OR: if any are present, at least one must match; empty → pass.
        let hasIncludes = !c.msgIncludes.isEmpty || !c.tagIncludes.isEmpty || !c.pidEquals.isEmpty
        if hasIncludes {
            var matched = false
            for r in c.msgIncludes where r.firstMatch(in: entry.message, range: msgRange) != nil { matched = true; break }
            if !matched {
                for r in c.tagIncludes where r.firstMatch(in: entry.tag, range: tagRange) != nil { matched = true; break }
            }
            if !matched {
                for p in c.pidEquals where entry.pid == p { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }
}
