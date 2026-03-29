//
//  ToggleImmersiveSpaceButton.swift
//  CrossWalk_Tokyo
//
//  Created by JL on 10/12/25.
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {

    @Environment(AppModel.self) private var appModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Button {
            Task { await toggleImmersive() }
        } label: {
            Text(appModel.immersiveSpaceState == .open ? "Hide Immersive Space" : "Show Immersive Space")
        }
        .disabled(appModel.immersiveSpaceState == .inTransition)
        .animation(nil, value: appModel.immersiveSpaceState)
        .fontWeight(.semibold)
    }

    @MainActor
    private func toggleImmersive() async {
        switch appModel.immersiveSpaceState {
        case .open:
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            // Don't set immersiveSpaceState to .closed because there
            // are multiple paths to ImmersiveView.onDisappear().
            // Only set .closed in ImmersiveView.onDisappear().

        case .closed:
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                // Don't set immersiveSpaceState to .open because there
                // may be multiple paths to ImmersiveView.onAppear().
                // Only set .open in ImmersiveView.onAppear().
                break

            case .userCancelled, .error:
                // On error or user cancel, mark the immersive space as closed
                // because it failed to open.
                appModel.immersiveSpaceState = .closed

            @unknown default:
                // On unknown response, assume space did not open.
                appModel.immersiveSpaceState = .closed
            }

        case .inTransition:
            // This case should not ever happen because button is disabled for this case.
            break
        }
    }
}

