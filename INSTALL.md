# Installation

## Requirements

- Monster Hunter Rise on PC
- REFramework
- REFramework.NET / C# source-plugin support
- XInput-compatible controller

## Install

1. Install REFramework.
2. Confirm REFramework loads correctly in Monster Hunter Rise.
3. Install/enable C# source-plugin support for your REFramework setup.
4. Extract the MHR Immersive Haptics release archive directly into the game folder.

You should end up with:

```text
<Monster Hunter Rise>/
└── reframework/
    ├── autorun/
    │   └── MHRImmersiveHaptics.lua
    └── plugins/
        └── source/
            └── MHRImmersiveHaptics.cs
```

5. Restart the game.

## Upgrading from an old development version

Delete any old test runtime/probe files before launching:

```text
reframework/autorun/MHRHaptics_ActionRuntime_v*.lua
reframework/autorun/MHRHaptics_*Probe*.lua
```

Do not run an old ActionRuntime together with the v1.0.0 runtime.

## Verify installation

The release intentionally has no Script Generated UI.

If the mod is working, haptics should trigger during supported gameplay events.

REFramework's log should also contain a single startup message indicating that MHR Immersive Haptics v1.0.0 loaded.

## Uninstall

Delete:

```text
reframework/autorun/MHRImmersiveHaptics.lua
reframework/plugins/source/MHRImmersiveHaptics.cs
```

Restart the game.
