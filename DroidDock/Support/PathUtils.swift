import Foundation

/// POSIX 路径处理、媒体类型推断、MTP 日期解析与字节格式化工具。
enum PathUtils {
    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "3gp", "webm",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "txt", "md", "csv", "json", "zip", "rar", "7z", "apk",
    ]

    /// 规范化为以 `/` 开头的 POSIX 路径；根目录返回 `"/"`。
    static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            } else if component == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            } else {
                stack.append(component)
            }
        }
        if stack.isEmpty {
            return "/"
        }
        return "/" + stack.joined(separator: "/")
    }

    static func join(_ dir: String, _ name: String) -> String {
        let normalizedDir = normalize(dir)
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedName.isEmpty else { return normalizedDir }
        if normalizedDir == "/" {
            return normalize("/" + trimmedName)
        }
        return normalize(normalizedDir + "/" + trimmedName)
    }

    static func parentPath(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        if components.count <= 1 {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    static func filename(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "/"
    }

    /// 返回面包屑列表，首项固定为根目录 `"/"`。
    static func breadcrumbs(for path: String, rootTitle: String = "内部存储") -> [(name: String, path: String)] {
        let normalized = normalize(path)
        var result: [(name: String, path: String)] = [(rootTitle, "/")]
        guard normalized != "/" else { return result }
        var current = ""
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }

    static func inferMediaKind(filename: String) -> MediaKind {
        guard let dot = filename.lastIndex(of: ".") else { return .other }
        let ext = filename[filename.index(after: dot)...].lowercased()
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        return .other
    }

    /// 解析 MTP ISO-8601 风格日期串（`YYYYMMDDThhmmss[.s][Z|±hhmm]`）。
    static func parseMTPDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 else { return nil }
        let chars = Array(trimmed)
        guard chars[8] == "T" else { return nil }

        func digits(_ start: Int, _ length: Int) -> Int? {
            guard start + length <= chars.count else { return nil }
            return Int(String(chars[start..<(start + length)]))
        }

        guard let year = digits(0, 4),
              let month = digits(4, 2),
              let day = digits(6, 2),
              let hour = digits(9, 2),
              let minute = digits(11, 2),
              let second = digits(13, 2) else {
            return nil
        }

        var idx = 15
        if idx < chars.count, chars[idx] == "." {
            idx += 1
            while idx < chars.count, chars[idx].isNumber {
                idx += 1
            }
        }

        var timeZone = TimeZone.current
        if idx < chars.count {
            let tzSuffix = String(chars[idx...])
            if tzSuffix == "Z" {
                timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            } else if tzSuffix.count == 5 || tzSuffix.count == 6 {
                let sign = tzSuffix.first == "-" ? -1 : (tzSuffix.first == "+" ? 1 : 0)
                let clean = tzSuffix.dropFirst().replacingOccurrences(of: ":", with: "")
                if sign != 0, clean.count == 4,
                   let tzH = Int(clean.prefix(2)),
                   let tzM = Int(clean.suffix(2)) {
                    timeZone = TimeZone(secondsFromGMT: sign * (tzH * 3600 + tzM * 60)) ?? .current
                }
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return calendar.date(from: comps)
    }

    static func formatByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func formatMTPDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02d",
            c.year ?? 1970, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// 校验 Android 存储可接受的文件名/目录名，合法返回 nil，非法返回可读原因。
    static func validateAndroidFilename(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "名称不能为空"
        }
        guard name != ".", name != ".." else {
            return "名称不能为 . 或 .."
        }
        if name.utf8.count > 255 {
            return "名称长度不能超过 255 字节"
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        if name.rangeOfCharacter(from: forbidden) != nil {
            return "名称不能包含 / \\ : * ? \" < > | 等字符"
        }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return "名称不能包含控制字符"
            }
        }
        return nil
    }

    enum ConflictResolution: Sendable, Equatable {
        case proceed(finalName: String, overwriteExisting: Bool)
        case skip
    }

    /// 按冲突策略决定最终目标名称；大小写不敏感匹配以兼容 Android VFAT/FUSE 与 macOS APFS。
    static func resolveConflictDestination(
        name: String,
        existingNames: Set<String>,
        strategy: ConflictStrategy
    ) -> ConflictResolution {
        let lowerExisting = Set(existingNames.map { $0.lowercased() })
        guard lowerExisting.contains(name.lowercased()) else {
            return .proceed(finalName: name, overwriteExisting: false)
        }
        switch strategy {
        case .skip:
            return .skip
        case .overwrite:
            return .proceed(finalName: name, overwriteExisting: true)
        case .rename:
            let ns = name as NSString
            let ext = ns.pathExtension
            let stem = ext.isEmpty ? name : ns.deletingPathExtension
            for index in 1...9999 {
                let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                if !lowerExisting.contains(candidate.lowercased()) {
                    return .proceed(finalName: candidate, overwriteExisting: false)
                }
            }
            return .proceed(finalName: "\(stem) (\(UUID().uuidString.prefix(6)))\(ext.isEmpty ? "" : ".\(ext)")", overwriteExisting: false)
        }
    }
}

/// 同名文件冲突处理策略。
enum ConflictStrategy: String, CaseIterable, Identifiable, Sendable {
    case rename = "自动重命名"
    case overwrite = "覆盖"
    case skip = "跳过"

    var id: String { rawValue }
}
