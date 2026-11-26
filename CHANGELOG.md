# Changelog

All notable changes to **Battle Fatigue (Low HP Stance)** are documented in this file.

## [1.1.0] - 2026-11-26

### Fixed
- **Eliminated `0xC0000264` UE4SS crash:** Removed non-existent `.Z` access on `FVector2D` (`InputVectorCache`) and removed background `LoopAsync` thread execution; all evaluation and hook overrides now run synchronously on the Game Thread.
- **Restored active hook execution (`SetLocomotionParameterCache` + `UpdateLocomotionParameterCache`):** Fixed `hookFiredCount = 0` / stance not activating after removing `LoopAsync`, while keeping 100% Game-Thread execution.
- **Per-spawn capability probing (`st.caps`):** Probed all 10 hot-path locomotion cache properties once per character spawn in `resolveFighterComponents` so missing properties are never read at 60Hz (and logged once when `logDebug = true`).
- **Mid-air hover compatibility (`MOVE_CUSTOM = 6`):** Accepted `MovementMode = 6` alongside `1` (Walking) and `5` (Flying) while keeping `MOVE_FALLING (3)` blocked.

### Added
- **`config.enableDevHotkeys = false`:** Separated developer hotkeys (`F8` hot-reload, `F9` diagnostic snapshot) from `config.enableHotkeys` (`F7` live toggle).
- **`config.profile = false`:** Optional `os.clock()` hook profiler reporting calls/sec and average microseconds per call in `F9` diagnostics.

---

## [1.0.1] - 2026-11-26

### Fixed
- **RT x2 descent ground-lock:** Prevented overriding `LocomotionStateCache` during descent/landing transitions (`actSFL`, `JumpStatusCache`, `DashUpDownStatusCache`) and added stabilization delays.
- **Ki charge / action recovery:** Removed stale `IsRequestResetStateMachineCache` check so the exhausted stance resumes after charging Ki or completing actions without requiring a jump.

### Known Issues (Resolved in 1.1.0)
- Reading `InputVectorCache.Z` on `FVector2D` inside the 60Hz hook triggered UE4SS property errors associated with `0xC0000264` crashes.

---

## [1.0.0] - 2026-11-26

### Added
- Initial release of **Battle Fatigue (Low HP Stance)** for *Dragon Ball: Sparking! ZERO*.
- Automatic visual-only exhausted/panting idle stance when any fighter reaches their last (red) health bar (`HP <= 10,000` or `fallbackRatio = 0.30`).
- Ground and mid-air idle stance support with immediate cancel on movement/action input.
- Best-effort auto-disable checks for online battles and replays.
- Live toggle (`F7`), hot-reload (`F8`), and diagnostic snapshot (`F9`) hotkeys.
