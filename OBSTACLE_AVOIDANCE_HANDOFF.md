# Obstacle Avoidance Handoff (CrossWalk_Tokyo)

This document explains how the obstacle-avoidance logic is wired in the current app build, and what to adjust when handing over to another developer.

## 1) Where the logic lives

Primary file:
- `CrossWalk_Tokyo/ImmersiveView.swift`

Related UI file:
- `CrossWalk_Tokyo/GUIOverlay.swift`

Core detection entrypoint:
- `detectForwardCubeHit()` in `ImmersiveView.swift`

## 2) Runtime update loop

Obstacle avoidance runs in the main timer update:
- Frequency: `0.1s` (`Timer.publish(every: 0.1, ...)`)
- Calls `detectForwardCubeHit()` every tick

Within this flow:
1. Compute six forward sectors
2. Raycast each sector against active obstacles (`LongObstacle_0..2`)
3. Map sector hit result into HUD outer-ring indices
4. Send intensity to haptic/network output via `appModel.sendIntensityToDevice(...)`
5. Evaluate right-hand cane ray and write result to HUD center point (index 0)

## 3) Active obstacle targets

Only these names are treated as dynamic avoidance targets:
- `LongObstacle_0`
- `LongObstacle_1`
- `LongObstacle_2`

Name matching is robust through parent-chain checks in:
- `isPedSimObstacleEntity(_:)`

## 4) Sector model (6 groups)

Sector setup in `detectForwardCubeHit()`:
- `sectorSpan = 60°`
- Group 0 starts at straight forward
- Scan direction is clockwise
- Each sector uses `raysPerSector` samples (currently 20)

Key parameter:
- `manForwardRayLength` (currently 30.0m)

## 5) HUD mapping

The six sector results are mapped to HUD outer-ring points through:
- `sectorToHUDIndex`

Current mapping in code:
- `private let sectorToHUDIndex: [Int] = [6, 5, 4, 3, 2, 1]`

Meaning:
- Keep sector detection math unchanged, but reorder how results appear on HUD.
- If display orientation needs adjustment, only edit this mapping array.

## 6) Color semantics

Current HUD semantics:
- `0` = green (clear)
- `1` = red (hit)

No yellow branch is used in current obstacle display logic.

## 7) Hand override (left-front sector takeover)

Behavior:
- Left-front sector can be overridden by right-hand cane ray.
- Condition: right hand is **raised** and **fist is detected**.
- If fist is released, logic falls back to original left-front sector detection.

Where:
- Gate function: `shouldUseRightHandOverrideForLeftFront()`
- Applied inside sector loop when `i == 5`

## 8) Hand tracking and fist detection

Providers:
- `WorldTrackingProvider`
- `HandTrackingProvider` (when supported)

Fist detection:
- Uses hand skeleton joint curl distances (`evaluateRightHandFist(anchor:)`)
- Uses debouncing to avoid flicker:
  - Press debounce: `fistPressDebounceSeconds` (0.12s)
  - Release debounce: `fistReleaseDebounceSeconds` (0.08s)

Right-hand cane ray:
- `detectArmCaneHit(root:)`
- Uses tracked right-hand position + forward direction
- Writes result to HUD center (`newStates[0]`)

## 9) Debug visualization

Debug ray rendering is currently disabled:
- `enableDebugRayRendering = false`

To re-enable visual rays for debugging:
- Set `enableDebugRayRendering = true`

## 10) Tuning knobs (most useful)

In `ImmersiveView.swift`:
- `manForwardRayLength`
- `raysPerSector`
- `sectorToHUDIndex`
- `rightHandRaisedThresholdY`
- `fistPressDebounceSeconds`
- `fistReleaseDebounceSeconds`
- `armCaneRayLength`
- `armCaneDownwardBias`

## 11) Handoff checklist

Before merging future changes, verify:
1. HUD outer-ring orientation still matches physical sector directions
2. Left-front hand override still activates only on raised + fist
3. Releasing fist restores default left-front sector logic
4. Intensity output indexes (`0..5`) still match your target hardware mapping
5. Obstacle entity naming remains consistent (`LongObstacle_*`)

---

If behavior looks wrong visually, first check `sectorToHUDIndex` before changing raycast math.
