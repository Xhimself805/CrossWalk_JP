# CrossWalk_Tokyo

VisionOS prototype for immersive crosswalk navigation with obstacle awareness, haptic/intensity signaling, and hand-driven override behavior.

## Project Snapshot

Main app target:
- `CrossWalk_Tokyo.xcodeproj`

Core runtime logic:
- `CrossWalk_Tokyo/ImmersiveView.swift`

HUD rendering:
- `CrossWalk_Tokyo/GUIOverlay.swift`

Pedestrian simulation bridge:
- `CrossWalk_Tokyo/PedestrianSimBridge.swift`

---

## Obstacle Avoidance (How to Use)

This is the section your teammate should read first.

### 1) What is detected

Obstacle avoidance currently checks against these dynamic entities:
- `LongObstacle_0`
- `LongObstacle_1`
- `LongObstacle_2`

Entity matching is done through parent-chain name checks in:
- `isPedSimObstacleEntity(_:)`

### 2) How detection runs

Detection entrypoint:
- `detectForwardCubeHit()` in `ImmersiveView.swift`

Update cadence:
- Every `0.1s` via app timer.

Detection model:
- 6 forward sectors
- each sector spans `60°`
- each sector samples `raysPerSector` rays (currently `20`)
- clockwise sweep from straight-ahead baseline

### 3) HUD behavior

State values:
- `0` = clear (green)
- `1` = hit (red)

Mapping from sector result to HUD outer-ring index is controlled by:
- `sectorToHUDIndex`

If orientation appears wrong on headset, **only change `sectorToHUDIndex` first** (do not immediately change ray math).

### 4) Hand override (left-front takeover)

When gesture gate is active, **left-front sector** can be controlled by right-hand cane ray.

Gate condition:
- right hand tracked
- right hand raised above threshold
- right hand fist detected (skeleton curl-based, debounced)

If fist is released, behavior falls back to normal sector detection.

### 5) Hand fist detection quality

Fist detection uses hand skeleton joint curl distance checks plus debounce:
- press debounce: `0.12s`
- release debounce: `0.08s`

This is implemented in:
- `evaluateRightHandFist(anchor:)`
- `updateRightHandFistDebounced(rawFist:)`

### 6) Important tuning constants

In `ImmersiveView.swift`:
- `manForwardRayLength`
- `raysPerSector`
- `sectorToHUDIndex`
- `rightHandRaisedThresholdY`
- `armCaneRayLength`
- `armCaneDownwardBias`
- `fistPressDebounceSeconds`
- `fistReleaseDebounceSeconds`

### 7) Debug visualization

Ray visualization is currently disabled:
- `enableDebugRayRendering = false`

Enable this only for debugging alignment, then disable for normal use.

---

## Handoff Notes

A fuller engineering handoff document is included here:
- `OBSTACLE_AVOIDANCE_HANDOFF.md`

Use that file for deeper context, implementation notes, and teammate onboarding details.
