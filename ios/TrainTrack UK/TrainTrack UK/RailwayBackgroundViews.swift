import CryptoKit
import SwiftUI
import UIKit

actor RailwayBackgroundImageCache {
    static let shared = RailwayBackgroundImageCache()

    private static let maximumDownloadBytes = 6 * 1_024 * 1_024
    private static let diskCapacity = 50 * 1_024 * 1_024
    private let cacheDirectory: URL
    private let session: URLSession
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(
        cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("railway-backgrounds", isDirectory: true),
        session: URLSession? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    func image(for asset: RailwayBackgroundAsset, apiBaseURL: String) async -> UIImage? {
        if let image = images.object(forKey: asset.sha256 as NSString) { return image }
        if let task = inFlight[asset.sha256] { return await task.value }
        let task = Task<UIImage?, Never> { [cacheDirectory, session] in
            await Self.loadImage(
                asset: asset,
                apiBaseURL: apiBaseURL,
                cacheDirectory: cacheDirectory,
                session: session
            )
        }
        inFlight[asset.sha256] = task
        let image = await task.value
        inFlight[asset.sha256] = nil
        if let image {
            images.setObject(
                image,
                forKey: asset.sha256 as NSString,
                cost: max(asset.width * asset.height * 4, 1)
            )
        }
        return image
    }

    func prune(keeping hashes: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let values = files.compactMap { url -> (URL, String, Int, Date)? in
            guard ["webp", "jpg"].contains(url.pathExtension),
                  let resource = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return (
                url,
                url.deletingPathExtension().lastPathComponent,
                resource.fileSize ?? 0,
                resource.contentModificationDate ?? .distantPast
            )
        }
        var totalSize = values.reduce(0) { $0 + $1.2 }
        guard totalSize > Self.diskCapacity else { return }
        for file in values.filter({ !hashes.contains($0.1) }).sorted(by: { $0.3 < $1.3 }) {
            guard totalSize > Self.diskCapacity else { break }
            if (try? FileManager.default.removeItem(at: file.0)) != nil {
                totalSize -= file.2
                images.removeObject(forKey: file.1 as NSString)
            }
        }
    }

    private nonisolated static func loadImage(
        asset: RailwayBackgroundAsset,
        apiBaseURL: String,
        cacheDirectory: URL,
        session: URLSession
    ) async -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(asset.sha256).\(asset.cacheFileExtension)")
        if let data = try? Data(contentsOf: fileURL), validate(data: data, asset: asset),
           let image = displayImage(from: data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return image
        }
        guard let remoteURL = asset.remoteURL(apiBaseURL: apiBaseURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: remoteURL)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  responseContentTypeIsValid(http.mimeType, asset: asset),
                  validate(data: data, asset: asset),
                  let image = displayImage(from: data) else { return nil }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return image
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            debugLog("🖼️ [RailwayBackground] Image download failed: \(error)")
            return nil
        }
    }

    private nonisolated static func validate(data: Data, asset: RailwayBackgroundAsset) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumDownloadBytes,
              let image = UIImage(data: data) else { return false }
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        guard let byteSize = asset.byteSize,
              data.count == byteSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            return false
        }
        return width == asset.width && height == asset.height
    }

    private nonisolated static func responseContentTypeIsValid(
        _ mimeType: String?,
        asset: RailwayBackgroundAsset
    ) -> Bool {
        mimeType?.lowercased() == "image/webp"
    }

    private nonisolated static func displayImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

private struct RailwayBackgroundLoadedImage: View {
    let asset: RailwayBackgroundAsset?
    let contentMode: ContentMode
    let focalFill: Bool

    @State private var remoteImage: UIImage?

    var body: some View {
        GeometryReader { proxy in
            if let remoteImage, let asset {
                if focalFill {
                    focalImage(remoteImage, asset: asset, size: proxy.size)
                } else {
                    Image(uiImage: remoteImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                Color(.systemBackground)
            }
        }
        .task(id: "\(ApiHostPreference.currentBaseURL)|\(asset?.sha256 ?? "fallback")") {
            remoteImage = nil
            guard let asset else { return }
            let image = await RailwayBackgroundImageCache.shared.image(
                for: asset,
                apiBaseURL: ApiHostPreference.currentBaseURL
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { remoteImage = image }
        }
    }

    private func focalImage(_ image: UIImage, asset: RailwayBackgroundAsset, size: CGSize) -> some View {
        let sourceWidth = max(CGFloat(asset.width), 1)
        let sourceHeight = max(CGFloat(asset.height), 1)
        let scale = max(size.width / sourceWidth, size.height / sourceHeight)
        let renderedWidth = sourceWidth * scale
        let renderedHeight = sourceHeight * scale
        let xOffset = (renderedWidth - size.width) * (0.5 - CGFloat(asset.focalPoint.x))
        let yOffset = (renderedHeight - size.height) * (0.5 - CGFloat(asset.focalPoint.y))
        return Image(uiImage: image)
            .resizable()
            .frame(width: renderedWidth, height: renderedHeight)
            .offset(x: xOffset, y: yOffset)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

struct RailwayBackgroundBackdrop: View {
    @EnvironmentObject private var store: RailwayBackgroundStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = RailwayBackgroundMotionModel.shared
    @State private var isVisible = false
    @State private var motionViewID = UUID()

    var body: some View {
        ZStack {
            RailwayBackgroundLoadedImage(asset: store.selectedAsset, contentMode: .fill, focalFill: true)
                .scaleEffect(motionIsEnabled ? 1.08 : 1)
                .offset(motionIsEnabled ? motion.translation : .zero)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: motionIsEnabled)

            Color.black.opacity(store.selectedAsset?.scrimOpacity ?? 0.34)
        }
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .onAppear {
                isVisible = true
                updateMotionActivity()
            }
            .onDisappear {
                isVisible = false
                updateMotionActivity()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateMotionActivity()
            }
            .onChange(of: scenePhase) { _, _ in
                updateMotionActivity()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                guard motionIsEnabled else { return }
                motion.updateOrientation(currentInterfaceOrientation)
            }
    }

    private var motionIsEnabled: Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
    }

    private func updateMotionActivity() {
        if motionIsEnabled {
            motion.activate(viewID: motionViewID, orientation: currentInterfaceOrientation)
        } else {
            motion.deactivate(viewID: motionViewID)
        }
    }
}

struct RailwayBackgroundSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(.white.opacity(0.88))
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
    }
}

private struct RailwayBackgroundInfoButton: View {
    let asset: RailwayBackgroundAsset?
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: "photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background {
                    if reduceTransparency {
                        Circle().fill(.black.opacity(0.9))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    Circle().stroke(.white.opacity(0.55), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("View background photo")
        .accessibilityValue(asset?.attributionText ?? "Fallback railway photograph")
        .accessibilityHint("Opens the photo full screen with image details")
    }
}

private struct RailwayBackgroundHiddenPreferenceKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct RailwayBackgroundChromeModifier: ViewModifier {
    let showsInfoButton: Bool
    @EnvironmentObject private var store: RailwayBackgroundStore
    @Environment(\.horizontalTabSwipePresentation) private var swipePresentation
    @Environment(\.isActiveHorizontalTabSwipePage) private var isActiveSwipePage
    @State private var isViewerPresented = false
    @State private var isHidden = false

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background {
                if !isHidden {
                    StationaryRailwayBackground(
                        presentation: swipePresentation,
                        tracksSwipe: isActiveSwipePage
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isHidden, showsInfoButton {
                        RailwayBackgroundInfoButton(asset: store.selectedAsset) {
                            isViewerPresented = true
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $isViewerPresented) {
                RailwayBackgroundViewer(asset: store.selectedAsset)
            }
            .onPreferenceChange(RailwayBackgroundHiddenPreferenceKey.self) { isHidden = $0 }
    }
}

private struct StationaryRailwayBackground: View {
    let presentation: HorizontalTabSwipePresentation?
    let tracksSwipe: Bool

    var body: some View {
        RailwayBackgroundBackdrop()
            .offset(x: tracksSwipe ? -(presentation?.offset ?? 0) : 0)
    }
}

extension View {
    func railwayBackgroundPOC(showsInfoButton: Bool = true) -> some View {
        modifier(RailwayBackgroundChromeModifier(showsInfoButton: showsInfoButton))
    }

    func hidesRailwayBackgroundChrome(_ isHidden: Bool = true) -> some View {
        preference(key: RailwayBackgroundHiddenPreferenceKey.self, value: isHidden)
    }
}

private struct RailwayBackgroundViewer: View {
    let asset: RailwayBackgroundAsset?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.045).ignoresSafeArea()
            RailwayBackgroundZoomableImage(asset: asset)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close photo")
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
                if let attributionText = asset?.attributionText,
                   let sourceURL = asset?.unsplashSourceURL {
                    Link(destination: sourceURL) {
                        Text(attributionText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                    }
                    .accessibilityHint("Opens this photograph on Unsplash")
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

}

private struct RailwayBackgroundZoomableImage: View {
    let asset: RailwayBackgroundAsset?

    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var transientScale: CGFloat = 1
    @GestureState private var transientTranslation = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let displayedScale = clampedScale(scale * transientScale)
            let displayedOffset = boundedOffset(
                CGSize(
                    width: offset.width + transientTranslation.width,
                    height: offset.height + transientTranslation.height
                ),
                within: proxy.size,
                scale: displayedScale
            )

            RailwayBackgroundLoadedImage(asset: asset, contentMode: .fit, focalFill: false)
                .scaleEffect(displayedScale)
                .offset(displayedOffset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    magnifyGesture(within: proxy.size)
                        .simultaneously(with: dragGesture(within: proxy.size))
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                        offset = .zero
                    }
                }
                .accessibilityLabel("Background photograph")
                .accessibilityHint("Pinch to zoom or drag to move around the photograph")
        }
        .ignoresSafeArea()
        .clipped()
    }

    private func magnifyGesture(within size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($transientScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let newScale = clampedScale(scale * value.magnification)
                scale = newScale
                offset = newScale == 1
                    ? .zero
                    : boundedOffset(offset, within: size, scale: newScale)
            }
    }

    private func dragGesture(within size: CGSize) -> some Gesture {
        DragGesture()
            .updating($transientTranslation) { value, state, _ in
                guard scale > 1 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard scale > 1 else {
                    offset = .zero
                    return
                }
                offset = boundedOffset(
                    CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    ),
                    within: size,
                    scale: scale
                )
            }
    }

    private func clampedScale(_ proposedScale: CGFloat) -> CGFloat {
        min(max(proposedScale, 1), 5)
    }

    private func boundedOffset(_ proposedOffset: CGSize, within size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1 else { return .zero }
        let maximumX = size.width * (scale - 1) / 2
        let maximumY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }
}
