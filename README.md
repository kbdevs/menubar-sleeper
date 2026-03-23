# MenuBarSleep

A simple macOS menu bar app that automatically keeps your Mac awake only while an OpenCode session is actively running.

## Features

- **True activity tracking** - Reads OpenCode session state instead of just checking whether the app is open
- **Sleep prevention only when needed** - Starts `caffeinate` while OpenCode is busy and stops it when all sessions go idle or finish
- **Manual override** - Switch between `Auto`, `On`, and `Off` from the menu bar at any time
- **Menu bar status** - Shows a coffee cup while sleep is being prevented, moon when sleep is allowed
- **Manual refresh** - Lets you force an immediate process scan from the menu

## OpenCode Integration

The app checks the live local OpenCode server at `http://127.0.0.1:4096` to detect whether recent sessions are actively busy.

If present, it also reads the optional plugin marker directory at `~/.config/opencode/menubarsleep/active-sessions/` as an extra signal source.

## Installation

1. Download the latest release from the [Releases](https://github.com/kbdevs/menubar-sleeper/releases) page
2. Open the `.dmg` file
3. Drag `MenuBarSleep.app` to your Applications folder
4. Launch the app from Applications

## Usage

Once launched, the app appears in your menu bar:

- **Coffee cup icon** - One or more OpenCode sessions are actively working and the app is preventing sleep
- **Moon icon** - No OpenCode sessions are actively running, so normal sleep behavior is allowed

Click the icon to:

- See the current OpenCode monitoring status
- Switch sleep behavior between `Auto`, `On`, and `Off`
- See how many active OpenCode sessions are detected
- Refresh detection immediately
- Quit the app

## Building from Source

```bash
make
make install
```

Or build a release package:

```bash
make
hdiutil create -volname "MenuBarSleep" -srcapp build/MenuBarSleep.app -ov -format UDZO MenuBarSleep.dmg
```

## Requirements

- macOS 11.0 (Big Sur) or later

## License

MIT
