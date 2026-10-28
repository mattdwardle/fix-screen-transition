# kvm-follow

Make a Bluetooth Magic Keyboard and a Logitech mouse follow a USB-C display switch between two Macs.

## The problem

Two MacBooks share one monitor, such as an Apple Studio Display, through a USB-C switch. Pressing the switch moves the screen to the other Mac, but:

- **The Magic Keyboard stays on the old Mac.** It may be plugged into the display, but many switches (for example, Cable Matters 20 Gbps USB-C switches) carry video only, not the display's USB data. The cable only charges the keyboard, which keeps typing over Bluetooth to whichever Mac it was already connected to.
- **The Logitech mouse stays on the old Mac** until you press its Easy-Switch button.

You can check whether this applies to you: with the keyboard plugged into the display, open **System Settings → Bluetooth** and disconnect the keyboard. If typing stops, or the keyboard jumps to your other Mac, the cable isn't carrying data.

## What this does

A small background helper runs on each Mac and watches for the external display to appear or disappear.

| Event | What this Mac does |
|---|---|
| Display **disappears** (you switched away) | Disconnects the Magic Keyboard over Bluetooth, so it reconnects to the other Mac. Tells the Logitech mouse to jump to the other Mac's Easy-Switch channel. |
| Display **appears** (you switched here) | Connects the Magic Keyboard over Bluetooth, retrying for a few seconds while the other Mac lets go. |

With the helper on both Macs, the switch's button moves the display, keyboard and mouse together.

It's a single Swift file with no dependencies. It uses macOS's own `IOBluetooth` for the keyboard, `IOKit` HID for the mouse (Logitech HID++ 2.0 `CHANGE_HOST`, feature `0x1814`) and `CoreGraphics` display notifications.

## Requirements

- macOS on Apple Silicon or Intel, with the Xcode Command Line Tools (`xcode-select --install`) to compile it.
- A Magic Keyboard (any model, including Touch ID) **paired over Bluetooth with both Macs**.
- A Logitech mouse with Easy-Switch that supports HID++ `CHANGE_HOST`, connected over Bluetooth to both Macs. Tested with an **MX Anywhere 3S**. For other models, see [Using a different mouse](#using-a-different-mouse).
- Each Mac on its own Easy-Switch channel.

## Install

Do this on **both** Macs.

1. Find out which Easy-Switch channel (1, 2 or 3) each Mac uses. The lights are under the mouse.
2. Clone the repo and run the installer with the **other** Mac's channel:

   ```sh
   git clone https://github.com/mattdwardle/fix-screen-transition.git
   cd fix-screen-transition
   ./install.sh <other-macs-channel>
   ```

   Example: if Mac A is channel 3 and Mac B is channel 2, run `./install.sh 2` on Mac A and `./install.sh 3` on Mac B.

3. If macOS asks whether `kvm-follow` may use Bluetooth, click **Allow**.

The installer:
- compiles the tool to `~/.local/bin/kvm-follow`
- writes your keyboard's address and the other Mac's channel to `~/.config/kvm-follow/config.json`
- adds a LaunchAgent (`~/Library/LaunchAgents/com.kvm-follow.plist`) so it starts at login and restarts if it stops

## Usage

After installing, just press your switch. You can also run the tool by hand:

```sh
kvm-follow status     # keyboard, mouse, display and config state
kvm-follow leave      # hand the keyboard and mouse to the other Mac now
kvm-follow arrive     # take the keyboard back now
kvm-follow setup 2    # rewrite the config (argument = the other Mac's channel)
```

(`~/.local/bin` may not be on your `PATH`; use the full path if needed.)

Logs go to `~/Library/Logs/kvm-follow.log`:

```
[2026-10-28T06:44:18Z] watching; external display present
[2026-10-28T06:51:02Z] display left -> handing keyboard and mouse to the other Mac
[2026-10-28T06:51:02Z] keyboard: disconnect -> ok
[2026-10-28T06:51:03Z] mouse: switch to channel 2 -> sent
```

## Uninstall

```sh
./uninstall.sh
```

This stops the helper and removes the binary, LaunchAgent and config.

## Limitations

- **Touch ID** on the Magic Keyboard only works with the Mac it was last connected to by a cable that carries data. Over a video-only switch that never happens, so Touch ID will likely work on only one Mac. Typing works on both. This is an Apple restriction, not something software can work around.
- **Switching takes about 1–3 seconds** while Bluetooth reconnects.
- **Only one external display is expected.** The helper reacts to any external display coming or going. If you use other monitors, set `"displayName"` in the config to part of the display's ID shown by `kvm-follow status` (for example, `"vendor-0610"` for Apple displays).
- **The mouse is sent, never pulled.** A Logitech mouse can only be told to switch by the Mac it's currently connected to, so each Mac sends it away when the display leaves. If the helper isn't running on the Mac you're leaving, press the Easy-Switch button.
- **If the switch already carries USB data** to the display (some Thunderbolt switches do), you probably don't need this: the keyboard will work over its cable.

## Using a different mouse

The mouse is matched by Logitech's vendor ID (`0x046D`) and a product ID, which defaults to `0xB037` (MX Anywhere 3S over Bluetooth). To use another Logitech Bluetooth mouse, find its product ID:

```sh
system_profiler SPBluetoothDataType | grep -A4 "MX"
```

Then set `"mouseProductID"` in `~/.config/kvm-follow/config.json` to that number in decimal (for example, `0xB037` is `45111`), and restart:

```sh
launchctl kickstart -k gui/$UID/com.kvm-follow
```

Check it with `kvm-follow status`, which should report the mouse's current channel. Mice connected through a Logi Bolt or Unifying receiver aren't supported.

## License

[MIT](LICENSE)
