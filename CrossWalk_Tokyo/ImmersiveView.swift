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

    // Unity-like obstacle detection params
    private struct ObsSectorState {
        var currentDistance: Float = 6
        var minDistance: Float = 6
        var preDistance: Float = 6
        var timer: Float = 0
        var realState: Int = 0
        var showState: Int = 0
        var resetTimer: Float = 0
    }

    @State private var sectorStates: [ObsSectorState] = Array(repeating: ObsSectorState(), count: 6)
    private let farDetectionRadius: Float = 5.0
    private let nearDetectionRadius: Float = 1.0
    private let raysPerSector: Int = 5
    private let verticalStep: Float = 1.0
    private let stepThreshold: Int = 1
    private let obstacleNames: Set<String> = ["Cube_0", "Cube_1", "Cube_2", "SpawnCube"]

    private let logger = Logger(subsystem: "flavinlab.CrossWalk-Tokyo", category: "WorldTracking")

    // NEW: 雷达射线探测常数
    private let manForwardRayLength: Float = 20.0

    // NEW: 将单变量改为存放 6 个实体引用的数组
    @State private var forwardRayEntities: [ModelEntity] = []
    @State private var rayContainers: [Entity] = []
    @State private var hitIndicatorEntities: [ModelEntity] = []

    // NEW: 保存7个状态的数组，0 为绿，1 为红
    @State private var hudIndicatorStates: [Int] = Array(repeating: 0, count: 7)

    private let spawnCubeDistance: Float = 2.0

    var body: some View {
        ZStack {
            RealityView { content in
                // Root world anchor
                let rootAnchor = AnchorEntity(world: matrix_identity_float4x4)
                content.add(rootAnchor)
                self.rootAnchorRef = rootAnchor

                // Head-locked anchor (camera)
                let head = AnchorEntity(.head)
                content.add(head)
                self.headAnchor = head

                // Head-anchored text in front of user
                let initialText = "Loading coordinate..."
                let initialMesh = MeshResource.generateText(
                    initialText,
                    extrusionDepth: 0.001,
                    font: .systemFont(ofSize: 0.03, weight: .semibold), // 略微改小字号以适应多行显示
                    containerFrame: .zero,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
                let initialMaterial = UnlitMaterial(color: .white)
                let textEntity = ModelEntity(mesh: initialMesh, materials: [initialMaterial])
                textEntity.name = "HeadWorldText"
                textEntity.position = SIMD3<Float>(0, 0.05, -0.7) // 略微往上移，留出下方空间给换行
                textEntity.scale = SIMD3<Float>(repeating: 1.0)
                head.addChild(textEntity)
                
                // IMPORTANT: 储存实体引用以便后续定时器修改
                DispatchQueue.main.async {
                    self.headTextEntity = textEntity
                    self.lastHeadText = initialText
                }

                // Load scene entities asynchronously
                Task { @MainActor in
                    do {
                        // Load environment
                        let crossTokyoEntity = try await Entity.load(named: "Crossing_Tokyo")
                        crossTokyoEntity.position.y = 5.95
                        
                        // 删掉了 generateCollisionShapes，让东京场景彻底不参与碰撞！
                        // 这样射线就会像穿透空气一样穿透城市，只打在 Cube 上。

                        rootAnchor.addChild(crossTokyoEntity)

                        // Spawn one cube in front of spawn/origin
                        let spawnCube = try await Entity.load(named: "Cube")
                        spawnCube.name = "SpawnCube"
                        
                        // 把宽度和厚度放大到了 1.5，高度保持 1.7，这样它就是一个很大很明显的方块了
                        spawnCube.scale = SIMD3<Float>(1.5, 10.2, 1.5) 
                        
                        // 让底端着地：高度是 1.7，一半就是 0.85，把它放在 Y=0.85 的位置即可完美贴地
                        spawnCube.position = SIMD3<Float>(0, 0.85, -spawnCubeDistance)
                        
                        spawnCube.generateCollisionShapes(recursive: true) // 只有 Cube 生成碰撞体

                        if let modelEntity = spawnCube as? ModelEntity,
                           var mc = modelEntity.components[ModelComponent.self] as? ModelComponent {
                            mc.materials = [SimpleMaterial(color: .blue, isMetallic: false)]
                            modelEntity.components[ModelComponent.self] = mc
                        }

                        rootAnchor.addChild(spawnCube)

                        // NEW: 创建 6 条世界射线呈 60 度角辐射
                        var tempContainers: [Entity] = []
                        var tempRays: [ModelEntity] = []
                        var tempHits: [ModelEntity] = []

                        for _ in 0..<6 {
                            let container = Entity()
                            let rayMesh = MeshResource.generateCylinder(height: 1.0, radius: 0.01)
                            let rayMat = UnlitMaterial(color: .green)
                            let rayEntity = ModelEntity(mesh: rayMesh, materials: [rayMat])
                            
                            rayEntity.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                            rayEntity.position = SIMD3<Float>(0, 0, -0.5)
                            
                            container.addChild(rayEntity)
                            rootAnchor.addChild(container)
                            
                            let hitMesh = MeshResource.generateSphere(radius: 0.1) 
                            let hitMat = UnlitMaterial(color: .yellow)
                            let hitEntity = ModelEntity(mesh: hitMesh, materials: [hitMat])
                            hitEntity.isEnabled = false // 初始隐藏
                            rootAnchor.addChild(hitEntity)
                            
                            tempContainers.append(container)
                            tempRays.append(rayEntity)
                            tempHits.append(hitEntity)
                        }

                        self.rayContainers = tempContainers
                        self.forwardRayEntities = tempRays
                        self.hitIndicatorEntities = tempHits

                        // Directional light
                        let lightEntity = Entity()
                        var lightComponent = DirectionalLightComponent()
                        lightComponent.intensity = 1000
                        lightComponent.color = .white
                        lightEntity.components[DirectionalLightComponent.self] = lightComponent
                        lightEntity.orientation = simd_quatf(angle: -.pi/4, axis: SIMD3<Float>(1,0,0))
                        rootAnchor.addChild(lightEntity)

                    } catch {
                        print("Error loading entities: \(error)")
                    }
                }
            } // !!! 将 update 闭包完全删除，因为在内部更改 State 是非法的 !!!
            .ignoresSafeArea()

            // Face-fixed world-coordinate HUD
            VStack(spacing: 4) {
                Text("My World Coordinate")
                    .font(.caption).bold()
                Text(String(format: "x: %.3f  y: %.3f  z: %.3f", guiWorldPosition.x, guiWorldPosition.y, guiWorldPosition.z))
                    .font(.caption2)
                    .monospacedDigit()

                Text(String(format: "yaw: %.1f°  pitch: %.1f°  roll: %.1f°", guiOrientationDegrees.x, guiOrientationDegrees.y, guiOrientationDegrees.z))
                    .font(.caption2)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 18)

            // Unity-like 7-circle GUI
            GeometryReader { geo in
                let c = CGPoint(x: geo.size.width / 2.0, y: 120.0)
                let r: CGFloat = 16.0
                let ring: CGFloat = 40.0
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        // 将复杂的数学运算拆分开，明确为 CGFloat 类型，减轻编译器推断压力
                        let baseAngle: CGFloat = -(.pi / 2.0)
                        let offset: CGFloat = (2.0 * .pi) / 3.0
                        let step: CGFloat = CGFloat(i) * (.pi / 3.0)
                        let angle: CGFloat = baseAngle - offset + step
                        
                        // 把 2D panel 的颜色也与 hudIndicatorStates 同步 (0 为绿, 其他为红)
                        Circle()
                            .fill(hudIndicatorStates[i + 1] == 1 ? Color.red : Color.green)
                            .frame(width: r * 2, height: r * 2)
                            .position(
                                x: c.x + cos(angle) * ring,
                                // 【修改这里】：将 + 改为 -，实现 2D 屏幕的上下翻转
                                y: c.y - sin(angle) * ring
                            )
                    }
                    Circle()
                        // 设中心球对应数组的第 0 个元素
                        .fill(hudIndicatorStates[0] == 1 ? Color.red : Color.green)
                        .frame(width: r * 2, height: r * 2)
                        .position(c)
                }
            }
            .allowsHitTesting(false)

            // 将状态数组传给 3D HUD
            GUIOverlay(targetEntity: $manEntity, manRotationAngle: .constant(0), hudStates: $hudIndicatorStates)
            CountdownOverlay()
        }
        .ignoresSafeArea()
        // 统一在主频率 Timer 里更新逻辑
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updateWorldTrackingAndEntities()
            DetectObstaclesWithRayCast()
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

                    try await arkitSession.run([worldTracking])
                    isWorldTrackingRunning = true
                    logger.debug("ARKitSession started. WorldTrackingProvider is running.")
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
            #if !targetEnvironment(simulator)
            if !isRunningInPreview {
                arkitSession.stop()
            }
            #endif
            isWorldTrackingRunning = false
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

    private func DetectObstaclesWithRayCast() {
        guard let head = headAnchor, let root = rootAnchorRef else { return }

        let dt: Float = 0.1
        let headM = head.transformMatrix(relativeTo: nil)
        let playerBottom = headM.position + SIMD3<Float>(0, -0.85, 0)
        let forward = headM.forward

        var next = sectorStates
        let sectorCount = next.count
        let sectorAngleSpan: Float = 360.0 / Float(max(sectorCount, 1))

        for i in 0..<sectorCount {
            let sectorStartAngle = Float(i) * sectorAngleSpan - sectorAngleSpan / 2
            let sectorEndAngle = Float(i + 1) * sectorAngleSpan - sectorAngleSpan / 2
            let angleStep = (sectorEndAngle - sectorStartAngle) / Float(max(raysPerSector, 1))

            var tempState = 0
            var closestDistance = Float.greatestFiniteMagnitude

            for j in 0..<raysPerSector {
                let currentAngle = sectorStartAngle + Float(j) * angleStep
                let rayDirection = normalize(simd_quatf(angle: currentAngle * .pi / 180, axis: SIMD3<Float>(0, 1, 0)).act(forward))

                if let nearHit = root.scene?.raycast(origin: playerBottom, direction: rayDirection, length: nearDetectionRadius).first,
                   obstacleNames.contains(nearHit.entity.name) {
                    tempState = max(tempState, 4)
                    closestDistance = min(closestDistance, nearHit.distance)
                    break
                }

                if let farHit = root.scene?.raycast(origin: playerBottom, direction: rayDirection, length: farDetectionRadius).first,
                   obstacleNames.contains(farHit.entity.name) {
                    tempState = max(tempState, 2)
                    closestDistance = min(closestDistance, farHit.distance)
                    break
                }
            }

            var s = next[i]
            s.preDistance = s.currentDistance
            s.currentDistance = closestDistance.isFinite ? closestDistance : 6
            s.realState = tempState

            if s.realState == 0 {
                s.minDistance = 6
                s.timer = 0
                s.resetTimer = 0
                s.showState = 0
            } else {
                let isApproaching = s.currentDistance < s.preDistance - 0.01
                if isApproaching {
                    s.showState = s.realState
                    s.timer = 0
                    s.resetTimer = 0
                } else {
                    s.timer += dt
                    if s.timer < 0.5 {
                        s.showState = s.realState
                        s.resetTimer = 0
                    } else {
                        s.resetTimer += dt
                        let cycle = s.resetTimer.truncatingRemainder(dividingBy: 3.0)
                        s.showState = cycle < 0.5 ? s.realState : 0
                    }
                }
                s.minDistance = s.currentDistance <= s.minDistance ? s.currentDistance : max(s.currentDistance - 0.001, nearDetectionRadius)
            }
            next[i] = s
        }
        sectorStates = next
    }

    private func detectForwardCubeHit() {
        guard let root = rootAnchorRef else { return }

        // 默认初始化7个球为绿灯(0)
        var newStates = Array(repeating: 0, count: 7)

        // 读取世界的起始点与核心朝向
        #if targetEnvironment(simulator)
        let origin = SIMD3<Float>(0, 1.2, 0)
        let baseForward = SIMD3<Float>(0, 0, -1)
        #else
        guard isWorldTrackingRunning, let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }

        let transformMatrix = deviceAnchor.originFromAnchorTransform
        let devicePos = SIMD3<Float>(transformMatrix.columns.3.x, transformMatrix.columns.3.y, transformMatrix.columns.3.z)
        let forward = normalize(SIMD3<Float>(-transformMatrix.columns.2.x, -transformMatrix.columns.2.y, -transformMatrix.columns.2.z))
        
        // 直接使用设备原点作为起点，不再向前推移
        let origin = devicePos
        let baseForward = forward
        #endif

        // 循环发射 6 条射线
        for i in 0..<6 {
            // 在 RealityKit 里，让一个向量顺时针旋转，绕 Y 轴旋转的角必须是负的。
            // 界面上我们是顺时针生成圆圈的（0: 前, 1: 右前, 2: 右后, 3: 后, 4: 左后, 5: 左前）
            let angle = -Float(i) * (.pi / 3) 
            let rot = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            let dir = rot.act(baseForward)

            var drawLength: Float = 10.0 
            var actualHitPosition: SIMD3<Float>? = nil
            var hitCube = false

            let hits = root.scene?.raycast(origin: origin, direction: dir, length: manForwardRayLength) ?? []
            
            for hit in hits {
                let hitName = hit.entity.name
                if obstacleNames.contains(hitName) || hitName.contains("Cube") {
                    hitCube = true
                    drawLength = max(0.05, hit.distance)
                    actualHitPosition = hit.position
                    break
                }
                // 忽略城市的空气墙遮挡
                if hitName.contains("Crossing_Tokyo") { continue }
            }

            // 如果打中，对应下标变红 (为了实现1和6对换、2和5对换、3和4对换，直接使用 6 - i)  
            if hitCube {
                newStates[6 - i] = 1
            }

            // 更新 3D 渲染画面 (射线实体、指示球)
            if i < rayContainers.count && i < forwardRayEntities.count && i < hitIndicatorEntities.count {
                let container = rayContainers[i]
                let ray = forwardRayEntities[i]
                let indicator = hitIndicatorEntities[i]

                container.position = origin
                container.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: dir)
                container.scale = SIMD3<Float>(1, 1, drawLength)

                if var model = ray.model {
                    model.materials = [UnlitMaterial(color: hitCube ? .red : .green)]
                    ray.model = model
                }
                
                if hitCube, let pos = actualHitPosition {
                    indicator.position = pos - (dir * 0.01)
                    indicator.isEnabled = true
                } else {
                    indicator.isEnabled = false
                }
            }
        }

        // 把最新的 6 条方向判定立刻同步给界面 HUD
        hudIndicatorStates = newStates
    }
}

// Keep your preview macro if using Xcode previews
#Preview(immersionStyle: .full) {
    ImmersiveView()
        .environment(AppModel())
}
