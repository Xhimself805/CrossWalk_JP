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

    // NEW: 6个方向的 IPv6 地址 (分别对应 0:前, 1:右前, 2:右后, 3:后, 4:左后, 5:左前)
    // 请将以下填入你 ESP32/真实硬件的 IPv6 地址。将它们改为 static 避免 @Observable 的 lazy 报错
    static let targetIPs: [String] = [
        "fd44:6728:f986:1:e434:b041:ba9e:9add", // Index 0 (Front) - 设置为真实测试节点
        "fd2f:77e5:42af:1:0000:0000:0000:0002", // Index 1 (Right-Front)
        "fd2f:77e5:42af:1:0000:0000:0000:0003", // Index 2 (Right-Back)
        "fd2f:77e5:42af:1:0000:0000:0000:0004", // Index 3 (Back)
        "fd2f:77e5:42af:1:0000:0000:0000:0005", // Index 4 (Left-Back)
        "fd2f:77e5:42af:1:0000:0000:0000:0006"  // Index 5 (Left-Front)
    ]
    static let targetPort: UInt16 = 61617
    
    // 记录每条射线的上一次发送的强度，避免0.1秒狂发相同的数据塞爆日志和网络
    private var lastSentIntensities: [Int] = Array(repeating: -1, count: 6)
    
    // 取消 lazy，直接使用静态变量初始化
    var udpClient = UDPClient(deviceConnections: AppModel.targetIPs, remotePort: AppModel.targetPort)
    
    /// 将 0-99 的强度单独发给某个固定的 IPv6 地址
    func sendIntensityToDevice(index: Int, intensity: Int) {
        guard index >= 0 && index < AppModel.targetIPs.count else { return }
        
        // 只有当强度发生变化时，才发送 UDP 和打印 Debug Log 避免刷屏
        if lastSentIntensities[index] != intensity {
            let previous = lastSentIntensities[index]
            lastSentIntensities[index] = intensity
            
            let ip = AppModel.targetIPs[index]
            udpClient.sendMessage(to: ip, message: String(intensity))
            
            // 更详细的 Debug Log
            if intensity > 0 {
                print("💥 [HIT!] Ray [\(index)] hit the cube! Changed from \(previous) to \(intensity). Sent to IP: \(ip)")
            } else {
                print("🟢 [CLEAR] Ray [\(index)] is clear. Changed from \(previous) to \(intensity). Sent to IP: \(ip)")
            }
        }
    }

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
