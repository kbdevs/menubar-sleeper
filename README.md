# MenuBarSleep

A simple macOS menu bar app that lets you quickly toggle sleep prevention on your Mac.

## Features

- **Menu bar icon** - Shows a coffee cup when sleep is disabled, moon when sleep is enabled
- **One-click toggle** - Easily enable or disable sleep with a single click
- **Auto-restore** - Automatically re-enables sleep when you quit the app (if it was disabled)

## Installation

1. Download the latest release from the [Releases](https://github.com/kbdevs/menubar-sleeper/releases) page
2. Open the `.dmg` file
3. Drag `MenuBarSleep.app` to your Applications folder
4. Launch the app from Applications

## Usage

Once launched, the app appears in your menu bar:
- **Coffee cup icon** - Sleep is disabled (your Mac won't sleep)
- **Moon icon** - Sleep is enabled (normal behavior)

Click the icon to:
- See current sleep status
- Toggle sleep on/off
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
