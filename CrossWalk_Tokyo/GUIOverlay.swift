import SwiftUI
import RealityKit
import RealityKitContent
import UIKit
import simd
import Combine

struct GUIOverlay: View {
    @Binding var targetEntity: Entity?       // Reference to Man1
    @Binding var manRotationAngle: Float     // Rotation angle of the target entity (unused for HUD mapping)
    // NEW: 存放7个整型的数组（0: 绿灯, 1: 红灯）
    @Binding var hudStates: [Int]

    @State private var hudDiscs: [ModelEntity] = []
    @State private var headAnchorRef: AnchorEntity?

    var body: some View {
        ZStack {
            RealityView { content in
            // Head-locked anchor
            let headAnchor = AnchorEntity(.head)
            self.headAnchorRef = headAnchor
            content.add(headAnchor)

            let hudPlane = Entity()
            hudPlane.name = "HeadLockedHUD"
            hudPlane.position = SIMD3<Float>(0.0, 0.10, -0.35)
            headAnchor.addChild(hudPlane)

            // Create discs
            let discRadius: Float = 0.008
            let discHeight: Float = 0.001
            let defaultColor = UIColor.green

            var createdDiscs: [ModelEntity] = []

            // Center disc (Index 0)
            let centerDisc = ModelEntity(
                mesh: .generateCylinder(height: discHeight, radius: discRadius),
                materials: [UnlitMaterial(color: defaultColor)]
            )
            centerDisc.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1,0,0))
            centerDisc.position = SIMD3<Float>(0,0,0.001)
            hudPlane.addChild(centerDisc)
            createdDiscs.append(centerDisc)

            // Surrounding 6 discs (Index 1...6)
            let ringRadius: Float = 0.02
            for i in 0..<6 {
                // 将复杂的数学运算拆分开，明确为 Float 类型，减轻编译器推断压力
                let baseAngle: Float = .pi / 2.0
                let offset: Float = (2.0 * .pi) / 3.0
                let step: Float = Float(i) * (.pi / 3.0)
                // HUD 需求：整体顺时针旋转 60 度。
                // 在当前坐标约定中，减去 pi/3 即为顺时针 60°。
                let hudClockwise60: Float = -.pi / 3.0
                // 在当前基础上再逆时针旋转 90°。
                let hudCounterClockwise90: Float = .pi / 2.0
                let angle: Float = baseAngle + offset + hudClockwise60 + hudCounterClockwise90 - step
                
                let x = cosf(angle) * ringRadius
                // 【修改这里】：加上负号，实现 3D 空间的上下翻转
                let y = -sinf(angle) * ringRadius
                
                // Start surrounding discs as green (safe) by default — updateHUDColor will change them as needed
                let disc = ModelEntity(
                    mesh: .generateCylinder(height: discHeight, radius: discRadius),
                    materials: [UnlitMaterial(color: defaultColor)]
                )
                disc.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1,0,0))
                disc.position = SIMD3<Float>(x, y, 0.001)
                hudPlane.addChild(disc)
                createdDiscs.append(disc)
            }

            // Apply initial colors once (static HUD when raycasts are removed)
            DispatchQueue.main.async {
                self.hudDiscs = createdDiscs
                applyStatesToColors(hudStates)
            }
        } // end RealityView builder
            // optional lightweight debug SwiftUI overlay can remain if needed
            VStack {
                Spacer()
            }
        } // end ZStack
        .ignoresSafeArea()
        // 监听外部数组的改变，数组内容一变，就刷新材质
        .onChange(of: hudStates) { _, newStates in
            applyStatesToColors(newStates)
        }
        .onDisappear {
            // nothing to clean up for HUD since raycasts were removed
        }
    }

    // 根据传入的数组映射颜色并赋值
    private func applyStatesToColors(_ states: [Int]) {
        guard hudDiscs.count >= 7, states.count >= 7 else { return }
        
        for i in 0..<7 {
            let disc = hudDiscs[i]
            
            let color: UIColor
            if states[i] == 1 {
                color = .red
            } else if states[i] == 2 {
                color = .yellow
            } else {
                color = .green
            }
            
            if var modelComponent = disc.components[ModelComponent.self] as? ModelComponent {
                modelComponent.materials = [UnlitMaterial(color: color)]
                disc.components.set(modelComponent)
            }
        }
    }
    // end GUIOverlay
}
