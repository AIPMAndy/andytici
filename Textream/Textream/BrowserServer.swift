//
//  BrowserServer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import Foundation
import Network

// MARK: - Browser State

struct BrowserState: Codable {
    // R42: nil = "words unchanged since the last broadcast; browser should
    // keep its local cache". The words array (~5–10 KB for a 1000-word
    // script) used to be re-encoded on every 10 Hz tick even when the user
    // hadn't switched pages. Now the server only includes it when the
    // content actually changes (page switch, source edit, or a fresh client
    // connection). Browser JS keeps `cachedWords` and falls back to it
    // whenever `s.words === null`.
    //
    // R60: `var` instead of `let` so broadcast() can populate it after the
    // cheap-signature early-return (the words-hash decision was previously
    // computed BEFORE that early-return, paying for 2-3 hashValue reads
    // + 5 multiplications per 10Hz tick even when the broadcast would be
    // dropped anyway).
    var words: [String]?
    let highlightedCharCount: Int
    let totalCharCount: Int
    // CGFloat (== Double on arm64) eliminates the per-tick
    // `(speechRecognizer?.audioLevels ?? []).map { Double($0) }` allocation
    // in broadcastCurrentState. JSONEncoder emits the same numeric byte
    // stream either way. (R37)
    let audioLevels: [CGFloat]
    let isListening: Bool
    let isDone: Bool
    let fontColor: String
    let cueColor: String
    let hasNextPage: Bool
    let isActive: Bool
    let highlightWords: Bool
    let lastSpokenText: String
}

// MARK: - Browser Server

class BrowserServer {
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var wsConnections: [NWConnection] = []
    private var broadcastTimer: Timer?

    // Content state
    private var words: [String] = []
    private var totalCharCount: Int = 0
    private var hasNextPage: Bool = false
    private weak var speechRecognizer: SpeechRecognizer?
    private var timerWordProgress: Double = 0
    private var contentActive: Bool = false
    // Prefix sum of (word.count + 1) for words[0..<i]: cachedCharOffsets[i] is the
    // char offset BEFORE word i. cachedCharOffsets.count = words.count + 1.
    // Lets charOffsetForWordProgress go from O(wholeWord) to O(1) per call;
    // the 10Hz broadcast timer otherwise re-walks 0..<wholeWord every tick.
    // Rebuilt only when words array changes (showContent / updateContent). (R32)
    private var cachedCharOffsets: [Int] = [0]
    // R58: per-word grapheme counts cached alongside the prefix sum. Without
    // this, the fractional branch in charOffsetForWordProgress does
    // `words[wholeWord].count` — an O(M) grapheme walk — twice per 10Hz
    // broadcast tick (called from broadcastCurrentState). Rebuild together
    // with cachedCharOffsets in rebuildCharOffsetCache.
    private var cachedWordCharCounts: [Int] = []
    // Cached JSONEncoder: JSONEncoder() carries a small amount of internal
    // state and allocates per call. With 10Hz broadcasting, caching shaves
    // 10 encoder allocations per second on the main thread. (R33)
    private let jsonEncoder = JSONEncoder()
    // Dedup encoded state: BrowserState carries the full `words: [String]`
    // and re-encodes every 10Hz tick. When audioLevels stay steady (no
    // speech, classic mode) the encoded bytes are identical; memcmp-ing
    // Data lets us skip the WS send loop. Aligned with DirectorServer. (R35)
    private var lastBroadcastState: Data?
    // R40: pre-encode cheap signature. The encode itself is the expensive
    // step (walks every String in `words` to produce JSON bytes). Comparing
    // a handful of cheap fields (Int + Bool + String + array tail) lets us
    // skip the encode entirely on idle ticks. When ASR is silent and the
    // user isn't scrolling, this saves ~10 full encodes/sec.
    private var lastSigCharCount: Int = -1
    private var lastSigIsDone: Bool = false
    private var lastSigIsListening: Bool = false
    private var lastSigLastSpoken: String = ""
    private var lastSigAudioCount: Int = -1
    private var lastSigAudioLast: CGFloat = 0
    // R42: track the words array hash so the server only includes `words`
    // in the encoded payload when the content actually changes (page switch,
    // source edit, fresh client connection). On steady 10Hz ticks during
    // ASR the words payload is omitted — the browser keeps `cachedWords`.
    private var lastBroadcastWordsHash: Int = 0

    private func cheapSignatureChanged(
        highlightedCharCount: Int, isDone: Bool, isListening: Bool,
        lastSpokenText: String, audioLevels: [CGFloat]
    ) -> Bool {
        if highlightedCharCount != lastSigCharCount { return true }
        if isDone != lastSigIsDone { return true }
        if isListening != lastSigIsListening { return true }
        if lastSpokenText != lastSigLastSpoken { return true }
        if audioLevels.count != lastSigAudioCount { return true }
        // Sample only the last sample — earlier samples change monotonically
        // during a burst but the trailing edge is enough to detect motion.
        if let tail = audioLevels.last, tail != lastSigAudioLast { return true }
        return false
    }

    /// Cheap content-hash for the words array. Mixes count with three
    /// sampling points (first, middle, last) so a tiny edit anywhere in
    /// the script flips the hash, while the cost stays O(1) regardless
    /// of script length. Used by R42 to decide whether the next
    /// broadcast needs to ship the words array or can leave it as `null`
    /// (the browser keeps its local cache). Worst-case collision only
    /// causes one extra full-state send — never a stale-cache bug, since
    /// the cheap pre-encode signature (R40) still guards byte-equality.
    /// (R42)
    private static func wordsHash(_ arr: [String]) -> Int {
        var h = arr.count
        h = h &* 31 &+ (arr.first?.hashValue ?? 0)
        h = h &* 31 &+ (arr.last?.hashValue ?? 0)
        if arr.count > 2 {
            h = h &* 31 &+ arr[arr.count / 2].hashValue
        }
        return h
    }

    var httpPort: UInt16 { NotchSettings.shared.browserServerPort }
    var wsPort: UInt16 { httpPort + 1 }
    var isRunning: Bool { httpListener != nil }
    var connectedClients: Int { wsConnections.count }

    // MARK: - Lifecycle

    func start() {
        stop()
        startHTTPListener()
        startWSListener()
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil

        httpListener?.cancel()
        httpListener = nil
        wsListener?.cancel()
        wsListener = nil

        for conn in wsConnections { conn.cancel() }
        wsConnections.removeAll()
        contentActive = false
    }

    // MARK: - Content Management

    func showContent(speechRecognizer: SpeechRecognizer, words: [String], totalCharCount: Int, hasNextPage: Bool) {
        self.speechRecognizer = speechRecognizer
        self.words = words
        self.totalCharCount = totalCharCount
        self.hasNextPage = hasNextPage
        self.timerWordProgress = 0
        self.contentActive = true
        rebuildCharOffsetCache()
        startBroadcasting()
    }

    func updateContent(words: [String], totalCharCount: Int, hasNextPage: Bool) {
        self.words = words
        self.totalCharCount = totalCharCount
        self.hasNextPage = hasNextPage
        self.timerWordProgress = 0
        rebuildCharOffsetCache()
    }

    func hideContent() {
        contentActive = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        broadcastInactive()
    }

    // MARK: - HTTP Server

    private func startHTTPListener() {
        guard let port = NWEndpoint.Port(rawValue: httpPort) else { return }
        do {
            httpListener = try NWListener(using: .tcp, on: port)
        } catch { return }

        httpListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.httpListener = nil }
        }
        httpListener?.newConnectionHandler = { [weak self] conn in
            self?.handleHTTPConnection(conn)
        }
        httpListener?.start(queue: .main)
    }

    private func handleHTTPConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            guard error == nil else { conn.cancel(); return }

            let response = self.buildHTTPResponse()
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func buildHTTPResponse() -> Data {
        let html = Self.generateHTML(wsPort: wsPort)
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    // MARK: - WebSocket Server

    private func startWSListener() {
        guard let port = NWEndpoint.Port(rawValue: wsPort) else { return }
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            wsListener = try NWListener(using: params, on: port)
        } catch { return }

        wsListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.wsListener = nil }
        }
        wsListener?.newConnectionHandler = { [weak self] conn in
            self?.handleWSConnection(conn)
        }
        wsListener?.start(queue: .main)
    }

    private func handleWSConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        wsConnections.append(conn)
        // R42: force the next broadcast to include the full words array,
        // so a freshly-connected client has something to render even if it
        // joins during a stable-tick interval. Setting the cached hash to
        // a sentinel (-1, guaranteed ≠ any real wordsHash result) makes
        // the next broadcastCurrentState's includeWords check return true.
        lastBroadcastWordsHash = -1
        receiveWSMessage(conn)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.wsConnections.removeAll { $0 === conn }
            default: break
            }
        }
    }

    private func receiveWSMessage(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            if error != nil { conn.cancel(); return }
            self?.receiveWSMessage(conn)
        }
    }

    // MARK: - Broadcasting

    private func startBroadcasting() {
        broadcastTimer?.invalidate()
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.broadcastCurrentState()
        }
    }

    private func broadcastCurrentState() {
        guard contentActive, !wsConnections.isEmpty else { return }

        // R77: cache singletons at the top of this 10 Hz function. Previously
        // read listeningMode once and fontColorPreset.cssColor + cueColorPreset
        // .cssColor once each per tick (3 reads × 10 Hz = 30 reads/sec). The
        // classic/silencePaused branches additionally read scrollSpeed (1 more
        // per tick in active modes). Hoisting deduplicates within the function
        // and keeps the function body free of inline @Observable access.
        let mode = NotchSettings.shared.listeningMode
        let speed = NotchSettings.shared.scrollSpeed
        let fontColor = NotchSettings.shared.fontColorPreset.cssColor
        let cueColor = NotchSettings.shared.cueColorPreset.cssColor

        let charCount: Int
        switch mode {
        case .wordTracking:
            // In word-tracking mode the script doesn't auto-scroll, so the
            // `scrollDone` early-stop is meaningless — skip the redundant
            // charOffsetForWordProgress() call (saves 1 O(1) prefix-sum
            // lookup per 100 ms tick × 10 Hz = 10 wasted lookups/sec). (R38)
            charCount = speechRecognizer?.recognizedCharCount ?? 0
        case .classic:
            // R53: cache the first prefix-sum lookup. When scrollDone is
            // true (end-of-script, common while speaker finishes) the
            // second lookup would return the same value — reuse it and
            // skip one O(1) array read + min() per 100 ms tick.
            let offsetBefore = charOffsetForWordProgress(timerWordProgress)
            let scrollDone = totalCharCount > 0 && offsetBefore >= totalCharCount
            if !scrollDone {
                timerWordProgress += speed * 0.1
                charCount = charOffsetForWordProgress(timerWordProgress)
            } else {
                charCount = offsetBefore
            }
        case .silencePaused:
            let offsetBefore = charOffsetForWordProgress(timerWordProgress)
            let scrollDone = totalCharCount > 0 && offsetBefore >= totalCharCount
            if !scrollDone && speechRecognizer?.isListening == true && (speechRecognizer?.isSpeaking ?? false) {
                timerWordProgress += speed * 0.1
                charCount = charOffsetForWordProgress(timerWordProgress)
            } else {
                charCount = offsetBefore
            }
        }

        let effective = min(charCount, totalCharCount)
        let rawDone = totalCharCount > 0 && effective >= totalCharCount
        // In classic/silence-paused modes on the last page, suppress Done so the
        // browser keeps showing the prompter text (speaker may still be talking).
        let isDone = rawDone && (mode == .wordTracking || hasNextPage)

        let highlightWords = mode == .wordTracking

        let state = BrowserState(
            words: nil, // R60: deferred — see broadcast(_:words:) for the include-words decision
            highlightedCharCount: effective,
            totalCharCount: totalCharCount,
            audioLevels: speechRecognizer?.audioLevels ?? [],
            isListening: speechRecognizer?.isListening ?? false,
            isDone: isDone,
            fontColor: fontColor,
            cueColor: cueColor,
            hasNextPage: hasNextPage,
            isActive: true,
            highlightWords: highlightWords,
            lastSpokenText: speechRecognizer?.lastSpokenText ?? ""
        )
        broadcast(state, words: words)
    }

    private func broadcastInactive() {
        // R42: force the next active broadcast to include the words array
        // (the browser's local cache may have been overwritten by a stale
        // tick, and on inactive→active transitions we want the first
        // active frame to render text). The `words: nil` here is fine —
        // `s.isActive === false` causes render() to return early before
        // touching `words`.
        lastBroadcastWordsHash = -1
        let state = BrowserState(
            words: nil, highlightedCharCount: 0, totalCharCount: 0,
            audioLevels: [], isListening: false, isDone: false,
            fontColor: "#ffffff", cueColor: "#ffffff", hasNextPage: false, isActive: false,
            highlightWords: true, lastSpokenText: ""
        )
        broadcast(state)
    }

    private func broadcast(_ state: BrowserState, words: [String]? = nil) {
        guard !wsConnections.isEmpty else { return }
        // R40: cheap pre-encode dedup. Skip the encoder entirely when no
        // user-visible field changed since the last tick.
        if !cheapSignatureChanged(
            highlightedCharCount: state.highlightedCharCount,
            isDone: state.isDone,
            isListening: state.isListening,
            lastSpokenText: state.lastSpokenText,
            audioLevels: state.audioLevels
        ) {
            return
        }
        // R60: resolve the include-words decision here (after the cheap-signature
        // early-return) so a stable-tick broadcast doesn't pay for Self.wordsHash
        // (2-3 cached hashValue reads + 5 multiplications per 10Hz tick). The
        // browser still gets a slim payload without `words` on stable ticks
        // because the hash matches and we leave state.words as nil.
        var resolvedState = state
        if let words, state.isActive {
            let currentWordsHash = Self.wordsHash(words)
            if currentWordsHash != lastBroadcastWordsHash {
                lastBroadcastWordsHash = currentWordsHash
                resolvedState.words = words
            }
        }
        guard let data = try? jsonEncoder.encode(resolvedState) else { return }
        // Skip broadcast if state hasn't changed (R35)
        if let last = lastBroadcastState, last == data {
            // Even though the encoder produced identical bytes, refresh the
            // cheap signature so we don't repeat the encode next tick.
            cacheSignature(resolvedState)
            return
        }
        lastBroadcastState = data
        cacheSignature(resolvedState)
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws", metadata: [meta])
        for conn in wsConnections {
            conn.send(content: data, contentContext: ctx, completion: .idempotent)
        }
    }

    private func cacheSignature(_ state: BrowserState) {
        lastSigCharCount = state.highlightedCharCount
        lastSigIsDone = state.isDone
        lastSigIsListening = state.isListening
        lastSigLastSpoken = state.lastSpokenText
        lastSigAudioCount = state.audioLevels.count
        lastSigAudioLast = state.audioLevels.last ?? 0
    }

    // MARK: - Helpers

    /// Rebuild the prefix-sum cache for `charOffsetForWordProgress`. O(N) once
    /// per words-change (showContent/updateContent), saves O(wholeWord) per
    /// 10Hz broadcast tick. (R32)
    private func rebuildCharOffsetCache() {
        var offsets = [Int]()
        offsets.reserveCapacity(words.count + 1)
        offsets.append(0)
        // R58: build per-word char count cache in the same pass so the
        // fractional branch in charOffsetForWordProgress can skip the
        // O(M) grapheme walk on every 10Hz tick.
        var charCounts = [Int]()
        charCounts.reserveCapacity(words.count)
        var acc = 0
        for word in words {
            let n = word.count
            charCounts.append(n)
            acc += n + 1
            offsets.append(acc)
        }
        cachedCharOffsets = offsets
        cachedWordCharCounts = charCounts
    }

    /// Convert fractional word progress into a char offset using the prefix-sum
    /// cache. O(1) lookup per call after a one-time O(N) build per words-change.
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let count = words.count
        guard count > 0 else { return 0 }
        let wholeWord = min(Int(progress), count)
        let frac = progress - Double(wholeWord)
        var offset = cachedCharOffsets[wholeWord]
        if wholeWord < count {
            // R58: O(1) read from cachedWordCharCounts instead of walking
            // words[wholeWord].count (O(M) graphemes) on every 10Hz tick.
            offset += Int(Double(cachedWordCharCounts[wholeWord]) * frac)
        }
        return min(offset, totalCharCount)
    }

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip != "127.0.0.1" else { continue }

            if name == "en0" || name == "en1" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }

    // MARK: - HTML Template

    static func generateHTML(wsPort: UInt16) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <title>Andy题词 · 远端提词</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{height:100%;overflow:hidden;background:#000;color:#fff;
          font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',system-ui,sans-serif}
        body{display:flex;flex-direction:column}

        /* Waiting */
        #waiting{flex:1;display:flex;flex-direction:column;align-items:center;
          justify-content:center;gap:16px}
        #waiting .icon{font-size:48px}
        #waiting .title{font-size:20px;font-weight:600;color:rgba(255,255,255,.6);
          animation:pulse 2s ease-in-out infinite}
        #waiting .sub{font-size:14px;color:rgba(255,255,255,.3);text-align:center;
          max-width:320px;line-height:1.5}
        #waiting .url{font-size:12px;color:rgba(255,255,255,.15);margin-top:8px;
          font-family:ui-monospace,monospace}
        @keyframes pulse{0%,100%{opacity:.6}50%{opacity:1}}

        /* Main */
        #main{display:none;flex-direction:column;height:100%}

        /* Prompter with fade mask */
        #prompter-wrap{flex:1;position:relative;overflow:hidden}
        #prompter-wrap::before,#prompter-wrap::after{
          content:'';position:absolute;left:0;right:0;z-index:2;pointer-events:none}
        #prompter-wrap::before{top:0;height:8%;
          background:linear-gradient(to bottom,#000,transparent)}
        #prompter-wrap::after{bottom:0;height:8%;
          background:linear-gradient(to top,#000,transparent)}
        #prompter{height:100%;overflow-y:auto;
          padding:20px max(40px,8%);
          -webkit-overflow-scrolling:touch;scroll-behavior:smooth}
        #prompter::-webkit-scrollbar{display:none}

        /* Text: match ExternalDisplayView font sizing: max(48, min(96, width/14)) */
        #text-container{
          font-size:clamp(48px,calc(100vw / 14),96px);
          font-weight:600;line-height:1.4;word-wrap:break-word}
        .w{display:inline;transition:color .12s ease}
        .w.ann{font-style:italic}

        /* Bottom bar — matches ExternalDisplayView layout */
        #bar{flex-shrink:0;padding:12px max(40px,8%) 40px;
          display:flex;align-items:center;gap:16px}
        #waveform{width:240px;height:32px;display:flex;align-items:center;gap:1.5px}
        .wf{width:3px;background:rgba(255,255,255,.15);border-radius:1.5px;
          min-height:3px;transition:height .08s ease,background .12s ease;align-self:center}
        #spoken{font-size:18px;font-weight:500;color:rgba(255,255,255,.5);
          flex:1;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;
          direction:rtl;text-align:left}
        #mic-btn{width:40px;height:40px;border-radius:50%;
          background:rgba(255,255,255,.15);display:flex;align-items:center;
          justify-content:center;flex-shrink:0}
        #mic-dot{width:10px;height:10px;border-radius:50%;
          background:#facc15;opacity:0;transition:opacity .2s}
        #mic-dot.on{opacity:1}

        /* Done */
        #done{display:none;flex-direction:column;align-items:center;
          justify-content:center;height:100%;gap:12px}
        #done .check{width:64px;height:64px;border-radius:50%;background:#22c55e;
          display:flex;align-items:center;justify-content:center;
          font-size:32px;color:#fff;animation:pop .4s ease}
        #done .label{font-size:32px;font-weight:700;color:#fff;
          animation:fadeUp .4s ease .1s both}
        @keyframes pop{0%{transform:scale(0);opacity:0}
          60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
        @keyframes fadeUp{0%{opacity:0;transform:translateY(8px)}
          100%{opacity:1;transform:translateY(0)}}

        @media(max-width:768px){
          #prompter{padding:16px 5%}
          #bar{padding:10px 5% 20px}
          #waveform{width:160px;height:28px}
          #text-container{font-size:clamp(28px,calc(100vw / 10),60px)}
        }
        </style>
        </head>
        <body>

        <div id="waiting">
          <div class="icon">📡</div>
          <div class="title">等待 Andy题词…</div>
          <div class="sub">在 App 里开始朗读，这里就会同步显示</div>
          <div class="url" id="conn-status">连接中…</div>
        </div>

        <div id="main">
          <div id="prompter-wrap">
            <div id="prompter"><div id="text-container"></div></div>
          </div>
          <div id="bar">
            <div id="waveform"></div>
            <div id="spoken"></div>
            <div id="mic-btn"><div id="mic-dot"></div></div>
          </div>
        </div>

        <div id="done">
          <div class="check">✓</div>
          <div class="label">完成！</div>
        </div>

        <script>
        const WSP=\(wsPort),host=location.hostname;
        let ws,rt,prevWordKey='',scrollTgt=null,cachedWords=[];

        /* ---- helpers ---- */

        // Parse a CSS color into [r,g,b]. Memoized by source string: parseColor
        // runs 2× per 10Hz tick (fc + cc) but fc/cc only change when the
        // user adjusts a color preset in Settings, which is rare. The Map
        // cache drops ~20 parseColor calls/sec on a steady script.
        const _colorCache=new Map();
        function parseColor(c){
          const cached=_colorCache.get(c);
          if(cached)return cached;
          let v;
          if(c.startsWith('#')){
            const parts=c.length===4
              ?[c[1]+c[1],c[2]+c[2],c[3]+c[3]]
              :[c.slice(1,3),c.slice(3,5),c.slice(5,7)];
            v=parts.map(h=>parseInt(h,16));
          } else {
            const m=c.match(/(\\d+)/g);
            v=m?m.slice(0,3).map(Number):[255,255,255];
          }
          _colorCache.set(c,v);
          return v;
        }
        function rgba(rgb,a){return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';}

        // Detect annotation words: [bracket] or emoji-only (no letters/digits)
        function isAnnotation(w){
          if(w.startsWith('[')&&w.endsWith(']'))return true;
          return!/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/.test(w);
        }

        // Count letters+digits in a word
        function letterCount(w){
          let n=0;for(const ch of w)if(/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/.test(ch))n++;
          return Math.max(1,n);
        }

        /* ---- DOM refs (R55: cache once, render() reads via closure) ---- */
        // render() runs at 10 Hz and previously called document.getElementById
        // 8 times per tick (waiting/main/done/text-container/prompter/waveform
        // /spoken/mic-dot). At 10 Hz that's ~80 DOM lookups/sec on the
        // browser's main thread for elements that never change. Cache them
        // once at script load so render() just reads the closure binding.
        // WS event handlers (onopen/onclose) also reuse connStatus from here.
        const connStatus=document.getElementById('conn-status'),
              waitingEl=document.getElementById('waiting'),
              mainEl=document.getElementById('main'),
              doneEl=document.getElementById('done'),
              textContainerEl=document.getElementById('text-container'),
              prompterEl=document.getElementById('prompter'),
              waveformEl=document.getElementById('waveform'),
              spokenEl=document.getElementById('spoken'),
              micDotEl=document.getElementById('mic-dot');

        /* ---- connection ---- */

        function connect(){
          ws=new WebSocket('ws://'+host+':'+WSP);
          ws.onopen=()=>{clearTimeout(rt);
            connStatus.textContent='Connected';};
          ws.onmessage=e=>{try{render(JSON.parse(e.data))}catch(x){console.error(x)}};
          ws.onclose=()=>{
            connStatus.textContent='Reconnecting…';
            rt=setTimeout(connect,1500);};
          ws.onerror=()=>{ws.close()};
        }

        /* ---- render ---- */

        function render(s){
          // R66: cache the three-way display mode (waiting/main/done) so we
          // only write 3 inline `style.display` values on a transition, not
          // on every 10 Hz tick. The previous code wrote all three every
          // frame regardless of whether anything had changed — each write
          // triggers style-invalidation in the browser (~30 invalidations/sec
          // for the steady state where isActive=true and isDone=false).
          // prevMode = -1 sentinel guarantees the first frame always writes.
          const mode=!s.isActive?0:(s.isDone?1:2);
          if(mode!==prevMode){
            prevMode=mode;
            waitingEl.style.display=mode===0?'flex':'none';
            mainEl.style.display=mode===2?'flex':'none';
            doneEl.style.display=mode===1?'flex':'none';
          }
          if(mode!==2)return;

          const c=textContainerEl,
                // R42: server only ships the (potentially large) `words`
                // array when the content actually changes (page switch,
                // source edit, fresh client connection). On every other
                // tick `s.words === null` and we keep using the cached
                // array from the previous full payload. Falls back to []
                // only on the very first frame if the server somehow
                // sent a null before any full state — shouldn't happen
                // because `handleWSConnection` forces includeWords on the
                // next tick.
                // R66: simpler null-check. `s.words` is either an array (truthy,
                // including `[]`) or null (falsy after JSON.parse), so the
                // ternary below collapses the original
                // `s.words!==null&&s.words!==undefined` double-check + the
                // `cachedWords` assignment into one expression — same
                // semantics, ~2 ops lighter per 10Hz tick.
                words=(s.words?(cachedWords=s.words):cachedWords),
                fc=s.fontColor||'#ffffff',
                cc=s.cueColor||fc,
                rgb=parseColor(fc),
                crgb=parseColor(cc),
                hlWords=s.highlightWords!==false,
                hcc=s.highlightedCharCount||0;

          // R43: hoist the five unique rgba() strings out of the per-word
          // loop. The previous code called rgba(crgb, 0.5/0.2/0.4) and
          // rgba(rgb, 0.3/0.6) inside the highlight branches, allocating
          // 4–5 short-lived strings per word per frame. At 1000 words ×
          // 10 Hz that's ~50 000 string allocations/sec on the browser's
          // main thread. Allocating once per frame drops it to 5.
          const annLit=rgba(crgb,0.5),
                annDim=rgba(crgb,0.2),
                annPlain=rgba(crgb,0.4),
                readDim=rgba(rgb,0.3),
                curMed=rgba(rgb,0.6);

          // Rebuild spans only when words change
          const wordKey=words.length+'|'+(words[0]||'')+'|'+(words[words.length-1]||'');
          if(wordKey!==prevWordKey){
            c.innerHTML='';
            let cp=0;
            for(let i=0;i<words.length;i++){
              const wd=words[i],ann=isAnnotation(wd);
              const sp=document.createElement('span');
              sp.className=ann?'w ann':'w';
              // R44: store charOffset/length/letterCount/annFlag as direct
              // number/bool properties on the span instead of in `dataset`.
              // `dataset.*` coerces everything to strings, forcing the hot
              // render loops below to `parseInt(d.s)` / `parseInt(d.l)` /
              // `parseInt(d.lc)` for every word on every 10 Hz frame —
              // ~3000 parseInt calls/sec for a 1000-word script. Direct
              // numeric properties skip the string round-trip and the parse.
              sp.s=cp;
              sp.l=wd.length;
              sp.lc=letterCount(wd);
              sp.a=ann;
              // R49: cache `ce` = charOffset + (annotation ? letterCount : length).
              // The hot render loops below originally recomputed
              // `litCount = min(wLen, max(0, hcc - charOff))` and then checked
              // `litCount >= lc` to determine "fully lit." Both loops collapse
              // to a single `hcc >= sp.ce` (or `hcc < sp.ce` in the nextIdx
              // search). Saves ~3 conditional ops per span × 2 loops × 10 Hz
              // × N spans (~60k ops/sec on a 1000-word script).
              sp.ce=cp + (ann ? sp.lc : sp.l);
              // R45: per-span cache for (color, underline). The hot
              // render loop walks every word on every 10 Hz tick; most
              // words keep the same (color, underline) across many
              // consecutive frames once ASR has passed them. Skipping
              // the four style.* writes when the tuple is unchanged
              // drops ~99 % of per-frame style mutations on a stable
              // script, and the browser skips style-invalidation work
              // for unchanged inline styles.
              sp._c='';sp._u=false;
              sp.textContent=wd+' ';
              c.appendChild(sp);
              cp+=wd.length+1;
            }
            prevWordKey=wordKey;
          }

          // R65: hoist `spans` + length out of both loops. `c.children` is the
          // same HTMLCollection on both passes, and `length` is touched per
          // iteration otherwise — both add a property read per word × per frame.
          const spans=c.children;
          const nSpans=spans.length;

          // Find the next-word index (first non-fully-lit non-annotation)
          let nextIdx=-1;
          if(hlWords){
            for(let i=0;i<nSpans;i++){
              const sp=spans[i];
              if(sp.a)continue;
              // R49: skip the min/max arithmetic. `litCount < lc` reduces to
              // `hcc < ce` where ce = charOff + (annotation ? lc : wLen).
              // For non-annotation wLen==lc so ce = charOff+wLen; for annotation
              // wLen > lc but litCount is still clamped by hcc-charOff vs lc,
              // so ce = charOff+lc is the exact threshold either way.
              if(hcc<sp.ce){nextIdx=i;break}
            }
          }

          // Color each word to match native WordFlowLayout
          scrollTgt=null;
          for(let i=0;i<nSpans;i++){
            const sp=spans[i];
            const ann=sp.a;
            // R49: skip the min/max arithmetic for `litCount`. `isFullyLit`
            // becomes a single comparison against the cached `ce`.
            const isFullyLit=hcc>=sp.ce;
            // R65: the previous `isCurrent` formula had a second clause
            // `(charsInto>=0 && !isFullyLit && !ann)` that's provably
            // unreachable. For i < nextIdx the word is fully lit → !isFullyLit
            // is false. For i > nextIdx, sp.s[i] > sp.ce[nextIdx] > hcc so
            // charsInto = hcc - sp.s[i] < 0. The only true case is
            // `i === nextIdx`, so the second clause is dead code AND it
            // forces an extra `hcc - sp.s` subtraction per word per frame.
            const isCurrent=i===nextIdx;

            let color,underline=false;

            if(!hlWords){
              // Classic / silence-paused: uniform color, no per-word highlight
              color=ann?annPlain:fc;
            } else if(ann){
              // Annotation: cue color with varying opacity
              color=isFullyLit?annLit:annDim;
            } else if(isFullyLit){
              // Already read: dimmed
              color=readDim;
            } else if(isCurrent){
              // Current / next word: medium + underline
              color=curMed;
              underline=true;
            } else {
              // Unread: full brightness
              color=fc;
            }

            // R45: skip the four style.* writes when (color, underline) haven't
            // changed since the previous frame. For a stable script most
            // words keep the same tuple across many frames once ASR has
            // passed them — ~99 % of per-frame style mutations drop, and
            // the browser skips its style-invalidation work for unchanged
            // inline styles. Initial sp._c='' / sp._u=false are guaranteed
            // ≠ any real value so the first frame after a page switch
            // still applies styles.
            if(sp._c!==color||sp._u!==underline){
              sp.style.color=color;
              sp.style.textDecoration=underline?'underline':'none';
              sp.style.textDecorationColor=underline?color:'';
              sp.style.textUnderlineOffset=underline?'4px':'';
              sp._c=color;sp._u=underline;
            }

            // Track the active word for scrolling
            if(isCurrent||(!scrollTgt&&isFullyLit)){
              scrollTgt=sp;
            }
          }

          // Auto-scroll: keep active word centered.
          // R64: scrollTgt changes only when the active word advances (every
          // few frames at most). The previous code called
          // scrollTgt.getBoundingClientRect() + prompterEl.getBoundingClientRect()
          // on every 10Hz tick — both force a layout flush, which is the most
          // expensive DOM operation in the browser. Cache the rect keyed on
          // scrollTgt element identity; only re-measure when the active word
          // changes (≈ once per word, not per frame). A user-initiated scroll
          // invalidates the cache so manual scroll auto-recenters on the next
          // tick.
          if(scrollTgt){
            if(scrollTgt!==lastScrollTgtEl||!lastScrollTgtRect){
              const pr=prompterEl.getBoundingClientRect();
              const r=scrollTgt.getBoundingClientRect();
              lastScrollTgtEl=scrollTgt;
              lastScrollTgtRect=r;
              lastPrompterRect=pr;
            }
            const r=lastScrollTgtRect,pr=lastPrompterRect,
                  mid=pr.top+pr.height*0.4;
            if(r.top>mid+40||r.bottom<pr.top)
              scrollTgt.scrollIntoView({behavior:'smooth',block:'center'});
          }

          // Waveform with progress coloring (matches native AudioWaveformProgressView)
          const wf=waveformEl,
                lv=s.audioLevels||[],
                // R65: hoist lv.length + the barCount-1 reciprocal out of
                // the per-bar loop. lv.length was read every iteration to
                // bounds-check `i<lv.length`; `i/(barCount-1)` was a
                // division per bar per frame even though the divisor is
                // constant within the frame.
                lvLen=lv.length,
                pct=s.totalCharCount>0?s.highlightedCharCount/s.totalCharCount:0;
          while(wf.children.length<lvLen){
            const b=document.createElement('div');b.className='wf';
            // R46: init style fingerprint cache on bars created mid-session.
            b._h='';b._bg='';
            wf.appendChild(b)}
          const barCount=wf.children.length,
                invBarRange=barCount>1?1/(barCount-1):0;
          for(let i=0;i<barCount;i++){
            const l=i<lvLen?lv[i]:0;
            const barProgress=i*invBarRange;
            const isLit=barProgress<=pct;
            // R46: skip the two style.* writes when (height, background)
            // haven't changed since the previous frame. For stable audio
            // (silence, steady tone, last frame before a peak) most bars
            // hold the same tuple across many frames — the same skip
            // pattern as the per-span _c/_u cache.
            const h=Math.max(3,l*32)+'px',
                  bg=isLit?'rgba(250,204,21,0.9)':'rgba(255,255,255,0.15)';
            const bar=wf.children[i];
            if(bar._h!==h||bar._bg!==bg){
              bar.style.height=h;
              bar.style.background=bg;
              bar._h=h;bar._bg=bg;
            }
          }

          // Last spoken text (word-tracking mode only)
          // R55: spokenEl comes from the script-scope cache (see DOM refs
          // block above), no per-tick getElementById.
          if(hlWords&&s.lastSpokenText){
            // R61: gate split+slice+join behind a lastSpokenText-change
            // check. The previous code recomputed the 5-word tail on every
            // 10 Hz tick (split allocates Array, slice(-5) allocates Array,
            // join allocates String) even when lastSpokenText hadn't
            // changed — common in word-tracking mode where ASR partials
            // come at ~1 Hz but render() runs at 10 Hz. For a 5-minute
            // session that's ~3000 wasted allocations, dropped to 1 per
            // partial (the cache check below).
            if(s.lastSpokenText!==prevLastSpokenSrc){
              const tail=s.lastSpokenText.split(' ').slice(-5).join(' ');
              spokenEl.textContent=tail;
              prevSpoken=tail;prevSpokenHl=true;
              prevLastSpokenSrc=s.lastSpokenText;
            }
          } else if(prevSpoken!==''||prevSpokenHl!==false){
            spokenEl.textContent='';
            prevSpoken='';prevSpokenHl=false;
            prevLastSpokenSrc='';
          }

          // Mic indicator
          // R66: cache isListening — the previous code called
          // micDotEl.classList.toggle('on', !!s.isListening) every tick even
          // when isListening hadn't changed. classList.toggle on a stable
          // class still walks classList.contains + may call add/remove;
          // guarding it behind a boolean cache drops it to once per actual
          // listening transition (typically 2 transitions per session).
          const listening=!!s.isListening;
          if(listening!==prevMicOn){
            prevMicOn=listening;
            micDotEl.classList.toggle('on',listening);
          }
        }

        // Init waveform bars (R46: cache per-bar style fingerprint so
        // render() can skip unchanged (height, background) writes).
        const wfInit=waveformEl;
        for(let i=0;i<30;i++){const b=document.createElement('div');
          b.className='wf';b.style.height='2px';b._h='';b._bg='';wfInit.appendChild(b)}

        // R46: spoken-text cache so we can skip textContent writes when
        // s.lastSpokenText (or hlWords) didn't change this tick.
        // R61: prevLastSpokenSrc caches the *input* string so render() can
        // skip the split/slice/join on stable ticks (see tail block above).
        let prevSpoken='',prevSpokenHl=false;
        let prevLastSpokenSrc='';
        // R66: prevMode sentinel (-1) is set the first time render() runs so
        // the initial frame still writes the three style.display values. After
        // that, transitions are the only thing that writes them — drops to
        // ~0 style-invalidation events/sec on a steady session.
        let prevMode=-1,prevMicOn=false;
        // R64: scroll-target rect cache. scrollTgt is reassigned to the same
        // span for many consecutive frames (the active word doesn't change
        // every tick), so caching its getBoundingClientRect() avoids forcing
        // a layout flush on every 10Hz frame. Invalidated on user scroll
        // (below) so manual drag-to-scroll auto-recovers.
        let lastScrollTgtEl=null,lastScrollTgtRect=null,lastPrompterRect=null;
        prompterEl.addEventListener('scroll',()=>{lastScrollTgtRect=null});

        connect();
        </script>
        </body>
        </html>
        """
    }
}
