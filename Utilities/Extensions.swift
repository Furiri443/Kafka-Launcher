import AVFoundation
import Combine
import CryptoKit
import SwiftUI
import WebKit

// MARK: - Extensions & Utilities

extension View {
    /// Liquid Glass card modifier for macOS Tahoe
    func liquidGlassCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.5),
                                .white.opacity(0.1),
                                .clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
    }

    /// Liquid Glass button style
    func liquidGlassButton(color: Color = .white) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(color.opacity(0.15))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                color.opacity(0.6),
                                color.opacity(0.1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: color.opacity(0.3), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Async Image with Cache

struct CachedAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url = url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                case .failure:
                    fallbackGradient
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    fallbackGradient
                }
            }
        } else {
            fallbackGradient
        }
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [.gray.opacity(0.3), .gray.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Looping Video Background

struct LoopingVideoBackground: View {
    let url: URL
    @StateObject private var controller: LoopingVideoController

    init(url: URL) {
        self.url = url
        _controller = StateObject(wrappedValue: LoopingVideoController(remoteURL: url))
    }

    var body: some View {
        Group {
            if controller.usesWebRenderer {
                LoopingVideoWebView(url: url) { state in
                    controller.handleWebPlaybackState(state)
                }
            } else if controller.canDisplay {
                LoopingVideoPlayerView(player: controller.player)
            }
        }
        .opacity(controller.canDisplay ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: controller.canDisplay)
        .allowsHitTesting(false)
        .onAppear { controller.play() }
        .onDisappear { controller.pause() }
        .id(url.absoluteString)
    }
}

@MainActor
private final class LoopingVideoController: ObservableObject {
    let player = AVPlayer()
    @Published var isReady = false
    @Published var canDisplay = false
    let usesWebRenderer: Bool

    private let candidateRemoteURLs: [URL]
    private var currentItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var webTimeoutTask: Task<Void, Never>?
    private var currentCandidateIndex = 0

    init(remoteURL: URL) {
        self.usesWebRenderer = remoteURL.pathExtension.lowercased() == "webm"
        self.candidateRemoteURLs = Self.makeCandidateURLs(for: remoteURL)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        if usesWebRenderer {
            scheduleWebTimeout(for: remoteURL)
        } else {
            loadTask = Task { await preparePlayer(at: 0) }
        }
    }

    deinit {
        statusObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        loadTask?.cancel()
        fallbackTask?.cancel()
        webTimeoutTask?.cancel()
        player.pause()
    }

    func play() {
        if usesWebRenderer {
            if !canDisplay {
                scheduleWebTimeout(for: candidateRemoteURLs[0])
            }
        } else {
            player.play()
        }
    }

    func pause() {
        if !usesWebRenderer {
            player.pause()
        }
    }

    func handleWebPlaybackState(_ state: WebPlaybackState) {
        switch state {
        case .ready:
            webTimeoutTask?.cancel()
            if !canDisplay {
                isReady = true
                canDisplay = true
            }
        case .failed:
            webTimeoutTask?.cancel()
            isReady = false
            canDisplay = false
        }
    }

    private func preparePlayer(at candidateIndex: Int) async {
        do {
            currentCandidateIndex = candidateIndex
            let remoteURL = candidateRemoteURLs[candidateIndex]
            let localURL = try await Self.cachedVideoURL(for: remoteURL)
            guard !Task.isCancelled else { return }

            statusObservation?.invalidate()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            fallbackTask?.cancel()

            let item = AVPlayerItem(url: localURL)
            currentItem = item
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output

            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.isReady = item.status == .readyToPlay
                    if item.status == .readyToPlay {
                        self.canDisplay = true
                        self.player.play()
                    }
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }

            player.replaceCurrentItem(with: item)
            scheduleFallbackProbe()
        } catch {
            let remoteURL = candidateRemoteURLs[candidateIndex]
            print("[BackgroundVideo] Failed to prepare video \(remoteURL): \(error)")
            await tryNextCandidate(after: candidateIndex)
        }
    }

    private func scheduleFallbackProbe() {
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            if !self.hasDecodedFrame() {
                self.player.pause()
                let failedURL = self.candidateRemoteURLs[self.currentCandidateIndex]
                print("[BackgroundVideo] No decoded frame for \(failedURL)")
                await self.tryNextCandidate(after: self.currentCandidateIndex)
            }
        }
    }

    private func tryNextCandidate(after candidateIndex: Int) async {
        let nextIndex = candidateIndex + 1
        guard nextIndex < candidateRemoteURLs.count else {
            isReady = false
            canDisplay = false
            return
        }
        isReady = false
        await preparePlayer(at: nextIndex)
    }

    private func hasDecodedFrame() -> Bool {
        guard let currentItem, let videoOutput else { return false }
        let itemTime = currentItem.currentTime()
        return videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
    }

    private func scheduleWebTimeout(for remoteURL: URL) {
        webTimeoutTask?.cancel()
        webTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !self.canDisplay else { return }
            self.isReady = false
            self.canDisplay = false
            print("[BackgroundVideo] Timed out waiting for playable web video \(remoteURL)")
        }
    }

    private static func makeCandidateURLs(for remoteURL: URL) -> [URL] {
        [remoteURL]
    }

    private static func cachedVideoURL(for remoteURL: URL) async throws -> URL {
        let fm = FileManager.default
        let cacheRoot = try fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("KafkaLauncher/background-videos", isDirectory: true)

        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let hash = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let localURL = cacheRoot.appendingPathComponent("\(hash).\(ext)")

        if fm.fileExists(atPath: localURL.path) {
            return localURL
        }

        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if fm.fileExists(atPath: localURL.path) {
            try? fm.removeItem(at: localURL)
        }
        try fm.moveItem(at: tempURL, to: localURL)
        return localURL
    }
}

private enum WebPlaybackState {
    case ready
    case failed
}

private struct LoopingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> LoopingVideoContainerView {
        let view = LoopingVideoContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: LoopingVideoContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class LoopingVideoContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct LoopingVideoWebView: NSViewRepresentable {
    let url: URL
    let onPlaybackStateChange: (WebPlaybackState) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.html(for: url), baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let target = url.absoluteString
        if context.coordinator.currentURL != target {
            context.coordinator.currentURL = target
            nsView.loadHTMLString(Self.html(for: url), baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: url.absoluteString, onPlaybackStateChange: onPlaybackStateChange)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
    }

    private static func html(for url: URL) -> String {
        let source = url.absoluteString
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: transparent;
            }
            video {
              position: fixed;
              inset: 0;
              width: 100vw;
              height: 100vh;
              object-fit: cover;
              background: transparent;
              opacity: 0;
              transition: opacity 160ms ease-in-out;
            }
            video.ready { opacity: 1; }
          </style>
        </head>
        <body>
          <video autoplay loop muted playsinline preload="auto">
            <source src="\(source)" type="video/webm">
          </video>
          <script>
            const post = (state) => {
              try {
                window.webkit.messageHandlers.backgroundVideoState.postMessage(state);
              } catch (_) {}
            };
            const video = document.querySelector("video");
            const markReady = () => {
              video.classList.add("ready");
              post("ready");
            };
            video.addEventListener("loadeddata", markReady, { once: true });
            video.addEventListener("canplay", markReady, { once: true });
            video.addEventListener("playing", markReady);
            video.addEventListener("error", () => post("failed"));
            setTimeout(() => {
              if (video.readyState < 2) {
                post("failed");
              }
            }, 5000);
            video.play().then(markReady).catch(() => post("failed"));
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "backgroundVideoState"
        var currentURL: String
        private let onPlaybackStateChange: (WebPlaybackState) -> Void

        init(currentURL: String, onPlaybackStateChange: @escaping (WebPlaybackState) -> Void) {
            self.currentURL = currentURL
            self.onPlaybackStateChange = onPlaybackStateChange
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageHandlerName else { return }
            switch message.body as? String {
            case "ready":
                onPlaybackStateChange(.ready)
            case "failed":
                onPlaybackStateChange(.failed)
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onPlaybackStateChange(.failed)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onPlaybackStateChange(.failed)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onPlaybackStateChange(.failed)
        }
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
