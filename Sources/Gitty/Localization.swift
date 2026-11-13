import Foundation

/// 화면 글자 번역. 소스는 한국어로 쓰고, 영어 화면이면 Resources/en.json의 번역을 쓴다.
///   tr("‘\(name)’ 폴더를 만들었습니다")  → 키 "‘{}’ 폴더를 만들었습니다", 값 "Created folder ‘{}’"
/// 끼워 넣은 값은 키에서 {}로 바뀌고, 번역에서 {} (순서대로) 또는 {1}, {2} (자리 지정)로 다시 들어간다.
/// 번역이 없으면 한국어 그대로 보인다. 작업 기록(로그)은 번역하지 않는다.
struct Tr: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]

    init(stringLiteral value: String) {
        key = value
        args = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        args = stringInterpolation.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{}"
            args.append(String(describing: value))
        }
    }
}

func tr(_ text: Tr) -> String {
    Loc.translate(text.key, text.args)
}

enum Loc {
    static let languageKey = "appLanguage"   // "system" | "ko" | "en"

    /// 영어로 보일지 (설정 → 언어, 기본은 시스템 언어)
    static let isEnglish: Bool = {
        switch UserDefaults.standard.string(forKey: languageKey) ?? "system" {
        case "ko": return false
        case "en": return true
        default: return !(Locale.preferredLanguages.first ?? "ko").hasPrefix("ko")
        }
    }()

    private static let english: [String: String] = {
        guard isEnglish, let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    static func translate(_ key: String, _ args: [String]) -> String {
        let template = english[key] ?? key
        return fill(template, args)
    }

    /// {} 는 순서대로, {1} {2} 는 그 자리 값으로
    static func fill(_ template: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return template }
        var out = ""
        var next = 0
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = template[template.index(after: i)..<close]
                if inner.isEmpty, next < args.count {
                    out += args[next]; next += 1
                    i = template.index(after: close); continue
                }
                if let n = Int(inner), n >= 1, n <= args.count {
                    out += args[n - 1]
                    i = template.index(after: close); continue
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }
}
