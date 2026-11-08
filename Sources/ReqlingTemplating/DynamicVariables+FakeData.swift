import Foundation

/// Postman's most used fake-data built-ins, in the shapes Postman writes them, drawn from short word lists of Reqling's
/// own rather than Postman's, so values read alike without matching word for word.
extension DynamicVariables {
    static let fakeDataGenerators: [Generator] = [
        Generator("$randomFirstName") { $0.pick(firstNames) },
        Generator("$randomLastName") { $0.pick(lastNames) },
        Generator("$randomFullName") { "\($0.pick(firstNames)) \($0.pick(lastNames))" },
        Generator("$randomUserName") { $0.userName() },
        Generator("$randomEmail") { "\($0.userName())@\($0.pick(emailDomains))" },
        Generator("$randomPhoneNumber") { "\($0.digits(3))-\($0.digits(3))-\($0.digits(4))" },
        Generator("$randomCity") { $0.pick(cities) },
        Generator("$randomCompanyName") { $0.companyName() },
        Generator("$randomLoremWord") { $0.pick(loremWords) },
        Generator("$randomLoremSentence") { $0.loremSentence() }
    ]

    func pick(_ words: [String]) -> String {
        words[random(0..<words.count)]
    }

    func digits(_ count: Int) -> String {
        (0..<count).map { _ in String(random(0..<10)) }.joined()
    }

    /// `Ada.Lovelace`, `Ada_Lovelace42`, or `Ada17`, the three shapes Postman's user names take.
    func userName() -> String {
        let first = pick(Self.firstNames)
        let separator = random(0..<2) == 0 ? "." : "_"
        switch random(0..<3) {
        case 0: return "\(first)\(random(0..<100))"
        case 1: return "\(first)\(separator)\(pick(Self.lastNames))"
        default: return "\(first)\(separator)\(pick(Self.lastNames))\(random(0..<100))"
        }
    }

    /// `Hart LLC`, `Hart - Okafor`, or `Hart, Okafor and Silva`, the three shapes Postman's company names take.
    func companyName() -> String {
        let name = pick(Self.lastNames)
        switch random(0..<3) {
        case 0: return "\(name) \(pick(Self.companySuffixes))"
        case 1: return "\(name) - \(pick(Self.lastNames))"
        default: return "\(name), \(pick(Self.lastNames)) and \(pick(Self.lastNames))"
        }
    }

    /// Three to ten words, capitalized and ending in a period.
    func loremSentence() -> String {
        let words = (0..<random(3..<11)).map { _ in pick(Self.loremWords) }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst() + "."
    }

    private static let firstNames = [
        "Ada", "Alan", "Amara", "Ana", "Arjun", "Ben", "Carmen", "Chen", "Dana", "Diego", "Elena", "Emeka", "Ethan", "Fatima",
        "Grace", "Hana", "Hugo", "Ines", "Isaac", "Jamal", "Jin", "Julia", "Kai", "Kofi", "Lena", "Leo", "Lucia", "Maya",
        "Mateo", "Nadia", "Noah", "Omar", "Priya", "Quinn", "Rosa", "Sam", "Sofia", "Tariq", "Uma", "Victor", "Wei", "Yara",
        "Zoe"
    ]

    private static let lastNames = [
        "Adams", "Baker", "Bauer", "Castro", "Chen", "Costa", "Dubois", "Evans", "Fischer", "Garcia", "Gupta", "Hart",
        "Ibrahim", "Ito", "Jensen", "Kim", "Kowalski", "Larsen", "Lopez", "Mendes", "Moreau", "Nakamura", "Novak", "Okafor",
        "Park", "Patel", "Quinn", "Reyes", "Rossi", "Santos", "Schmidt", "Silva", "Tanaka", "Torres", "Ueda", "Varga",
        "Walsh", "Weber", "Xu", "Young", "Zhang"
    ]

    private static let emailDomains = ["gmail.com", "yahoo.com", "hotmail.com"]

    private static let cities = [
        "Arlington", "Ashland", "Auburn", "Bristol", "Burlington", "Centerville", "Clayton", "Clinton", "Dayton", "Dover",
        "Fairview", "Franklin", "Georgetown", "Greenville", "Hudson", "Jackson", "Kingston", "Lebanon", "Lexington",
        "Madison", "Manchester", "Marion", "Milton", "Newport", "Oakland", "Oxford", "Riverside", "Salem", "Springfield",
        "Winchester"
    ]

    private static let companySuffixes = ["Inc", "and Sons", "LLC", "Group"]

    private static let loremWords = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor",
        "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo", "consequat", "duis", "aute", "irure",
        "in", "reprehenderit", "voluptate", "velit", "esse", "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint",
        "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui", "officia", "deserunt", "mollit", "anim", "id",
        "est", "laborum"
    ]
}
