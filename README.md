# MHR Immersive Haptics

Context-aware controller vibration for **Monster Hunter Rise on PC**, built on top of **REFramework**.

The goal is simple: make combat and large-monster presence feel more physical without turning the controller into constant noise.

## Features

### Monster roars
- Long pressure-wave rumble pattern.
- Intensity fades with distance.
- Practical haptic cutoff at roughly **30 meters**.
- Distant roars no longer vibrate when the monster is effectively out of audible range.

### Monster hard landings
- Detects real vertical movement instead of relying only on animation IDs.
- Gentle slopes and soft descents are ignored.
- Hard landings scale with:
  - fall / impact speed;
  - distance from the player.
- Nearby heavy landings feel much stronger than distant ones.

### Player weapon hits
Outgoing weapon impacts are split into two feedback classes:

- **White / normal damage-number hits** — lighter contact feedback.
- **Red damage-number hits** — stronger contact feedback.

The two classes use separate intensity bands, so red hits always feel noticeably heavier than normal hits.

Buddy-style damage is filtered out and does not trigger the player's hit feedback.

### Damage received by the player
Incoming damage is intentionally the strongest combat feedback.

Intensity scales with the **percentage of maximum HP lost**, so:
- small hits feel lighter;
- heavy attacks feel significantly stronger;
- very large hits can reach full-strength rumble.

Incoming hit feedback is always stronger than outgoing weapon-hit feedback.

### Player hard landings
Large player falls produce their own landing impulse.

Strength is calculated from both:
- vertical impact speed;
- actual drop height.

Small terrain changes, steps and ordinary movement are ignored.

## Feedback hierarchy

The combat feedback is deliberately tuned so that:

```text
normal outgoing hit
<
red outgoing hit
<
incoming hit on the player
```

This keeps the controller readable instead of making every event feel equally strong.

## Requirements

- Monster Hunter Rise on PC
- REFramework
- REFramework.NET / C# source-plugin support
- An XInput-compatible controller

Xbox controllers should work directly.

Other controllers may work if Steam Input or another compatibility layer exposes them as an XInput device.

## Installation

1. Install and verify that **REFramework** is working.
2. Make sure REFramework's C# source-plugin support is available.
3. Download the latest release.
4. Extract the archive into your Monster Hunter Rise game directory.
5. Confirm that these files exist:

```text
reframework/autorun/MHRImmersiveHaptics.lua
reframework/plugins/source/MHRImmersiveHaptics.cs
```

6. Restart the game.

### Upgrading from a development build

Remove older development files before installing v1.0.0, especially:

```text
MHRHaptics_ActionRuntime_v*.lua
MHRHaptics_*Probe*.lua
```

Only the final release runtime should be active.

## Uninstallation

Delete:

```text
reframework/autorun/MHRImmersiveHaptics.lua
reframework/plugins/source/MHRImmersiveHaptics.cs
```

Then restart the game.

## Notes

### Script Generated UI is empty

This is expected in the release build.

Development versions contained extensive diagnostic UI, counters, source probes and manual vibration tests. These were removed for v1.0.0.

The production build runs silently in the background.

### Performance

The mod is designed to be lightweight.

It does not render anything and therefore adds effectively no direct GPU workload. Most work consists of small RE Engine state reads, event hooks and controller-output updates.

Actual CPU overhead depends on the system and game state, but the production build removes the heavy diagnostic UI and logging used during development.

### Multiplayer and buddies

Buddy-style damage is filtered from outgoing player-hit feedback.

The mod is read-only with respect to gameplay state: it observes game state and sends vibration commands to the local controller.

As with any REFramework mod, future game updates or heavily modified combat/UI systems may require compatibility updates.

## Known limitations

- Uses standard XInput left/right motor vibration, not platform-specific HD haptics.
- Monster footsteps are intentionally not implemented; the mod focuses on larger, more meaningful events to avoid excessive vibration.
- Some unusual damage-display or combat-overhaul mods may interfere with hit classification.
- Future Monster Hunter Rise updates may change internal RE Engine methods used by the runtime.

## Why no monster footstep vibration?

Footstep haptics were explored during development, but they were deliberately left out of the final release.

The final event set already provides frequent feedback through combat, roars and landings. Adding constant step pulses made the concept risk becoming noisy rather than immersive.

## Project structure

```text
reframework/
├── autorun/
│   └── MHRImmersiveHaptics.lua
└── plugins/
    └── source/
        └── MHRImmersiveHaptics.cs
```

The Lua runtime reads Monster Hunter Rise state and emits compact haptic events.

The C# plugin handles XInput output and renders the vibration patterns on a separate worker thread.

## Version

Current release: **1.0.0**

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Credits

Built using the REFramework ecosystem.

Monster Hunter Rise and all related trademarks belong to Capcom.

This is an unofficial fan-made mod and is not affiliated with or endorsed by Capcom.

cuteling 228
