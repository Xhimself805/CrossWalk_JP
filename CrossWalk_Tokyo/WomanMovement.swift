import RealityKit
import Foundation // Add this import to use Timer

class WomanMovement {
    private var womanEntity: Entity
    private var timer: Timer?
    private var movingForward = true

    init(womanEntity: Entity) {
        self.womanEntity = womanEntity
    }

    func startWalking() {
        // Start a timer to move the woman forward and backward
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let currentPosition = self.womanEntity.position
            let movementStep: Float = 1

            if self.movingForward {
                self.womanEntity.position = SIMD3<Float>(currentPosition.x, currentPosition.y, currentPosition.z + movementStep)
                if currentPosition.z >= 200.0 { // Move forward until z = 20.0
                    self.movingForward = false
                }
            } else {
                self.womanEntity.position = SIMD3<Float>(currentPosition.x, currentPosition.y, currentPosition.z - movementStep)
                if currentPosition.z <= -200.0 { // Move backward until z = -20.0
                    self.movingForward = true
                }
            }
        }
    }

    func stopWalking() {
        timer?.invalidate()
        timer = nil
    }
}
