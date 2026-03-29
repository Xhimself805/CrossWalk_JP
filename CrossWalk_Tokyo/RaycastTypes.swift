import Foundation
import RealityKit

/// Small struct to represent a raycast hit from the head anchor
/// Conforms to Equatable so arrays of RayHit can be compared (used by SwiftUI onChange)
struct RayHit: Equatable {
    var name: String?
    var distance: Float?
}
