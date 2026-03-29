//
//  AppModel.swift
//  CrossWalk_Tokyo
//
//  Created by JLiu on 10/12/25.
//

import SwiftUI
import ARKit
import QuartzCore
import simd

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // MARK: - User world position tracking
    private let arkitSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var trackingTask: Task<Void, Never>?

    var userWorldPosition: SIMD3<Float>?

    func startWorldPositionTracking() {
        guard WorldTrackingProvider.isSupported else {
            print("World tracking is not supported on this device.")
            return
        }

        guard trackingTask == nil else { return }

        trackingTask = Task {
            do {
                try await arkitSession.run([worldTracking])

                while !Task.isCancelled {
                    if let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                        let transform = deviceAnchor.originFromAnchorTransform
                        userWorldPosition = SIMD3<Float>(
                            transform.columns.3.x,
                            transform.columns.3.y,
                            transform.columns.3.z
                        )
                    }

                    try? await Task.sleep(for: .milliseconds(33))
                }
            } catch {
                print("Failed to start world position tracking: \(error)")
            }
        }
    }

    func stopWorldPositionTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        arkitSession.stop()
    }
}
