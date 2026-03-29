//
//  AVPlayerView.swift
//  CrossWalk_Tokyo
//
//  Created by JLiu on 10/12/25.
//

import SwiftUI

struct AVPlayerView: UIViewControllerRepresentable {
    let viewModel: AVPlayerViewModel

    func makeUIViewController(context: Context) -> some UIViewController {
        return viewModel.makePlayerViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
        // Update the AVPlayerViewController as needed
    }
}

struct AVPlayerViewWithHUD: View {
    let viewModel: AVPlayerViewModel

    // Replace these with live world-tracking values from your source (ARKit/CoreMotion/etc.)
    @State private var worldX: Double = 0
    @State private var worldY: Double = 0
    @State private var worldZ: Double = 0

    @State private var yaw: Double = 0
    @State private var pitch: Double = 0
    @State private var roll: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            AVPlayerView(viewModel: viewModel)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                Text("World Position")
                    .font(.caption).bold()
                Text(String(format: "x: %.3f  y: %.3f  z: %.3f", worldX, worldY, worldZ))
                    .font(.caption2)
                    .monospacedDigit()

                Divider().overlay(.white.opacity(0.35))

                Text("Orientation")
                    .font(.caption).bold()
                Text(String(format: "yaw: %.2f°  pitch: %.2f°  roll: %.2f°", yaw, pitch, roll))
                    .font(.caption2)
                    .monospacedDigit()
            }
            .padding(10)
            .foregroundStyle(.white)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 16)
            .padding(.leading, 16)
        }
    }
}

// No change needed here. Ensure parent usage is:
// AVPlayerViewWithHUD(viewModel: viewModel)
