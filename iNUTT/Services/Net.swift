import Foundation
import WebKit
import UIKit

enum NetError: LocalizedError {
    case badStatus(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "The site returned error \(c)."
        case .empty: return "The page is empty."
        }
    }
}

enum Net {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static let cache: URLCache = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inutt-http", isDirectory: true)
        return URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024, directory: dir)
    }()

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = cache
        c.requestCachePolicy = .useProtocolCachePolicy
        c.timeoutIntervalForRequest = 25
        c.httpMaximumConnectionsPerHost = 6
        c.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        c.httpCookieAcceptPolicy = .always
        c.httpShouldSetCookies = true
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, referer: URL? = nil, policy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: policy)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { r.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        return r
    }

    static func fetch(_ url: URL, referer: URL? = nil, policy: URLRequest.CachePolicy = .reloadRevalidatingCacheData) async throws -> (Data, HTTPURLResponse?) {
        var req = request(url, referer: referer, policy: policy)
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let code = http?.statusCode, code >= 400 { throw NetError.badStatus(code) }
        if data.isEmpty { throw NetError.empty }
        return (data, http)
    }

    static func text(_ data: Data, response: HTTPURLResponse?) -> String {
        if let enc = response?.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(enc as CFString)
            if cf != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(cf)
                if let s = String(data: data, encoding: String.Encoding(rawValue: ns)) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Reddit asks apps for a descriptive user agent and answers browsers less reliably.
    static let redditUserAgent = "ios:dev.scyde.inutt:v1.0 (by /u/inutt_app)"

    /// Reddit JSON, trying www and old.reddit.com; adult subreddits need the over18 cookie.
    static func redditJSON(_ jsonURL: URL) async throws -> Data {
        var lastError: Error = NetError.empty
        for host in ["www.reddit.com", "old.reddit.com"] {
            guard var comps = URLComponents(url: jsonURL, resolvingAgainstBaseURL: false) else { continue }
            comps.host = host
            guard let u = comps.url else { continue }
            var req = URLRequest(url: u, cachePolicy: .reloadRevalidatingCacheData)
            req.setValue(redditUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("over18=1", forHTTPHeaderField: "Cookie")
            do {
                let (data, resp) = try await session.data(for: req)
                if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw NetError.badStatus(code) }
                // Blocked requests come back as an HTML page.
                guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }),
                      first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { throw NetError.empty }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Headers AVPlayer should send so hot-link protected media plays.
    static func avHeaders(referer: URL?) -> [String: Any] {
        var h: [String: String] = ["User-Agent": userAgent]
        if let referer { h["Referer"] = referer.absoluteString }
        return ["AVURLAssetHTTPHeaderFieldsKey": h]
    }
}

/// Renders JavaScript-heavy pages off screen and returns the final DOM. Nothing of it is ever shown.
@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    static let shared = PageRenderer()

    private var continuations: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    private var active = 0
    private let maxActive = 2

    func render(_ url: URL, settle: Double = 1.6) async -> String? {
        while active >= maxActive { try? await Task.sleep(nanoseconds: 200_000_000) }
        active += 1
        defer { active -= 1 }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = .default()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = Net.userAgent
        web.navigationDelegate = self
        web.isUserInteractionEnabled = false
        web.alpha = 0.01
        // Attach behind everything so timers and lazy loading run normally.
        let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        host?.insertSubview(web, at: 0)
        defer { web.stopLoading(); web.removeFromSuperview() }

        web.load(Net.request(url))
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuations[ObjectIdentifier(web)] = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                self.finish(web, ok: false)
            }
        }
        if !ok && web.url == nil { return nil }
        // Trigger lazy-loaded content.
        for _ in 0..<3 {
            _ = try? await web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); 1")
            try? await Task.sleep(nanoseconds: UInt64(settle / 3 * 1_000_000_000))
        }
        let html = try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        return html
    }

    private func finish(_ web: WKWebView, ok: Bool) {
        if let c = continuations.removeValue(forKey: ObjectIdentifier(web)) { c.resume(returning: ok) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(webView, ok: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(webView, ok: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(webView, ok: false)
    }
}
