import Foundation
import ReqlingScriptProtocol

/// The project's cookie jar as the phase's scripts see it, which every level shares: a copy of the jar as the phase
/// started, with each change applied at once, so the next read or level sees it, and reported at once, so it survives a
/// later throw or kill. Reqling applies the reported changes to the real jar after the phase (`ScriptSession`).
///
/// The copy is an in-memory `HTTPCookieStorage`, so a URL matches with the very code URLSession sends cookies with. It's
/// made on the first cookie call, so a script that never touches cookies pays nothing for it at launch.
///
/// A request a script sends may store cookies in the real jar, so its reply carries the jar as it then stands, with the
/// changes reported before the request went out on top (`ScriptFetchReply.cookies`). The copy is made again from that,
/// with the changes made since the request went out replayed (`requestSettled`).
final class ScriptCookies {
    private var snapshot: [ScriptCookie]
    private let request: ScriptRequestModel
    private let variables: ScriptVariables
    private let limits: ScriptLimits
    private let events: EventWriter
    private var writes = 0
    /// What the write limit applies to, as its message names it.
    private var unit = "phase"
    private var mirror: HTTPCookieStorage?
    /// Counts every change, so a request knows which came after it went out.
    private var sequence = 0
    /// Where `sequence` stood as each request still out was sent.
    private var marks: [Int] = []
    /// The changes made since the oldest request still out was sent: a reply's jar may lack them. Empty while no
    /// request is out, so a long stream keeps none.
    private var log: [(sequence: Int, write: ScriptCookieWrite)] = []
    /// What the next copy replays over `snapshot`, taken from `log` by the reply that set `snapshot`.
    private var replay: [ScriptCookieWrite] = []

    init(snapshot: [ScriptCookie], request: ScriptRequestModel, variables: ScriptVariables, limits: ScriptLimits, events: EventWriter) {
        self.snapshot = snapshot
        self.request = request
        self.variables = variables
        self.limits = limits
        self.events = events
    }

    /// Starts a stream handler call's own write limit; what earlier calls set stays.
    func beginCall() {
        writes = 0
        unit = "handler call"
    }

    /// Notes a request going out; what it returns names it to `requestSettled`.
    func requestSent() -> Int {
        marks.append(sequence)
        return sequence
    }

    /// A request is answered, carrying `jar` (or none, leaving the copy as it is), or was given up on. The next read
    /// sees `jar` with the changes made since the request went out on top.
    func requestSettled(_ mark: Int, jar: [ScriptCookie]?) {
        if let index = marks.firstIndex(of: mark) {
            marks.remove(at: index)
        }
        if let jar {
            snapshot = jar
            replay = log.filter { $0.sequence > mark }.map(\.write)
            mirror = nil
        }
        if let oldest = marks.min() {
            log.removeAll { $0.sequence <= oldest }
        } else {
            log.removeAll()
        }
    }

    /// `rq.cookies.for`'s target with its `{{variables}}` resolved, as the canonical text `scope` reads back.
    func target(_ text: String) throws(ScriptFailure) -> String {
        let resolved = variables.resolve(text)
        guard resolved.unresolved.isEmpty else {
            throw ScriptFailure("rq.cookies.for: \(Self.names(resolved.unresolved)) isn't defined.")
        }
        do {
            return try ScriptCookieScope.parse(resolved.value).text
        } catch {
            throw ScriptFailure("rq.cookies.for: \(error.message)")
        }
    }

    /// The scope a `target` names, or the request's URL for `nil`, resolved again on every call, since an earlier
    /// line may set a variable the URL uses.
    func scope(_ target: String?) throws(ScriptFailure) -> ScriptCookieScope {
        guard let target else {
            return try requestScope()
        }
        do {
            return try ScriptCookieScope.parse(target)
        } catch {
            throw ScriptFailure(error.message)
        }
    }

    func cookies(in scope: ScriptCookieScope) throws(ScriptFailure) -> [ScriptCookie] {
        try jar().cookies(in: scope).map(ScriptCookie.init)
    }

    func set(_ setting: ScriptCookieSetting, in scope: ScriptCookieScope) throws(ScriptFailure) {
        let write: ScriptCookieWrite
        do {
            write = try setting.write(for: scope, limits: limits)
        } catch {
            throw ScriptFailure(error.message)
        }
        try record([write])
    }

    /// Removes every cookie with the name that the scope covers.
    func remove(named name: String, in scope: ScriptCookieScope) throws(ScriptFailure) {
        try record(jar().cookies(in: scope).filter { $0.name == name }.map { .remove(ScriptCookie($0).identity) })
    }

    func clear(in scope: ScriptCookieScope) throws(ScriptFailure) {
        try record(jar().cookies(in: scope).map { .remove(ScriptCookie($0).identity) })
    }

    /// Applies and reports `changes`, or none of them past the phase's limit.
    private func record(_ changes: [ScriptCookieWrite]) throws(ScriptFailure) {
        guard writes + changes.count <= limits.cookieWrites else {
            throw ScriptFailure("Scripts can set or remove at most \(limits.cookieWrites) cookies in one \(unit).")
        }
        let jar = try jar()
        for change in changes {
            writes += 1
            sequence += 1
            jar.apply(change)
            if !marks.isEmpty {
                log.append((sequence, change))
            }
            events.write(.cookie(change))
        }
    }

    /// A gRPC call is sent to no URL, so only `rq.cookies.for` reaches the jar from its scripts.
    private func requestScope() throws(ScriptFailure) -> ScriptCookieScope {
        guard request.snapshot.protocolName != "grpc" else {
            throw ScriptFailure("A gRPC call has no URL for cookies; use rq.cookies.for(url).")
        }
        let resolved = variables.resolve(request.snapshot.url)
        guard resolved.unresolved.isEmpty else {
            throw ScriptFailure(
                "This request's URL uses \(Self.names(resolved.unresolved)), which isn't defined, so it has no cookies; use rq.cookies.for(url)."
            )
        }
        do {
            return try ScriptCookieScope.requestURL(resolved.value)
        } catch {
            throw ScriptFailure("This request's URL has no cookies: \(error.message) Use rq.cookies.for(url).")
        }
    }

    private func jar() throws(ScriptFailure) -> HTTPCookieStorage {
        if let mirror {
            return mirror
        }
        guard let storage = URLSessionConfiguration.ephemeral.httpCookieStorage else {
            throw ScriptFailure("Reqling couldn't open the project's cookies.")
        }
        for cookie in snapshot {
            if let stored = cookie.httpCookie {
                storage.setCookie(stored)
            }
        }
        for change in replay {
            storage.apply(change)
        }
        replay = []
        mirror = storage
        return storage
    }

    private static func names(_ names: [String]) -> String {
        names.map { "{{\($0)}}" }.joined(separator: ", ")
    }
}
