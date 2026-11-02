import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreVideo
import ToolboxCore
import OSLog

/// Captures individual windows only while a switcher session requests them.
/// Images remain in a small, short-lived memory cache; nothing is saved to disk.
@MainActor final class WindowThumbnailProvider {
    private struct CachedImage {
        let image: NSImage
        let created: Date
        let maximumPixelSize: NSSize
        let backingScaleFactor: CGFloat
        let pixelBudget: Int
        let sourceFrame: CGRect?
        let pixelCount: Int
    }
    private struct CaptureJob {
        let id: WindowID
        let window: SCWindow
        let generation: UInt64
        let maximumPixelSize: NSSize
        let backingScaleFactor: CGFloat
        let candidateCount: Int
        let sourceFrame: CGRect?
    }

    private let limit = WindowThumbnailSizing.imageLimit
    private let lifetime: TimeInterval = 2
    private let logger = Logger(subsystem: "local.mactoolbox.app", category: "WindowThumbnail")
    private var generation: UInt64 = 0
    private var discovery: Task<Void, Never>?
    private var pending: [CaptureJob] = []
    // Count physical operations across cancelled sessions as well. A native
    // screenshot already submitted to macOS has no cancellation API.
    private var inFlight = 0
    private var cache: [WindowID: CachedImage] = [:]
    private var deliver: ((WindowID, NSImage) -> Void)?

    var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    init() {}

    func request(items: [SwitchableWindow], selected: WindowID?,
                 maximumPixelSize: NSSize = NSSize(width: 720, height: 448),
                 backingScaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 1,
                 update: @escaping (WindowID, NSImage) -> Void) {
        cancel()
        guard isSupported, isAuthorized,
              maximumPixelSize.width.isFinite, maximumPixelSize.height.isFinite,
              maximumPixelSize.width > 0, maximumPixelSize.height > 0 else {
            cache.removeAll()
            return
        }
        deliver = update
        let requestedGeneration = generation
        let screenScale = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
        let demand = NSSize(width: min(CGFloat(WindowThumbnailSizing.maximumWidth), maximumPixelSize.width),
                            height: min(CGFloat(WindowThumbnailSizing.maximumHeight), maximumPixelSize.height))
        // Icon-only/minimized entries do not consume the 24 capture slots.
        var ordered = items.filter { !$0.minimized && !$0.isWindowless && $0.id.pid != getpid() }
        if let selected, let index = ordered.firstIndex(where: { $0.id == selected }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let candidates = Array(ordered.prefix(limit))
        let valid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let pixelBudget = WindowThumbnailSizing.pixelsPerImage(candidateCount: candidates.count)
        let now = Date()
        cache = cache.filter { id, cached in
            guard let item = valid[id] else { return false }
            // A larger panel or a denser destination screen must upgrade an old
            // low-resolution capture, even during the short cache lifetime.
            return now.timeIntervalSince(cached.created) < lifetime &&
                cached.maximumPixelSize.width >= demand.width && cached.maximumPixelSize.height >= demand.height &&
                cached.backingScaleFactor == screenScale && cached.pixelBudget >= pixelBudget &&
                cached.pixelCount <= pixelBudget &&
                cached.sourceFrame == item.frame
        }
        evictOverflow()
        for item in candidates {
            if let cached = cache[item.id] { update(item.id, cached.image) }
        }
        let uncached = candidates.filter { cache[$0.id] == nil }
        guard !uncached.isEmpty else { return }

        discovery = Task { [weak self] in
            // Do not perform AX queries or shareable-content discovery in the
            // synchronous key-filter callback that opened the switcher.
            await Task.yield()
            guard let self, self.generation == requestedGeneration, !Task.isCancelled, self.isAuthorized else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard self.generation == requestedGeneration, !Task.isCancelled, self.isAuthorized else { return }
                for item in uncached {
                    await Task.yield()
                    guard self.generation == requestedGeneration, !Task.isCancelled, self.isAuthorized else { return }
                    guard let window = self.match(item, in: content.windows) else { continue }
                    self.pending.append(CaptureJob(id: item.id, window: window, generation: requestedGeneration,
                        maximumPixelSize: demand, backingScaleFactor: screenScale,
                        candidateCount: candidates.count, sourceFrame: item.frame))
                    self.pump()
                }
            } catch {
                // Permission can be revoked, a window can close, or an app may
                // prohibit capture. The caller's title/icon fallback stays intact.
            }
        }
    }

    func cancel() {
        generation &+= 1
        discovery?.cancel(); discovery = nil
        pending.removeAll()
        deliver = nil
    }

    func clearCache() {
        cancel()
        cache.removeAll()
    }

    private func pump() {
        guard #available(macOS 14, *) else { return }
        guard isAuthorized else { clearCache(); return }
        while inFlight < 2, !pending.isEmpty {
            let job = pending.removeFirst()
            guard job.generation == generation else { continue }
            inFlight += 1
            Task { [weak self] in
                let captured: (image: CGImage, logicalSize: NSSize)?
                do { captured = try await Self.capture(job) }
                catch {
                    captured = nil
                    if let self, job.generation == self.generation {
                        let failure = error as NSError
                        // Error descriptions can contain window metadata; keep
                        // only the system error identity and owning process.
                        self.logger.info("capture-failed pid=\(job.id.pid, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
                    }
                }
                guard let self else { return }
                self.inFlight -= 1
                if job.generation == self.generation, self.isAuthorized, let captured {
                    let image = captured.image
                    let pixelCount = image.width * image.height
                    let budget = WindowThumbnailSizing.pixelsPerImage(candidateCount: job.candidateCount)
                    // Enforce the actual result too, rather than trusting only
                    // requested SC configuration dimensions.
                    guard image.width <= WindowThumbnailSizing.maximumWidth,
                          image.height <= WindowThumbnailSizing.maximumHeight,
                          pixelCount <= budget else { self.pump(); return }
                    let thumbnail = NSImage(cgImage: image, size: captured.logicalSize)
                    self.cache[job.id] = CachedImage(image: thumbnail, created: Date(),
                        maximumPixelSize: job.maximumPixelSize, backingScaleFactor: job.backingScaleFactor,
                        pixelBudget: budget, sourceFrame: job.sourceFrame, pixelCount: pixelCount)
                    self.evictOverflow()
                    self.deliver?(job.id, thumbnail)
                    let residentPixels = self.cache.values.reduce(0) { $0 + $1.pixelCount }
                    self.logger.info("capture-completed pid=\(job.id.pid, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) cachePixels=\(residentPixels, privacy: .public)")
                } else if !self.isAuthorized {
                    self.clearCache()
                }
                self.pump()
            }
        }
    }

    @available(macOS 14, *)
    private static func capture(_ job: CaptureJob) async throws -> (image: CGImage, logicalSize: NSSize)? {
        let filter = SCContentFilter(desktopIndependentWindow: job.window)
        let contentSize = filter.contentRect.size
        let logicalSize = contentSize.width.isFinite && contentSize.height.isFinite && contentSize.width > 0 && contentSize.height > 0
            ? contentSize : job.window.frame.size
        let reportedScale = CGFloat(filter.pointPixelScale)
        let sourceScale = reportedScale.isFinite && reportedScale > 0 ? reportedScale : job.backingScaleFactor
        guard let dimensions = WindowThumbnailSizing.dimensions(sourcePointSize: logicalSize, sourceScale: sourceScale,
            maximumPixelSize: job.maximumPixelSize, candidateCount: job.candidateCount) else { return nil }
        let configuration = SCStreamConfiguration()
        // Fit source content directly to actual point-size × display-scale
        // demand. No fixed-size letterbox is baked into the captured image.
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // Keeping logical source points here makes Actual Size mean the native
        // window's point dimensions, including when the screens have different
        // backing scales. High-resolution pixels remain in the CGImage rep.
        return (image, logicalSize)
    }

    /// AX has no public window-number property. Match public SC metadata using
    /// the owner plus live AX identity evidence; never choose an arbitrary window.
    private func match(_ item: SwitchableWindow, in windows: [SCWindow]) -> SCWindow? {
        guard let element = item.element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.04)
        if attribute(element, kAXMinimizedAttribute) as? Bool == true { return nil }
        let title = attribute(element, kAXTitleAttribute) as? String
        // A desktop-independent window filter can capture offscreen and other-
        // Space windows. Onscreen status must not discard otherwise valid ones.
        let eligible = windows.filter { candidate in
            candidate.owningApplication?.processID == item.id.pid &&
            candidate.windowLayer == 0 &&
            candidate.frame.width > 1 && candidate.frame.height > 1
        }
        let candidates = eligible.map {
            WindowCaptureCandidate(id: $0.windowID, processID: item.id.pid, title: $0.title, frame: $0.frame)
        }
        // Chrome adds profile/incognito annotations to its AX title separately
        // from its capture title. Opt in only for the known Chrome application;
        // the matcher still requires a unique PID/frame match for this alias.
        let isChrome = item.app.bundleIdentifier == "com.google.Chrome"
        let titlePolicy: WindowCaptureTitlePolicy = isChrome
            ? .chromium(browserName: "Google Chrome") : .exact
        let windowFrame = frame(of: element)
        guard let id = WindowCaptureMatcher.match(candidates: candidates, processID: item.id.pid,
                                                 title: title, frame: windowFrame,
                                                 titlePolicy: titlePolicy) else {
            if isChrome {
                let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let titlePresent = !normalizedTitle.isEmpty
                let exactTitleCount = titlePresent ? candidates.filter {
                    $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
                }.count : 0
                let nearFrameCount = windowFrame == nil ? 0 : candidates.filter {
                    WindowCaptureMatcher.match(candidates: [$0], processID: item.id.pid,
                                               title: nil, frame: windowFrame) != nil
                }.count
                // Diagnose the failed stage without titles, URLs, or pixels.
                logger.info("match-failed pid=\(item.id.pid, privacy: .public) candidates=\(candidates.count, privacy: .public) axTitlePresent=\(titlePresent, privacy: .public) axFramePresent=\(windowFrame != nil, privacy: .public) nearFrameCount=\(nearFrameCount, privacy: .public) exactTitleCount=\(exactTitleCount, privacy: .public) compatibleMatch=false")
            }
            return nil
        }
        return eligible.first { $0.windowID == id }
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let axPosition = position as! AXValue
        let axSize = size as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize,
              AXValueGetValue(axPosition, .cgPoint, &point), AXValueGetValue(axSize, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 1, dimensions.height > 1 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func evictOverflow() {
        while (cache.count > limit || cache.values.reduce(0, { $0 + $1.pixelCount }) > WindowThumbnailSizing.maximumCachePixels),
              let oldest = cache.min(by: { $0.value.created < $1.value.created })?.key {
            cache.removeValue(forKey: oldest)
        }
    }
}
