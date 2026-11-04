import Foundation

/// How the app's screens lead to each other, read from its source. It's a best guess: navigation built while
/// the app runs can't be seen, so a screen can show up with no way in.
struct AppFlow: Equatable, Sendable {
    /// The project folder it was read from, so a view can tell an old flow from the current one.
    let folder: String
    let screens: [AppScreen]
    /// One per pair of screens, in the order of `screens`.
    let links: [Link]
    /// The class name of the screen the app opens on, when the source says.
    let start: String?

    struct Link: Hashable, Sendable {
        let from: String
        let to: String
        let kind: Kind
    }

    enum Kind: Int, Comparable, Sendable {
        /// Opened on top: Back returns.
        case opens
        /// Takes the place of the screen, as after signing in: Back doesn't return.
        case replaces
        /// Shown inside the other screen, like a tab.
        case contains

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Screens in columns, for drawing left to right: where the app starts, then each screen one column after
    /// the first screen that leads to it. Linked screens the start doesn't reach start trees of their own, under
    /// the first.
    struct Layout: Equatable {
        let columns: [[String]]
        /// Screens with no links at all.
        let unlinked: [String]
    }

    var layout: Layout {
        let names = screens.map(\.className)
        let links = links.filter { $0.from != $0.to }
        let incoming = Set(links.map(\.to))
        let outgoing = Set(links.map(\.from))
        var columns: [[String]] = []
        var placed = Set<String>()
        func grow(from root: String) {
            guard placed.insert(root).inserted else { return }
            var current = [root]
            var depth = 0
            while !current.isEmpty {
                if depth == columns.count { columns.append([]) }
                columns[depth] += current
                var next: [String] = []
                for name in current {
                    for link in links where link.from == name && placed.insert(link.to).inserted {
                        next.append(link.to)
                    }
                }
                current = next
                depth += 1
            }
        }
        if let start, names.contains(start) { grow(from: start) }
        // Then the other ways in: screens that lead somewhere but nothing leads to, and lastly loops.
        for name in names where outgoing.contains(name) && !incoming.contains(name) { grow(from: name) }
        for name in names where outgoing.contains(name) { grow(from: name) }
        return Layout(columns: columns, unlinked: names.filter { !placed.contains($0) })
    }
}

extension AppFlow {
    /// What two names of one screen have in common: "Home screen" in the plan is the `HomeScreen` in the code.
    static func screenKey(_ name: String) -> String {
        var key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        for suffix in ["screen", "page", "view"] where key.hasSuffix(suffix) && key.count > suffix.count {
            key = String(key.dropLast(suffix.count))
            break
        }
        return key
    }

    /// The flow with the plan's screens added as planned cards. A planned screen that matches a real one by name
    /// ("Home" and `HomeScreen`) is the real one, and the plan's links to and from it are kept.
    func adding(_ plan: ProductPlan) -> AppFlow {
        let key = Self.screenKey
        var classByKey = Dictionary(screens.map { (key($0.name), $0.className) }, uniquingKeysWith: { first, _ in first })
        var added: [AppScreen] = []
        for planned in plan.screens where classByKey[key(planned.name)] == nil && !key(planned.name).isEmpty {
            let className = "planned:" + key(planned.name)
            classByKey[key(planned.name)] = className
            added.append(AppScreen(name: planned.name, className: className, file: "", purpose: planned.purpose))
        }
        var links = self.links
        var seen = Set(links.map { [$0.from, $0.to] })
        for planned in plan.screens {
            guard let from = classByKey[key(planned.name)] else { continue }
            for target in planned.leadsTo {
                guard let to = classByKey[key(target)], to != from, from.hasPrefix("planned:") || to.hasPrefix("planned:"),
                      seen.insert([from, to]).inserted else { continue }
                links.append(Link(from: from, to: to, kind: .opens))
            }
        }
        return AppFlow(folder: folder, screens: screens + added, links: links, start: start)
    }
}

/// Finds `AppFlow` in Dart source without running anything. It follows the common ways Flutter apps navigate:
/// `Navigator.push(… => ProfilePage())`, named routes (`routes:`, `onGenerateRoute`), go_router (`GoRoute`,
/// `context.go`), auto_route (`ProfileRoute()`), and screens shown inside others, like tabs. Navigation in a
/// widget a screen uses (a drawer, a list tile) counts as the screen's.
///
/// Its regexes use simple word boundaries: with Swift's default Unicode ones, `Navigator.push` is one word, so
/// `\bpush` never matches.
enum FlowFinder {
    static func found(in folder: String) async -> AppFlow {
        await Task.detached { flow(in: folder) }.value
    }

    static func flow(in folder: String) -> AppFlow {
        flow(sources: ScreenFinder.sources(in: folder), folder: folder)
    }

    static func flow(sources: [DartSource], folder: String) -> AppFlow {
        let screens = ScreenFinder.screens(in: sources)
        let screenNames = Set(screens.map(\.className))
        // main.dart first, so its home: wins when looking for the start.
        let code = sources.sorted { ($0.file == "lib/main.dart" ? 0 : 1, $0.file) < ($1.file == "lib/main.dart" ? 0 : 1, $1.file) }
            .map { withoutComments($0.text) }
        let routes = RouteTable(code: code, screens: screens)

        var classes: [String: References] = [:]
        for text in code {
            for (name, references) in references(in: text, screens: screenNames, routes: routes) {
                classes[name, default: References()].add(references)
            }
        }

        var links: [AppFlow.Link] = []
        for screen in screens {
            for target in targets(of: screen.className, classes: classes, screens: screenNames) where target.to != screen.className {
                links.append(AppFlow.Link(from: screen.className, to: target.to, kind: target.kind))
            }
        }
        let start = start(in: code, routes: routes, classes: classes, screens: screenNames)
        return AppFlow(folder: folder, screens: screens, links: links, start: start)
    }

    // MARK: Per class

    struct Target: Hashable {
        let to: String
        let kind: AppFlow.Kind
    }

    /// What a class's code leads to, in source order: screens directly, and other classes it builds.
    struct References {
        var targets: [Target] = []
        var uses: [String] = []

        mutating func add(_ other: References) {
            for target in other.targets where !targets.contains(target) { targets.append(target) }
            for name in other.uses where !uses.contains(name) { uses.append(name) }
        }
    }

    /// References by class. A state class counts as its widget's: `_HomePageState extends State<HomePage>`, and
    /// the same through a custom base like `ViewModel<HomePage, HomeCubit>`.
    static func references(in text: String, screens: Set<String>, routes: RouteTable) -> [String: References] {
        let declarations = text.matches(of: /\bclass\s+(\w+)[^{;]*\{/.wordBoundaryKind(.simple))
        var result: [String: References] = [:]
        for (index, declaration) in declarations.enumerated() {
            let name = String(declaration.output.1)
            let owner = declaration.output.0.firstMatch(of: /extends\s+\w+\s*<\s*(\w+)/).map { String($0.1) }
                .flatMap { name.contains($0) && name != $0 ? $0 : nil } ?? name
            let end = index + 1 < declarations.count ? declarations[index + 1].range.lowerBound : text.endIndex
            let body = text[declaration.range.upperBound..<end]
            var found = References()
            for call in body.matches(of: /\b([A-Z]\w*)\s*(?:<[^<>()]*>)?\s*\(/.wordBoundaryKind(.simple)) {
                let name = String(call.1)
                if let screen = screens.contains(name) ? name : routes.routeClasses[name] {
                    found.targets.append(Target(to: screen, kind: kind(before: call.range.lowerBound, in: body)))
                } else {
                    found.uses.append(name)
                }
            }
            let navigation = /\b(push\w*|go|goNamed|replace\w*|popAndPush\w*)\s*(?:<[^<>()]*>)?\s*\(\s*(?:\w*[Cc]ontext\s*,\s*|ctx\s*,\s*|c\s*,\s*)?('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)/.wordBoundaryKind(.simple)
            for call in body.matches(of: navigation) {
                guard let screen = routes.screen(for: routes.key(String(call.2))) else { continue }
                found.targets.append(Target(to: screen, kind: kind(ofMethod: String(call.1))))
            }
            result[owner, default: References()].add(found)
        }
        return result
    }

    /// A screen built in a route (`MaterialPageRoute(builder: …)`) is opened; one built anywhere else, as in
    /// a list of tabs, is shown inside. Only the statement the screen is built in counts.
    static func kind(before index: String.Index, in body: Substring) -> AppFlow.Kind {
        var statement = body[..<index].suffix(240)
        if let end = statement.lastIndex(of: ";") { statement = statement[statement.index(after: end)...] }
        if statement.contains(/Replacement|RemoveUntil|\.go\s*\(|replace/) { return .replaces }
        if statement.contains(/push|PageRoute|Navigator|show\w*\(/) { return .opens }
        return .contains
    }

    static func kind(ofMethod method: String) -> AppFlow.Kind {
        let replaces = method.contains("Replacement") || method.contains("RemoveUntil") || method.hasPrefix("go")
            || method.hasPrefix("replace") || method.hasPrefix("pop")
        return replaces ? .replaces : .opens
    }

    /// Everything a screen leads to, its own code first and then the widgets it uses, a few levels deep.
    /// Other screens aren't followed: what they lead to is theirs.
    private static func targets(of screen: String, classes: [String: References], screens: Set<String>) -> [Target] {
        var targets: [Target] = []
        var visited: Set<String> = [screen]
        var level = [screen]
        for _ in 0..<4 where !level.isEmpty {
            var next: [String] = []
            for name in level {
                guard let references = classes[name] else { continue }
                for target in references.targets {
                    if let index = targets.firstIndex(where: { $0.to == target.to }) {
                        if target.kind < targets[index].kind { targets[index] = target }
                    } else {
                        targets.append(target)
                    }
                }
                for used in references.uses where !screens.contains(used) && classes[used] != nil && visited.insert(used).inserted {
                    next.append(used)
                }
            }
            level = next
        }
        return targets
    }

    // MARK: Start

    /// `home:`, `initialRoute:` or go_router's `initialLocation:`, else the "/" route. A `home:` that isn't a
    /// screen itself (an auth gate, say) starts on the first screen it leads to.
    private static func start(in code: [String], routes: RouteTable, classes: [String: References], screens: Set<String>) -> String? {
        for text in code {
            if let home = text.firstMatch(of: /\bhome\s*:\s*(?:const\s+|new\s+)?([A-Z]\w*)\s*\(/.wordBoundaryKind(.simple)).map({ String($0.1) }) {
                if screens.contains(home) { return home }
                if let first = targets(of: home, classes: classes, screens: screens).first { return first.to }
            }
            if let initial = text.firstMatch(of: /\b(?:initialRoute|initialLocation)\s*:\s*('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)/.wordBoundaryKind(.simple)),
               let screen = routes.screen(for: routes.key(String(initial.1))) {
                return screen
            }
        }
        return routes.screen(for: "/")
    }

    /// Without `//` and `/* */` comments, so commented-out navigation doesn't count. A `//` straight after
    /// `:` (a URL in a string) is kept.
    static func withoutComments(_ text: String) -> String {
        text.replacing(/\/\*[\s\S]*?\*\//, with: "")
            .replacing(/(^|[^:\/])\/\/[^\n]*/) { String($0.1) }
    }
}

/// Route paths and names, and the screen each one shows.
struct RouteTable: Sendable {
    private(set) var entries: [(key: String, screen: String)] = []
    /// auto_route's generated `ProfileRoute` for `ProfilePage`.
    let routeClasses: [String: String]
    /// String constants by name (`static const profile = '/profile'`), for routes named through one.
    private let constants: [String: String]

    init(code: [String], screens: [AppScreen]) {
        var routeClasses: [String: String] = [:]
        for screen in screens {
            routeClasses[screen.className + "Route"] = screen.className
            for suffix in ["Page", "Screen", "View"] where screen.className.hasSuffix(suffix) {
                routeClasses[String(screen.className.dropLast(suffix.count)) + "Route"] = screen.className
            }
        }
        self.routeClasses = routeClasses

        var constants: [String: String] = [:]
        for text in code {
            for match in text.matches(of: /\b(\w+)\s*=\s*['"]([^'"\n$]*)['"]/.wordBoundaryKind(.simple)) {
                let name = String(match.1), value = String(match.2)
                // Several constants can share a name; the one that looks like a path is the route.
                if constants[name] == nil || (value.hasPrefix("/") && constants[name]?.hasPrefix("/") == false) {
                    constants[name] = value
                }
            }
        }
        self.constants = constants

        let names = Set(screens.map(\.className))
        for text in code {
            // routes: {'/profile': (context) => const ProfilePage()}
            for match in text.matches(of: /('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)\s*:\s*\([^()]*\)\s*(?:=>|\{\s*return)\s*(?:const\s+|new\s+)?(\w+)\s*\(/)
            where names.contains(String(match.2)) {
                add(key(String(match.1)), String(match.2))
            }
            // GoRoute(path: '/profile', name: 'profile', builder: (context, state) => const ProfilePage())
            for segment in segments(of: text, startingAt: /\bGoRoute\s*\(/.wordBoundaryKind(.simple), length: 800) {
                guard let screen = firstScreen(in: segment, names: names) else { continue }
                if let path = segment.firstMatch(of: /\bpath\s*:\s*('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)/.wordBoundaryKind(.simple)) { add(key(String(path.1)), screen) }
                if let name = segment.firstMatch(of: /\bname\s*:\s*('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)/.wordBoundaryKind(.simple)) { add(key(String(name.1)), screen) }
            }
            // onGenerateRoute: case '/profile': return MaterialPageRoute(builder: (_) => const ProfilePage());
            for segment in segments(of: text, startingAt: /\bcase\s+/.wordBoundaryKind(.simple), length: 400) {
                guard let label = segment.firstMatch(of: /^('[^'\n]*'|"[^"\n]*"|[A-Za-z_][\w.]*)\s*:/),
                      let screen = firstScreen(in: segment, names: names) else { continue }
                add(key(String(label.1)), screen)
            }
        }
    }

    private mutating func add(_ key: String, _ screen: String) {
        if !entries.contains(where: { $0.key == key }) { entries.append((key, screen)) }
    }

    /// A route as written in the code: the string itself, or the value of the constant it names.
    func key(_ expression: String) -> String {
        if let quote = expression.first, quote == "'" || quote == "\"" { return String(expression.dropFirst().dropLast()) }
        let name = expression.split(separator: ".").last.map(String.init) ?? expression
        return constants[name] ?? "#" + name
    }

    func screen(for key: String) -> String? {
        if let exact = entries.first(where: { $0.key == key }) { return exact.screen }
        guard key.hasPrefix("/") else { return nil }
        // The longest route that fits, written-out segments before a `$id` standing in for one.
        let longestFirst = entries.sorted { $0.key.split(separator: "/").count > $1.key.split(separator: "/").count }
        return (longestFirst.first { Self.path(key, matches: $0.key, strictly: true) }
            ?? longestFirst.first { Self.path(key, matches: $0.key) })?.screen
    }

    /// "/user/$id" matches "/user/:id", and a nested go_router path ("details") matches the end of "/home/details".
    /// Strictly, a `$id` segment only matches a parameter.
    static func path(_ call: String, matches route: String, strictly: Bool = false) -> Bool {
        guard !route.hasPrefix("#") else { return false }
        let callParts = (call.split(separator: "?").first ?? "").split(separator: "/")
        let routeParts = route.split(separator: "/")
        guard !routeParts.isEmpty,
              route.hasPrefix("/") ? callParts.count == routeParts.count : callParts.count >= routeParts.count else { return false }
        return zip(callParts.suffix(routeParts.count), routeParts).allSatisfy { call, route in
            route.hasPrefix(":") || (!strictly && call.contains("$")) || call == route
        }
    }

    /// The text after each match of `marker`, up to the next match or `length` characters.
    private func segments(of text: String, startingAt marker: some RegexComponent, length: Int) -> [Substring] {
        let ranges = text.matches(of: marker).map(\.range)
        return ranges.enumerated().map { index, range in
            let next = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            let limit = text.index(range.upperBound, offsetBy: length, limitedBy: next) ?? next
            return text[range.upperBound..<min(next, limit)]
        }
    }

    private func firstScreen(in segment: Substring, names: Set<String>) -> String? {
        segment.matches(of: /\b([A-Z]\w*)\s*\(/.wordBoundaryKind(.simple)).lazy.map { String($0.1) }.first(where: names.contains)
    }
}
