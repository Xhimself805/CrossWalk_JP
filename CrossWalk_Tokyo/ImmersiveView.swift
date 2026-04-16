import SwiftUI
import RealityKit
import RealityKitContent
import UIKit
import simd
import ARKit
import os
import Combine

// MARK: - Helpers: simd_float4x4 extensions
extension simd_float4x4 {
    var position: SIMD3<Float> {
        let t = columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    var forward: SIMD3<Float> {
        let z = columns.2
        return normalize(SIMD3<Float>(-z.x, -z.y, -z.z))
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

// MARK: - ImmersiveView
struct ImmersiveView: View {
    @Environment(AppModel.self) var appModel

    // anchors & entities
    @State private var rootAnchorRef: AnchorEntity?
    @State private var headAnchor: AnchorEntity?
    @State private var manEntity: Entity?

    @State private var headTextEntity: ModelEntity?
    @State private var lastHeadText: String = ""

    @State private var arkitSession = ARKitSession()
    @State private var worldTracking = WorldTrackingProvider()
    @State private var handTracking = HandTrackingProvider()
    @State private var handTrackingTask: Task<Void, Never>?
    @State private var rightHandIsTracked: Bool = false
    @State private var rightHandPosition: SIMD3<Float> = .zero
    @State private var rightHandForward: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    @State private var rightHandIsFist: Bool = false
    @State private var rightHandRawFist: Bool = false
    @State private var rightHandRawFistChangedAt: CFTimeInterval = 0

    // GUI state (single source of truth for displayed world pose)
    @State private var guiWorldPosition: SIMD3<Float> = .zero
    @State private var guiOrientationDegrees: SIMD3<Float> = .zero

    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    @State private var lastPrintedAt: CFTimeInterval = 0
    @State private var lastStatusPrintedAt: CFTimeInterval = 0
    @State private var isWorldTrackingRunning: Bool = false
    @State private var didLogHeadTextMissing: Bool = false
    @State private var updateTick: Int = 0

    // 将 Unity-like obstacle detection params（ObsSectorState） 和相关的废弃变量统统删除。
    // 但是保留我们需要用到的常数：
    private let farDetectionRadius: Float = 5.0
    private let nearDetectionRadius: Float = 1.0
    // 恢复为你需要的 20 条高密度射线
    private let raysPerSector: Int = 20
    // Obstacle groups:
    // - Legacy old obstacles: REMOVED intentionally.
    // - Active obstacles: only three Ped_Sim objects.
    private let obstacleNames: Set<String> = [
        "LongObstacle_0",
        "LongObstacle_1",
        "LongObstacle_2"
    ]

    private let logger = Logger(subsystem: "flavinlab.CrossWalk-Tokyo", category: "WorldTracking")

    // NEW: 雷达射线探测常数 (修改为 30 米)
    private let manForwardRayLength: Float = 30.0
    // Arm-cane proxy ray (for blind-cane style interaction)
    private let armCaneRayLength: Float = 2.2
    private let armCaneHeight: Float = 1.0
    private let armCaneForwardOffset: Float = 0.10
    private let armCaneDownwardBias: Float = 0.65
    private let rightHandRaisedThresholdY: Float = 1.25
    private let fistPressDebounceSeconds: CFTimeInterval = 0.12
    private let fistReleaseDebounceSeconds: CFTimeInterval = 0.08

    // Legacy wandering obstacles removed on purpose.

    // Ped_Sim bridge (no ROS): drives long moving obstacles
    @State private var pedSimBridge = PedestrianSimBridge()
    @State private var hasSpawnedPedSimLongObjects: Bool = false
    private let pedSimLongObjectCount: Int = 3
    private let pedSimLongObjectSpacing: Float = 6.0
    @State private var candidatePathEntities: [Entity] = []
    @State private var debugRayEntities: [ModelEntity] = []
    private var debugRayLength: Float { manForwardRayLength }
    private let debugRayThickness: Float = 0.009
    private let enableDebugRayRendering: Bool = false

    // NEW: 保存7个状态的数组，0 为绿，1 为红
    @State private var hudIndicatorStates: [Int] = Array(repeating: 0, count: 7)
    // 直接映射：将扇区结果映射到 HUD 外圈索引（1...6）。
    // 按要求：先水平翻转，再左右翻转（组合后等价于整体 180° 重映射）。
    private let sectorToHUDIndex: [Int] = [6, 5, 4, 3, 2, 1]

    var body: some View {
        ZStack {
            RealityView { content in
                setupRealityContent(content)
            } // !!! 将 update 闭包完全删除，因为在内部更改 State 是非法的 !!!
            .ignoresSafeArea()

            // 将状态数组传给 3D HUD
            GUIOverlay(targetEntity: $manEntity, manRotationAngle: .constant(0), hudStates: $hudIndicatorStates)
            CountdownOverlay()
        }
        .ignoresSafeArea()
        // 统一在主频率 Timer 里更新逻辑
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            // Ped_Sim logic only: move the three long obstacles.
            pedSimBridge.stepSimulation(dt: 0.1)

            // Treat user pose as Jackal input to solver and draw possible paths.
            if updateTick % 2 == 0 {
                updateSolverInputFromUserPose()
                drawCandidatePathsOnGround()
            }
            
            updateWorldTrackingAndEntities()
            // 删除了多余的引擎调用: DetectObstaclesWithRayCast()
            detectForwardCubeHit()
            updateTick &+= 1
        }
        .task {
            appModel.startWorldPositionTracking()

            #if !targetEnvironment(simulator)
            if !isRunningInPreview {
                do {
                    arkitSession = ARKitSession()
                    worldTracking = WorldTrackingProvider()
                    handTracking = HandTrackingProvider()

                    var providers: [any DataProvider] = [worldTracking]
                    if HandTrackingProvider.isSupported {
                        providers.append(handTracking)
                    }

                    try await arkitSession.run(providers)
                    isWorldTrackingRunning = true
                    logger.debug("ARKitSession started. WorldTrackingProvider is running.")

                    if HandTrackingProvider.isSupported {
                        startHandTrackingUpdates()
                    }
                } catch {
                    isWorldTrackingRunning = false
                    logger.error("Failed to start world tracking: \(error.localizedDescription)")
                }
            } else {
                isWorldTrackingRunning = false
                logger.debug("Skipped world tracking in Preview.")
            }
            #else
            isWorldTrackingRunning = false
            logger.debug("Skipped world tracking in Simulator.")
            #endif
        }
        .onDisappear {
            appModel.stopWorldPositionTracking()
            headTextEntity = nil
            clearCandidatePathEntities()
            for ray in debugRayEntities {
                ray.removeFromParent()
            }
            debugRayEntities.removeAll(keepingCapacity: false)
            handTrackingTask?.cancel()
            handTrackingTask = nil
            rightHandIsTracked = false
            #if !targetEnvironment(simulator)
            if !isRunningInPreview {
                arkitSession.stop()
            }
            #endif
            isWorldTrackingRunning = false
        }
    }

    private func setupRealityContent(_ content: RealityViewContent) {
        let rootAnchor = AnchorEntity(world: matrix_identity_float4x4)
        content.add(rootAnchor)
        self.rootAnchorRef = rootAnchor

        let head = AnchorEntity(.head)
        content.add(head)
        self.headAnchor = head

        let textEntity = makeInitialHeadTextEntity()
        head.addChild(textEntity)

        DispatchQueue.main.async {
            self.headTextEntity = textEntity
            self.lastHeadText = "Thinking..."
        }

        Task { @MainActor in
            await loadInitialScene(into: rootAnchor)
        }
    }

    private func makeInitialHeadTextEntity() -> ModelEntity {
        let initialText = "Thinking..."
        let initialMesh = MeshResource.generateText(
            initialText,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.03, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let initialMaterial = UnlitMaterial(color: .white)
        let textEntity = ModelEntity(mesh: initialMesh, materials: [initialMaterial])
        textEntity.name = "HeadWorldText"
        textEntity.position = SIMD3<Float>(0, 0.05, -0.7)
        textEntity.scale = SIMD3<Float>(repeating: 1.0)
        return textEntity
    }

    @MainActor
    private func loadInitialScene(into rootAnchor: AnchorEntity) async {
        do {
            let crossTokyoEntity = try await Entity.load(named: "Crossing_Tokyo")

            let mySpawnOffsetX: Float = 0.0
            let mySpawnOffsetZ: Float = 15.0
            crossTokyoEntity.position = SIMD3<Float>(-mySpawnOffsetX, 5.95, -mySpawnOffsetZ)
            rootAnchor.addChild(crossTokyoEntity)

            if !hasSpawnedPedSimLongObjects {
                pedSimBridge.reset()
                for i in 0..<pedSimLongObjectCount {
                    let longObject = try await Entity.load(named: "Cube")
                    let id = "LongObstacle_\(i)"
                    longObject.name = id
                    longObject.scale = SIMD3<Float>(1.5, 10.2, 1.5)

                    let xPos = Float(i - 1) * pedSimLongObjectSpacing
                    let startPos = SIMD3<Float>(xPos, 0.75, -30.0 - Float(i) * 4.0)
                    longObject.position = startPos
                    longObject.generateCollisionShapes(recursive: true)

                    if let modelEntity = longObject as? ModelEntity,
                       var mc = modelEntity.components[ModelComponent.self] as? ModelComponent {
                        mc.materials = [SimpleMaterial(color: .purple, isMetallic: false)]
                        modelEntity.components[ModelComponent.self] = mc
                    }

                    rootAnchor.addChild(longObject)

                    let destination = SIMD3<Float>(-xPos * 0.8, startPos.y, 18.0 + Float(i) * 2.0)
                    pedSimBridge.addAgent(
                        id: id,
                        entity: longObject,
                        startPosition: startPos,
                        destination: destination
                    )
                }

                hasSpawnedPedSimLongObjects = true
            }

            let lightEntity = Entity()
            var lightComponent = DirectionalLightComponent()
            lightComponent.intensity = 1000
            lightComponent.color = .white
            lightEntity.components[DirectionalLightComponent.self] = lightComponent
            lightEntity.orientation = simd_quatf(angle: -.pi / 4, axis: SIMD3<Float>(1, 0, 0))
            rootAnchor.addChild(lightEntity)
        } catch {
            print("Error loading entities: \(error)")
        }
    }

    // MARK: - State Logic

    private func updateWorldTrackingAndEntities() {
        // 更新你看到的文字坐标 和 HUD
        guard let headEntity = headTextEntity else { return }

        #if !targetEnvironment(simulator)
        guard isWorldTrackingRunning, !isRunningInPreview else { return }
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }

        let transformMatrix = deviceAnchor.originFromAnchorTransform
        let p = SIMD3<Float>(transformMatrix.columns.3.x, transformMatrix.columns.3.y, transformMatrix.columns.3.z)

        let q = Transform(matrix: transformMatrix).rotation
        let qw = q.real
        let qx = q.imag.x
        let qy = q.imag.y
        let qz = q.imag.z

        let sinrCosp = 2 * (qw * qx + qy * qz)
        let cosrCosp = 1 - 2 * (qx * qx + qy * qy)
        let roll = atan2(sinrCosp, cosrCosp)

        let sinp = 2 * (qw * qy - qz * qx)
        let pitch = abs(sinp) >= 1 ? (sinp >= 0 ? Float.pi / 2 : -Float.pi / 2) : asin(sinp)

        let sinyCosp = 2 * (qw * qz + qx * qy)
        let cosyCosp = 1 - 2 * (qy * qy + qz * qz)
        let yaw = atan2(sinyCosp, cosyCosp)

        let rad2deg: Float = 180 / .pi
        let o = SIMD3<Float>(yaw * rad2deg, pitch * rad2deg, roll * rad2deg)

        guiWorldPosition = p
        guiOrientationDegrees = o

        // 【性能优化】: 限制 3D 原生网格文字的刷新频率。每 5 个周期(0.5秒)才生成一次新的 3D 字体网格
        if updateTick % 5 == 0 {
            // 使用换行符 `\n` 将坐标分行显示，更整洁清晰
            let newText = String(
                format: "World Coordinate:\nX: %.3f  Y: %.3f  Z: %.3f\nYaw: %.1f  Pitch: %.1f  Roll: %.1f",
                p.x, p.y, p.z, o.x, o.y, o.z
            )

            // 只在发生变化时更新网格，以节省性能
            if newText != lastHeadText {
                lastHeadText = newText
                let mesh = MeshResource.generateText(
                    newText,
                    extrusionDepth: 0.001,
                    font: .systemFont(ofSize: 0.03, weight: .semibold), // 与上方保持一致大小
                    containerFrame: .zero,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
                headEntity.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .white)])
            }
        }
        #endif
    }

    private func stateColor(_ s: Int) -> Color {
        switch s {
        case 4: return Color(red: 0.5, green: 0.0, blue: 0.5) // purple
        case 3: return Color.orange
        case 2: return Color.red
        case 1: return Color.yellow
        default: return Color.green
        }
    }

    // Legacy wandering movement removed intentionally.

    private func updateSolverInputFromUserPose() {
        #if targetEnvironment(simulator)
        let pos = SIMD3<Float>(0, 0, 0)
        let yaw: Float = 0
        pedSimBridge.updateEgoInput(position: pos, headingYaw: yaw, speed: 1.2)
        #else
        guard isWorldTrackingRunning,
              let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let m = deviceAnchor.originFromAnchorTransform
        let pos = SIMD3<Float>(m.columns.3.x, 0.0, m.columns.3.z)

        let forward = normalize(SIMD3<Float>(-m.columns.2.x, 0, -m.columns.2.z))
        let yaw = atan2(forward.x, forward.z)

        pedSimBridge.updateEgoInput(position: pos, headingYaw: yaw, speed: 1.2)
        #endif
    }

    private func drawCandidatePathsOnGround() {
        guard let root = rootAnchorRef else { return }

        clearCandidatePathEntities()

        let paths = pedSimBridge.solveCandidatePaths()
        let colors: [UIColor] = [.systemTeal, .systemGreen, .systemOrange]

        for (pathIndex, path) in paths.enumerated() {
            let color = colors[pathIndex % colors.count]
            for point in path {
                let mesh = MeshResource.generateSphere(radius: 0.04)
                let mat = UnlitMaterial(color: color)
                let marker = ModelEntity(mesh: mesh, materials: [mat])
                marker.position = point
                marker.name = "CandidatePath_\(pathIndex)"
                root.addChild(marker)
                candidatePathEntities.append(marker)
            }
        }
    }

    private func clearCandidatePathEntities() {
        for entity in candidatePathEntities {
            entity.removeFromParent()
        }
        candidatePathEntities.removeAll(keepingCapacity: false)
    }

    // 原本在这里有一整块多达上百行的 private func DetectObstaclesWithRayCast() { ... }
    // 请将那整个函数完完全全地删掉！！！

    private func detectForwardCubeHit() {
        guard let root = rootAnchorRef else { return }
        if enableDebugRayRendering {
            ensureDebugRayEntities(root: root)
        } else if !debugRayEntities.isEmpty {
            for ray in debugRayEntities {
                ray.removeFromParent()
            }
            debugRayEntities.removeAll(keepingCapacity: false)
        }

        // 默认初始化7个球为绿灯(0)
        var newStates = Array(repeating: 0, count: 7)
        var sectorDebugStates = Array(repeating: 0, count: 6)

        // 读取世界的起始点与核心朝向
        #if targetEnvironment(simulator)
        let origin = SIMD3<Float>(0, 1.2, 0)
        let lowerOrigin = SIMD3<Float>(0, 0.2, 0) // 更改为 0.2 米
        let baseForward = SIMD3<Float>(0, 0, -1)
        #else
        guard isWorldTrackingRunning, let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }

        let transformMatrix = deviceAnchor.originFromAnchorTransform
        let devicePos = SIMD3<Float>(transformMatrix.columns.3.x, transformMatrix.columns.3.y, transformMatrix.columns.3.z)
        let forward = normalize(SIMD3<Float>(-transformMatrix.columns.2.x, -transformMatrix.columns.2.y, -transformMatrix.columns.2.z))
        
        // 1. 锁死射线发射的高度为胸口 1.2 米，和低层 0.2 米
        let origin = SIMD3<Float>(devicePos.x, 1.2, devicePos.z)
        let lowerOrigin = SIMD3<Float>(devicePos.x, 0.2, devicePos.z)
        
        // 2. 抹除俯仰角：将视线的前方向量投影到水平面 (Y设为0) 并重新归一化
        var flatForward = SIMD3<Float>(forward.x, 0, forward.z)
        if length(flatForward) > 0.001 {
            flatForward = normalize(flatForward)
        } else {
            flatForward = SIMD3<Float>(0, 0, -1) // 极低概率垂直看地面时的防错处理
        }
        let baseForward = flatForward
        #endif

        // 循环发射 6 个扇区（每扇区 60°）
        // 分组定义：第1组从正前方开始，顺时针 60° 为该组覆盖范围；之后每转 60° 一组。
        let sectorSpan: Float = .pi / 3.0
        let raysInSector = max(raysPerSector, 2)

        for i in 0..<6 {
            // 当前扇区起始角度：0(正前) -> 顺时针方向为负角度。
            let sectorStartAngle = -Float(i) * sectorSpan
            var sectorHit = false
            
            // 在扇区内遍历发射多条射线
            for j in 0..<raysInSector {
                // 扇区内部均匀采样：从扇区起点扫到扇区终点（顺时针 60°）
                let t = Float(j) / Float(raysInSector - 1)
                let angle = sectorStartAngle - t * sectorSpan
                
                let rot = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                let dir = rot.act(baseForward)

                var hitCube = false

                // NOTE:
                // Use `.all` instead of `.nearest` so we don't miss LongObstacle_*
                // when a non-target entity appears as the nearest hit.
                let hitsLower = root.scene?.raycast(origin: lowerOrigin, direction: dir, length: manForwardRayLength, query: .all) ?? []
                for hit in hitsLower {
                    if isPedSimObstacleEntity(hit.entity) {
                        hitCube = true
                        break
                    }
                    let hitName = hit.entity.name
                    if hitName.contains("Crossing_Tokyo") { continue }
                }

                // 只有底层的打到了，才发射同位置的高层射线
                if hitCube {
                    sectorHit = true
                    break
                }
            }

            // --- 单个扇区所有的射线扫描完毕 ---

            // 左前方扇区（i == 5）：
            // 当“右手举起 + 握拳(代理判定)”成立时，改由右手射线控制该点；松开恢复原逻辑。
            if i == 5, shouldUseRightHandOverrideForLeftFront() {
                sectorHit = detectArmCaneHit(root: root)
            }

            // HUD 规则：无碰撞=绿(0)，有碰撞=红(1)
            let intensity = sectorHit ? 99 : 0
            let hudIndex = sectorToHUDIndex[i]
            newStates[hudIndex] = sectorHit ? 1 : 0
            sectorDebugStates[i] = sectorHit ? 1 : 0

            // 发送 UDP 消息：仅发送代表该扇区整体的信号
            appModel.sendIntensityToDevice(index: i, intensity: intensity)
        }

        if enableDebugRayRendering {
            updateDebugRayVisuals(
                origin: lowerOrigin,
                baseForward: baseForward,
                sectorSpan: sectorSpan,
                states: sectorDebugStates
            )
        }

        // Center HUD (index 0): arm-cane ray hit state.
        newStates[0] = detectArmCaneHit(root: root) ? 1 : 0

        // 把最新的 6 个方向判定立刻同步给界面 HUD
        hudIndicatorStates = newStates
    }

    /// Right-arm cane ray based on tracked right-hand pose.
    /// No head-direction coupling: if right hand is not tracked, cane ray is disabled.
    private func detectArmCaneHit(root: AnchorEntity) -> Bool {
        guard rightHandIsTracked else { return false }

        var handForward = rightHandForward
        if simd_length(handForward) > 0.0001 {
            handForward = simd_normalize(handForward)
        } else {
            handForward = SIMD3<Float>(0, 0, -1)
        }

        let caneOrigin = SIMD3<Float>(rightHandPosition.x, armCaneHeight, rightHandPosition.z)
            + handForward * armCaneForwardOffset
        let caneDirection = simd_normalize(handForward + SIMD3<Float>(0, -armCaneDownwardBias, 0))
        let hits = root.scene?.raycast(
            origin: caneOrigin,
            direction: caneDirection,
            length: armCaneRayLength,
            query: .all
        ) ?? []

        for hit in hits {
            if isPedSimObstacleEntity(hit.entity) {
                return true
            }
        }
        return false
    }

    /// Gesture gate for hand override.
    private func shouldUseRightHandOverrideForLeftFront() -> Bool {
        guard rightHandIsTracked else { return false }
        let isRaised = rightHandPosition.y >= rightHandRaisedThresholdY
        return isRaised && rightHandIsFist
    }

    private func updateRightHandFistDebounced(rawFist: Bool) {
        let now = CACurrentMediaTime()

        if rightHandRawFist != rawFist {
            rightHandRawFist = rawFist
            rightHandRawFistChangedAt = now
        }

        if rawFist {
            if !rightHandIsFist && (now - rightHandRawFistChangedAt) >= fistPressDebounceSeconds {
                rightHandIsFist = true
            }
        } else {
            if rightHandIsFist && (now - rightHandRawFistChangedAt) >= fistReleaseDebounceSeconds {
                rightHandIsFist = false
            }
        }
    }

    private func evaluateRightHandFist(anchor: HandAnchor) -> Bool {
        guard anchor.isTracked else { return false }

        guard
            let indexKnuckle = jointWorldPosition(anchor: anchor, name: .indexFingerKnuckle),
            let littleKnuckle = jointWorldPosition(anchor: anchor, name: .littleFingerKnuckle)
        else {
            return false
        }

        let palmWidth = max(simd_distance(indexKnuckle, littleKnuckle), 0.04)

        let checks: [(HandSkeleton.JointName, HandSkeleton.JointName, Float)] = [
            (.indexFingerTip, .indexFingerKnuckle, 0.90),
            (.middleFingerTip, .middleFingerKnuckle, 0.95),
            (.ringFingerTip, .ringFingerKnuckle, 0.95),
            (.littleFingerTip, .littleFingerKnuckle, 1.00),
            (.thumbTip, .thumbKnuckle, 1.10)
        ]

        var curledCount = 0
        for (tipName, baseName, ratio) in checks {
            guard
                let tip = jointWorldPosition(anchor: anchor, name: tipName),
                let base = jointWorldPosition(anchor: anchor, name: baseName)
            else {
                continue
            }

            if simd_distance(tip, base) < palmWidth * ratio {
                curledCount += 1
            }
        }

        // Require most fingers curled to consider as a fist.
        return curledCount >= 4
    }

    private func jointWorldPosition(anchor: HandAnchor, name: HandSkeleton.JointName) -> SIMD3<Float>? {
        guard let handSkeleton = anchor.handSkeleton else { return nil }
        let joint = handSkeleton.joint(name)
        guard joint.isTracked else { return nil }

        let worldFromJoint = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        let t = worldFromJoint.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    private func ensureDebugRayEntities(root: AnchorEntity) {
        guard enableDebugRayRendering else { return }
        let expectedCount = 6 * raysPerSector
        guard debugRayEntities.count != expectedCount else { return }

        for ray in debugRayEntities {
            ray.removeFromParent()
        }
        debugRayEntities.removeAll(keepingCapacity: false)

        for i in 0..<6 {
            for j in 0..<raysPerSector {
                let mesh = MeshResource.generateBox(width: debugRayThickness, height: debugRayThickness, depth: debugRayLength)
                let material = UnlitMaterial(color: UIColor.systemGreen.withAlphaComponent(0.85))
                let rayEntity = ModelEntity(mesh: mesh, materials: [material])
                rayEntity.name = "DebugRay_\(i)_\(j)"
                root.addChild(rayEntity)
                debugRayEntities.append(rayEntity)
            }
        }

        print("🎯 Debug rays active: \(debugRayEntities.count) (expected \(expectedCount))")
    }

    private func updateDebugRayVisuals(
        origin: SIMD3<Float>,
        baseForward: SIMD3<Float>,
        sectorSpan: Float,
        states: [Int]
    ) {
        guard enableDebugRayRendering else { return }
        let expectedCount = 6 * raysPerSector
        guard debugRayEntities.count == expectedCount else { return }

        let raysInSector = max(raysPerSector, 2)

        var rayIndex = 0
        for i in 0..<6 {
            let sectorStartAngle = -Float(i) * sectorSpan
            let state = i < states.count ? states[i] : 0
            let color: UIColor = (state == 1) ? .red : UIColor.systemGreen.withAlphaComponent(0.85)

            for j in 0..<raysInSector {
                let t = Float(j) / Float(raysInSector - 1)
                let angle = sectorStartAngle - t * sectorSpan
                let rot = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                let dir = normalize(rot.act(baseForward))

                let rayEntity = debugRayEntities[rayIndex]
                rayEntity.position = origin + dir * (debugRayLength * 0.5)
                rayEntity.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: dir)

                if var modelComponent = rayEntity.components[ModelComponent.self] as? ModelComponent {
                    modelComponent.materials = [UnlitMaterial(color: color)]
                    rayEntity.components.set(modelComponent)
                }

                rayIndex += 1
            }
        }
    }

    /// Match Ped_Sim obstacle by checking current entity and its parents.
    /// This handles cases where raycast hits a child mesh entity with empty/default name.
    private func isPedSimObstacleEntity(_ entity: Entity) -> Bool {
        var current: Entity? = entity
        while let e = current {
            let n = e.name
            if obstacleNames.contains(n) || n.contains("LongObstacle") {
                return true
            }
            current = e.parent
        }
        return false
    }

    private func startHandTrackingUpdates() {
        handTrackingTask?.cancel()
        handTrackingTask = Task {
            for await update in handTracking.anchorUpdates {
                if Task.isCancelled { break }

                let anchor = update.anchor
                guard anchor.chirality == .right else { continue }

                if anchor.isTracked {
                    let m = anchor.originFromAnchorTransform
                    let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

                    var forward = SIMD3<Float>(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)
                    if simd_length(forward) > 0.0001 {
                        forward = simd_normalize(forward)
                    } else {
                        forward = SIMD3<Float>(0, 0, -1)
                    }

                    await MainActor.run {
                        rightHandIsTracked = true
                        rightHandPosition = pos
                        rightHandForward = forward
                        updateRightHandFistDebounced(rawFist: evaluateRightHandFist(anchor: anchor))
                    }
                } else {
                    await MainActor.run {
                        rightHandIsTracked = false
                        rightHandRawFist = false
                        rightHandRawFistChangedAt = CACurrentMediaTime()
                        rightHandIsFist = false
                    }
                }
            }
        }
    }
}

#Preview(immersionStyle: .full) {
    ImmersiveView()
        .environment(AppModel())
}
