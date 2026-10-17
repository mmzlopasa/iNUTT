import Foundation
import AVFoundation
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
        SiteAdapters.prepare(url)
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
    static func avHeaders(referer: URL?, url: URL? = nil) -> [String: Any] {
        var h: [String: String] = ["User-Agent": userAgent]
        if let referer {
            h["Referer"] = referer.absoluteString
            // CDNs that check where a stream is played from also look at the origin.
            if let scheme = referer.scheme, let host = referer.host { h["Origin"] = "\(scheme)://\(host)" }
        }
        var opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": h]
        // Signed in through the in-app browser: the player sends the same cookies.
        if let url, !url.isFileURL, let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            opts[AVURLAssetHTTPCookiesKey] = cookies
        }
        return opts
    }
}

/// Renders JavaScript-heavy pages off screen. Nothing of it is ever shown.
///
/// Two lanes: what the user is waiting for right now (opening a video, Reels) never queues behind
/// background work such as refreshing sites.
@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    static let shared = PageRenderer()

    enum Priority { case user, background }

    private var continuations: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    private var active: [Priority: Int] = [.user: 0, .background: 0]
    private let limits: [Priority: Int] = [.user: 3, .background: 2]
    /// Background pages wait while the user is waiting for something.
    private var userWaiting = 0

    private func acquire(_ p: Priority) async {
        if p == .user { userWaiting += 1 }
        while (active[p] ?? 0) >= (limits[p] ?? 1) || (p == .background && userWaiting > 0) {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if p == .user { userWaiting -= 1 }
        active[p, default: 0] += 1
    }

    private func release(_ p: Priority) { active[p, default: 1] -= 1 }

    /// Creates an off-screen web view and starts loading. Returns once the first response arrived or failed.
    private func open(_ url: URL, media: Bool) async -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = media ? [] : .all
        config.websiteDataStore = .default()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = Net.userAgent
        web.navigationDelegate = self
        web.isUserInteractionEnabled = false
        web.alpha = 0.01
        // Attach behind everything so timers and lazy loading run normally.
        let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        host?.insertSubview(web, at: 0)
        // Adult sites show their content only once the age gate has been passed.
        await SiteAdapters.prepare(url, store: config.websiteDataStore.httpCookieStore)
        web.load(Net.request(url))
        return web
    }

    private func close(_ web: WKWebView) {
        finish(web, ok: false)
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
    }

    /// Waits for the page to finish loading, at most `timeout` seconds.
    private func waitLoaded(_ web: WKWebView, timeout: Double) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuations[ObjectIdentifier(web)] = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(web, ok: false)
            }
        }
    }

    /// The final DOM of a listing page, for background refreshes.
    func render(_ url: URL, settle: Double = 1.6, priority: Priority = .background) async -> String? {
        await acquire(priority)
        defer { release(priority) }
        let web = await open(url, media: false)
        defer { close(web) }
        let ok = await waitLoaded(web, timeout: 14)
        if !ok && web.url == nil { return nil }
        if (try? await web.evaluateJavaScript(SiteAdapters.ageGateScript)) as? Int == 2 {
            _ = await waitLoaded(web, timeout: 4)
        }
        // Trigger lazy-loaded content.
        for _ in 0..<3 {
            _ = try? await web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); 1")
            try? await Task.sleep(nanoseconds: UInt64(settle / 3 * 1_000_000_000))
        }
        return try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
    }

    /// Opens one video's page and returns as soon as the page reveals its video file, instead of waiting
    /// for the whole page. Falls back to the page's HTML when no video shows up in time.
    func renderMedia(_ url: URL) async -> (video: CapturedVideo?, html: String?) {
        await acquire(.user)
        defer { release(.user) }
        let web = await open(url, media: true)
        defer { close(web) }
        let started = Date()
        while Date().timeIntervalSince(started) < 9 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = try? await web.evaluateJavaScript(SiteAdapters.ageGateScript)
            _ = try? await web.evaluateJavaScript(Self.playScript)
            if let first = await collect(web).first(where: { !Self.isAd($0.url) }) { return (first, nil) }
        }
        let html = try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        return (nil, html)
    }

    /// One video found on a page.
    struct CapturedVideo { let url: URL; let poster: URL?; let title: String }

    /// Opens a TikTok-style page off screen, swipes through its feed and collects every video it loads:
    /// `<video>` sources and video files the page requests. `onFound` gets each new batch right away.
    func captureVideos(_ url: URL, rounds: Int = 10, onFound: (([CapturedVideo]) -> Void)? = nil) async -> [CapturedVideo] {
        await acquire(.user)
        defer { release(.user) }
        let web = await open(url, media: true)
        defer { close(web) }

        var found: [CapturedVideo] = []
        var keys = Set<String>()
        func take(_ list: [CapturedVideo]) {
            var fresh: [CapturedVideo] = []
            for v in list where !Self.isAd(v.url) {
                if keys.insert(Self.videoKey(v.url)).inserted { fresh.append(v) }
            }
            if !fresh.isEmpty {
                found += fresh
                onFound?(fresh)
            }
        }
        // Collect while the page is still loading; many feeds show their first video early.
        let started = Date()
        while Date().timeIntervalSince(started) < 10, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await web.evaluateJavaScript(SiteAdapters.ageGateScript)
            _ = try? await web.evaluateJavaScript(Self.playScript)
            take(await collect(web))
            if !found.isEmpty && Date().timeIntervalSince(started) > 2.5 { break }
        }
        for _ in 0..<rounds where !Task.isCancelled {
            _ = try? await web.evaluateJavaScript(Self.swipeScript)
            try? await Task.sleep(nanoseconds: 800_000_000)
            take(await collect(web))
        }
        return found
    }

    private func collect(_ web: WKWebView) async -> [CapturedVideo] {
        guard let json = try? await web.evaluateJavaScript(Self.collectScript) as? String,
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return [] }
        return list.compactMap { v in
            guard let raw = v["u"], let u = URL(string: raw, relativeTo: web.url)?.absoluteURL,
                  u.scheme == "http" || u.scheme == "https" else { return nil }
            let poster = v["p"].flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: web.url)?.absoluteURL }
            return CapturedVideo(url: u, poster: poster, title: v["t"] ?? "")
        }
    }

    /// Pre-roll and tracking clips that pages load next to the real video.
    nonisolated static func isAd(_ u: URL) -> Bool {
        let s = u.absoluteString.lowercased()
        return ["/ads/", "doubleclick", "googlesyndication", "imasdk", "adserver", "/vast", "preroll", "pre-roll", "exoclick", "trafficjunky", "juicyads"]
            .contains { s.contains($0) }
    }

    /// HLS variants of one video share a folder; count them once.
    nonisolated static func videoKey(_ u: URL) -> String {
        u.pathExtension.lowercased() == "m3u8" ? (u.host ?? "") + u.deletingLastPathComponent().path : (u.host ?? "") + u.path
    }

    static let playScript = #"""
    (function(){
      document.querySelectorAll('video').forEach(function(v){ v.muted=true; v.preload='auto'; try{ var p=v.play(); if(p&&p.catch)p.catch(function(){}); }catch(e){} });
      var b=document.querySelector('.vjs-big-play-button,.ytp-large-play-button,.play-button,[class*=play-btn],[class*=playButton],[aria-label*=Play i]');
      if(b&&!window.__inuttClicked){ window.__inuttClicked=1; try{ b.click(); }catch(e){} }
      return 1;
    })()
    """#

    static let collectScript = #"""
    (function(){
      var out=[], seen={};
      function add(u,p,t){ if(!u||u.indexOf('blob:')===0||u.indexOf('data:')===0||seen[u])return; seen[u]=1; out.push({u:String(u),p:String(p||''),t:String(t||'')}); }
      document.querySelectorAll('video').forEach(function(v){
        var p=v.poster||v.getAttribute('data-poster')||'';
        var box=v.closest('article,li,section,[class*=item],[class*=card],[class*=reel],[class*=short],[class*=video],[class*=post]');
        var t=box&&box.innerText?box.innerText.trim().split('\n')[0].slice(0,140):'';
        add(v.currentSrc||v.src||v.getAttribute('data-src'),p,t);
        v.querySelectorAll('source').forEach(function(s){ add(s.src||s.getAttribute('data-src'),p,t); });
      });
      ['og:video:secure_url','og:video:url','og:video'].forEach(function(n){
        var m=document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"]');
        if(m&&/\.(mp4|m3u8|webm|mov)(\?|#|$)/i.test(m.content||'')) add(m.content,'','');
      });
      (performance.getEntriesByType('resource')||[]).forEach(function(e){
        var n=e.name; if(/\.(mp4|m3u8|webm|mov)(\?|#|$)/i.test(n)&&!/\.(ts|m4s)(\?|#|$)/i.test(n)) add(n,'','');
      });
      return JSON.stringify(out);
    })()
    """#

    static let swipeScript = #"""
    (function(){
      var h=window.innerHeight;
      document.querySelectorAll('*').forEach(function(e){
        var s=getComputedStyle(e);
        if((s.overflowY==='auto'||s.overflowY==='scroll')&&e.scrollHeight>e.clientHeight+50) e.scrollTop+=e.clientHeight||h;
      });
      window.scrollBy(0,h);
      document.querySelectorAll('video').forEach(function(v){ v.muted=true; var r=v.getBoundingClientRect(); if(r.top<h&&r.bottom>0){ try{ var p=v.play(); if(p&&p.catch)p.catch(function(){}); }catch(e){} } });
      return 1;
    })()
    """#

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
