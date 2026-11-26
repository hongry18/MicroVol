# MicroVol

MicroVol is a lightweight native macOS menu bar utility for Apple Silicon Macs that controls external monitor hardware volume via DDC/CI and system audio volume in 1-step increments.

It was built as a zero-bloat alternative when you only need precise keyboard volume control on an external DisplayPort or HDMI monitor without display management overhead or background CPU usage.

## Features

- Controls external monitor speaker volume from 0 to 100 in 1-step increments via DDC/CI VCP 0x62 on Apple Silicon Macs.
- Automatically switches to 1% CoreAudio volume control when using built-in speakers, headphones, or Bluetooth audio.
- Intercepts standard macOS Volume Up, Volume Down, and Mute media keys with 0.0% idle CPU usage.
- Displays a clean native floating HUD on the active screen where the cursor is located.
- Allows changing step size between 1, 2, and 5 from the menu bar.

## Requirements

- Apple Silicon Mac running macOS 13 or later
- External monitor with DDC/CI enabled over DisplayPort, USB-C, or HDMI
- Xcode Command Line Tools if building from source

## Build and Install

```zsh
git clone https://github.com/hongry18/MicroVol.git
cd MicroVol
./build.sh
cp -R build/MicroVol.app /Applications/
open /Applications/MicroVol.app
```

## Permissions

On first launch, macOS will prompt for Accessibility permission so MicroVol can intercept the keyboard media volume keys.

Go to System Settings > Privacy & Security > Accessibility and enable MicroVol.

If you download a prebuilt binary from GitHub Releases and macOS blocks it as an unidentified developer, clear the quarantine attribute once:

```zsh
xattr -cr /Applications/MicroVol.app
```

To launch automatically when logging in, add MicroVol in System Settings > General > Login Items & Extensions.

## License

MIT
