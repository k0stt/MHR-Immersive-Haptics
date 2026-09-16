# Changelog

## 1.0.0

First production release.

### Features

- Distance-aware monster roar haptics.
- Practical monster-roar cutoff at approximately 30 meters.
- Long pressure-wave roar pattern.
- Hard monster landing detection based on real vertical motion.
- Monster landing intensity scales with impact speed and player distance.
- Gentle terrain descents are ignored.
- Normal/white outgoing weapon-hit feedback.
- Stronger red outgoing weapon-hit feedback.
- Buddy-style damage filtering.
- Incoming damage feedback scales with percentage of maximum HP lost.
- Incoming damage is always stronger than outgoing weapon-hit feedback.
- Adaptive player hard-landing vibration based on fall speed and height.

### Release cleanup

- Removed Script Generated UI diagnostics.
- Removed source probes and debug counters.
- Removed event-history logging.
- Removed manual vibration test buttons.
- Removed unused experimental STEP/LIGHT patterns.
- Preserved the final gameplay tuning from the tested development build.
