import Combine
import CoreMotion
import SwiftUI
import UIKit

struct RailwayBackgroundParallaxFilter {
    static let maximumHorizontalTranslation: CGFloat = 12
    static let maximumVerticalTranslation: CGFloat = 10

    private static let maximumAngle = 0.18
    private static let deadZone = 0.006
    private static let dampingTimeConstant = 0.18

    private(set) var translation = CGSize.zero
    private var lastTimestamp: TimeInterval?

    init(translation: CGSize = .zero) {
        self.translation = translation
    }

    mutating func update(
        horizontalAngle: Double,
        verticalAngle: Double,
        timestamp: TimeInterval
    ) -> CGSize {
        let target = CGSize(
            width: -normalized(horizontalAngle) * Self.maximumHorizontalTranslation,
            height: -normalized(verticalAngle) * Self.maximumVerticalTranslation
        )
        let elapsed = lastTimestamp.map { min(max(timestamp - $0, 1.0 / 240.0), 0.1) } ?? 1.0 / 60.0
        let response = 1 - exp(-elapsed / Self.dampingTimeConstant)
        translation.width += (target.width - translation.width) * response
        translation.height += (target.height - translation.height) * response
        lastTimestamp = timestamp
        return translation
    }

    private func normalized(_ angle: Double) -> CGFloat {
        let magnitude = abs(angle)
        guard magnitude > Self.deadZone else { return 0 }
        let adjusted = min((magnitude - Self.deadZone) / (Self.maximumAngle - Self.deadZone), 1)
        return CGFloat(angle.sign == .minus ? -adjusted : adjusted)
    }
}

private final class RailwayBackgroundMotionProcessor: @unchecked Sendable {
    private let orientation: UIInterfaceOrientation
    private var referenceAttitude: CMAttitude?
    private var filter: RailwayBackgroundParallaxFilter

    init(orientation: UIInterfaceOrientation, initialTranslation: CGSize) {
        self.orientation = orientation
        filter = RailwayBackgroundParallaxFilter(translation: initialTranslation)
    }

    func translation(for motion: CMDeviceMotion) -> CGSize? {
        guard let relativeAttitude = motion.attitude.copy() as? CMAttitude else { return nil }
        if referenceAttitude == nil {
            referenceAttitude = motion.attitude.copy() as? CMAttitude
        }
        guard let referenceAttitude else { return nil }
        relativeAttitude.multiply(byInverseOf: referenceAttitude)

        let angles: (horizontal: Double, vertical: Double)
        switch orientation {
        case .portraitUpsideDown:
            angles = (-relativeAttitude.roll, -relativeAttitude.pitch)
        case .landscapeLeft:
            angles = (-relativeAttitude.pitch, relativeAttitude.roll)
        case .landscapeRight:
            angles = (relativeAttitude.pitch, -relativeAttitude.roll)
        default:
            angles = (relativeAttitude.roll, relativeAttitude.pitch)
        }

        return filter.update(
            horizontalAngle: angles.horizontal,
            verticalAngle: angles.vertical,
            timestamp: motion.timestamp
        )
    }
}

@MainActor
final class RailwayBackgroundMotionModel: ObservableObject {
    static let shared = RailwayBackgroundMotionModel()

    @Published private(set) var translation = CGSize.zero

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.skynolimit.train-track.railway-background-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var activeViews: Set<UUID> = []
    private var orientation: UIInterfaceOrientation = .portrait
    private var generation = UUID()

    private init() {
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    }

    func activate(viewID: UUID, orientation: UIInterfaceOrientation) {
        let wasInactive = activeViews.isEmpty
        activeViews.insert(viewID)
        if self.orientation != orientation {
            self.orientation = orientation
            if !wasInactive {
                restartUpdates()
                return
            }
        }
        if wasInactive {
            startUpdates()
        }
    }

    func deactivate(viewID: UUID) {
        activeViews.remove(viewID)
        guard activeViews.isEmpty else { return }
        stopUpdates()
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard self.orientation != orientation else { return }
        self.orientation = orientation
        guard !activeViews.isEmpty else { return }
        restartUpdates()
    }

    private func restartUpdates() {
        stopUpdates(centresImage: false)
        startUpdates()
    }

    private func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        guard availableFrames.contains(.xArbitraryZVertical) else { return }

        generation = UUID()
        let currentGeneration = generation
        let processor = RailwayBackgroundMotionProcessor(
            orientation: orientation,
            initialTranslation: translation
        )
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: motionQueue
        ) { [weak self] motion, _ in
            guard let motion, let nextTranslation = processor.translation(for: motion) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.translation = nextTranslation
            }
        }
    }

    private func stopUpdates(centresImage: Bool = true) {
        generation = UUID()
        motionManager.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        guard centresImage else { return }
        withAnimation(.easeOut(duration: 0.45)) {
            translation = .zero
        }
    }
}
