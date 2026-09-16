using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

using REFrameworkNET;
using REFrameworkNET.Attributes;

public class MHRImmersiveHaptics
{
    private const uint ErrorSuccess = 0;
    private const uint NoController = 0xFFFFFFFF;

    private static readonly object Sync = new object();

    private static uint _controllerIndex = NoController;
    private static volatile bool _shutdown;
    private static Thread? _workerThread;

    private static string _bridgePath = string.Empty;
    private static string _lastBridgeText = string.Empty;

    private static bool _patternActive;
    private static long _patternStartMs;
    private static string _activePatternName = string.Empty;
    private static float _activeScale = 1.0f;

    private readonly struct HapticSegment
    {
        public readonly int EndMs;
        public readonly float Left;
        public readonly float Right;

        public HapticSegment(int endMs, float left, float right)
        {
            EndMs = endMs;
            Left = left;
            Right = right;
        }
    }

    private static readonly HapticSegment[] RoarPattern =
    {
        new HapticSegment(240,  0.34f, 0.16f),
        new HapticSegment(600,  0.60f, 0.29f),
        new HapticSegment(1240, 0.92f, 0.54f),
        new HapticSegment(1960, 0.84f, 0.47f),
        new HapticSegment(2560, 0.66f, 0.33f),
        new HapticSegment(3000, 0.46f, 0.22f),
        new HapticSegment(3300, 0.22f, 0.09f),
    };

    private static readonly HapticSegment[] HeavyLandPattern =
    {
        new HapticSegment(65,  1.00f, 0.55f),
        new HapticSegment(135, 0.80f, 0.34f),
        new HapticSegment(225, 0.46f, 0.15f),
        new HapticSegment(300, 0.22f, 0.06f),
    };

    private static readonly HapticSegment[] PlayerHitPattern =
    {
        new HapticSegment(55,  1.00f, 1.00f),
        new HapticSegment(125, 1.00f, 0.62f),
        new HapticSegment(215, 0.78f, 0.30f),
        new HapticSegment(315, 0.42f, 0.12f),
        new HapticSegment(390, 0.20f, 0.05f),
    };

    private static readonly HapticSegment[] PlayerAttackHitPattern =
    {
        new HapticSegment(42,  0.66f, 1.00f),
        new HapticSegment(100, 1.00f, 0.54f),
        new HapticSegment(170, 0.72f, 0.24f),
        new HapticSegment(245, 0.36f, 0.10f),
        new HapticSegment(305, 0.16f, 0.04f),
    };

    private static readonly HapticSegment[] PlayerLandPattern =
    {
        new HapticSegment(60,  1.00f, 0.58f),
        new HapticSegment(145, 0.92f, 0.32f),
        new HapticSegment(250, 0.62f, 0.16f),
        new HapticSegment(360, 0.34f, 0.08f),
        new HapticSegment(450, 0.14f, 0.03f),
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct XInputGamepad
    {
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short ThumbLX;
        public short ThumbLY;
        public short ThumbRX;
        public short ThumbRY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XInputState
    {
        public uint PacketNumber;
        public XInputGamepad Gamepad;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XInputVibration
    {
        public ushort LeftMotorSpeed;
        public ushort RightMotorSpeed;
    }

    [DllImport("xinput1_4.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern uint XInputGetState(uint userIndex, out XInputState state);

    [DllImport("xinput1_4.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern uint XInputSetState(uint userIndex, ref XInputVibration vibration);

    [PluginEntryPoint]
    public static void Main()
    {
        string gameDir = Environment.ProcessPath != null
            ? Path.GetDirectoryName(Environment.ProcessPath) ?? Environment.CurrentDirectory
            : Environment.CurrentDirectory;

        string dataDir = Path.Combine(gameDir, "reframework", "data");
        Directory.CreateDirectory(dataDir);
        _bridgePath = Path.Combine(dataDir, "mhr_haptics_event.txt");

        FindController();

        _shutdown = false;
        _workerThread = new Thread(WorkerLoop)
        {
            IsBackground = true,
            Name = "MHR Immersive Haptics"
        };
        _workerThread.Start();

        API.LogInfo("[MHR Immersive Haptics] v1.0.0 loaded.");
    }

    [PluginExitPoint]
    public static void OnUnload()
    {
        _shutdown = true;
        StopPattern();

        try
        {
            _workerThread?.Join(500);
        }
        catch
        {
            // Shutdown should never block game exit.
        }
    }

    private static void WorkerLoop()
    {
        long lastBridgePoll = 0;

        while (!_shutdown)
        {
            long now = Environment.TickCount64;

            if (now - lastBridgePoll >= 15)
            {
                lastBridgePoll = now;
                PollBridge();
            }

            RenderPattern(now);
            Thread.Sleep(4);
        }
    }

    private static void PollBridge()
    {
        try
        {
            if (!File.Exists(_bridgePath))
                return;

            string text = File.ReadAllText(_bridgePath).Trim();
            if (string.IsNullOrEmpty(text))
                return;

            bool changed;

            lock (Sync)
            {
                changed = text != _lastBridgeText;
                if (changed)
                    _lastBridgeText = text;
            }

            if (!changed)
                return;

            string[] parts = text.Split('|');
            if (parts.Length < 2)
                return;

            string eventName = parts[1].Trim();
            string detail = parts.Length >= 4 ? parts[3] : string.Empty;

            HandleEvent(eventName, detail);
        }
        catch (IOException)
        {
            // The Lua side may be replacing the bridge file at this exact moment.
        }
        catch
        {
            // Keep haptics non-fatal if the bridge is temporarily unavailable.
        }
    }

    private static float ParseStrength(string detail)
    {
        if (string.IsNullOrWhiteSpace(detail))
            return 1.0f;

        foreach (string field in detail.Split(','))
        {
            string trimmed = field.Trim();

            if (!trimmed.StartsWith("strength=", StringComparison.OrdinalIgnoreCase))
                continue;

            string number = trimmed.Substring("strength=".Length);

            if (float.TryParse(
                number,
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out float parsed))
            {
                return Math.Clamp(parsed, 0.0f, 1.0f);
            }
        }

        return 1.0f;
    }

    private static void HandleEvent(string eventName, string detail)
    {
        float strength = ParseStrength(detail);
        if (strength <= 0.01f)
            return;

        switch (eventName.ToUpperInvariant())
        {
            case "ROAR":
                StartPattern("ROAR", strength);
                break;

            case "HEAVY_LAND":
                StartPattern("HEAVY_LAND", strength);
                break;

            case "PLAYER_HIT":
                StartPattern(
                    "PLAYER_HIT",
                    Math.Clamp(0.82f + (strength * 0.18f), 0.82f, 1.00f)
                );
                break;

            case "PLAYER_ATTACK_HIT_WHITE":
                StartPattern(
                    "PLAYER_ATTACK_HIT",
                    Math.Clamp(0.36f + (strength * 0.20f), 0.40f, 0.56f)
                );
                break;

            case "PLAYER_ATTACK_HIT_RED":
                StartPattern(
                    "PLAYER_ATTACK_HIT",
                    Math.Clamp(0.60f + (strength * 0.20f), 0.66f, 0.80f)
                );
                break;

            case "PLAYER_ATTACK_HIT":
                // Compatibility with older Lua runtimes.
                StartPattern("PLAYER_ATTACK_HIT", 0.52f);
                break;

            case "PLAYER_LAND":
                StartPattern("PLAYER_LAND", strength);
                break;
        }
    }

    private static HapticSegment[] GetPattern(string name)
    {
        return name switch
        {
            "ROAR" => RoarPattern,
            "HEAVY_LAND" => HeavyLandPattern,
            "PLAYER_HIT" => PlayerHitPattern,
            "PLAYER_ATTACK_HIT" => PlayerAttackHitPattern,
            "PLAYER_LAND" => PlayerLandPattern,
            _ => PlayerAttackHitPattern
        };
    }

    private static void StartPattern(string name, float scale)
    {
        if (_controllerIndex == NoController)
        {
            FindController();
            if (_controllerIndex == NoController)
                return;
        }

        lock (Sync)
        {
            _activePatternName = name;
            _activeScale = Math.Clamp(scale, 0.0f, 1.0f);
            _patternStartMs = Environment.TickCount64;
            _patternActive = true;
        }
    }

    private static void RenderPattern(long now)
    {
        string name;
        long start;
        float scale;
        bool active;
        uint controller;

        lock (Sync)
        {
            active = _patternActive;
            name = _activePatternName;
            start = _patternStartMs;
            scale = _activeScale;
            controller = _controllerIndex;
        }

        if (!active || controller == NoController)
            return;

        HapticSegment[] pattern = GetPattern(name);
        long elapsed = now - start;

        if (elapsed >= pattern[pattern.Length - 1].EndMs)
        {
            StopPattern();
            return;
        }

        HapticSegment segment = pattern[pattern.Length - 1];

        foreach (HapticSegment candidate in pattern)
        {
            if (elapsed < candidate.EndMs)
            {
                segment = candidate;
                break;
            }
        }

        float left = Math.Clamp(segment.Left * scale, 0.0f, 1.0f);
        float right = Math.Clamp(segment.Right * scale, 0.0f, 1.0f);

        ApplyRumble(
            controller,
            (ushort)(left * ushort.MaxValue),
            (ushort)(right * ushort.MaxValue)
        );
    }

    private static void StopPattern()
    {
        uint controller;

        lock (Sync)
        {
            _patternActive = false;
            _activePatternName = string.Empty;
            _activeScale = 1.0f;
            _patternStartMs = 0;
            controller = _controllerIndex;
        }

        if (controller != NoController)
            ApplyRumble(controller, 0, 0);
    }

    private static void FindController()
    {
        uint found = NoController;

        for (uint i = 0; i < 4; i++)
        {
            if (XInputGetState(i, out XInputState state) == ErrorSuccess)
            {
                found = i;
                break;
            }
        }

        lock (Sync)
        {
            _controllerIndex = found;
        }
    }

    private static void ApplyRumble(uint controller, ushort left, ushort right)
    {
        var vibration = new XInputVibration
        {
            LeftMotorSpeed = left,
            RightMotorSpeed = right
        };

        XInputSetState(controller, ref vibration);
    }
}
