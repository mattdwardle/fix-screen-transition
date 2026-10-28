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
| Display **appears** (you switched here) | Starts calling ("paging") the Magic Keyboard over Bluetooth, and keeps calling until it connects. |
| Display **disappears** (you switched away) | Waits 4 seconds, then tells the Logitech mouse to jump to the other Mac's Easy-Switch channel and **forgets** the Magic Keyboard (like "Forget This Device" in Bluetooth settings), so it moves to the other Mac. |

**Why the timing matters:** a Magic Keyboard only answers a Mac's connection request for a few seconds right after it's released by another Mac. The rest of the time it ignores requests and only reconnects to the Mac it was last on. So the Mac you switch to has to be calling the keyboard *before* the Mac you left lets go. The 4-second pause gives it time to notice the display and start. A merely disconnected keyboard goes straight back to the Mac it was just on, so the Mac you leave forgets it instead. It then moves to the other Mac. Later, when the other Mac forgets it in turn, it reconnects to this Mac by itself, without re-pairing. (Tested with a Magic Keyboard with Touch ID; if yours doesn't come back on its own, re-pair it in Bluetooth settings.)

**The mouse sleeps.** The MX Anywhere drops off Bluetooth after a few seconds without movement, so it may not be there to receive the switch command when the display leaves. A Mac without the display therefore checks every second and sends the mouse away as soon as it wakes up. At worst, you nudge the mouse after switching and it moves over within a second.

As a safety net, if a Mac without the display finds itself holding the keyboard, it forgets it again, at most every 6 seconds.

With the helper on both Macs, the switch's button moves the display, keyboard and mouse together.

It's a single Swift file with no dependencies. It uses macOS's own `IOBluetooth` for the keyboard, `IOKit` HID for the mouse (Logitech HID++ 2.0 `CHANGE_HOST`, feature `0x1814`) and `CoreGraphics` display notifications.

## Requirements

- macOS on Apple Silicon or Intel, with the Xcode Command Line Tools (`xcode-select --install`) to compile it.
- A Magic Keyboard (any model, including Touch ID) **paired over Bluetooth with both Macs**.
- A Logitech mouse with Easy-Switch that supports HID++ `CHANGE_HOST`, connected over Bluetooth to both Macs. Tested with an **MX Anywhere 3S**. For other models, see [Using a different mouse](#using-a-different-mouse).
- Each Mac on its own Easy-Switch channel.
- **The keyboard not plugged into the display.** Pressing the switch briefly cuts the display's USB power, which knocks a plugged-in keyboard off Bluetooth before the helper can hand it over, and it can end up on neither Mac. Run it on battery (a charge lasts about a month) and charge it from somewhere else.

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
4. Give it **Input Monitoring** access, which it needs to talk to the mouse: **System Settings → Privacy & Security → Input Monitoring**, and turn on `kvm-follow`. If it isn't listed, click **+**, press **⌘⇧G**, enter `~/.local/bin/kvm-follow` and add it. Then restart the helper:

   ```sh
   launchctl kickstart -k gui/$UID/com.kvm-follow
   ```

   If you have an Apple Development signing certificate (for example, from signing in to Xcode), the installer signs the tool with it, and the permission survives updates. Otherwise, re-running `./install.sh` rebuilds the tool and you'll need to allow it again: remove the old `kvm-follow` entry with **−**, then add it again.

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
[2026-10-28T06:51:02Z] display not here -> handing keyboard and mouse to the other Mac
[2026-10-28T06:51:04Z] keyboard: disconnect -> ok
[2026-10-28T06:51:04Z] mouse: switch to channel 2 -> sent
```

## Uninstall

```sh
./uninstall.sh
```

This stops the helper and removes the binary, LaunchAgent and config.

## Limitations

- **Touch ID** on the Magic Keyboard only works with the Mac it was last connected to by a cable that carries data. Over a video-only switch that never happens, so Touch ID will likely work on only one Mac. Typing works on both. This is an Apple restriction, not something software can work around.
- **Switching takes a few seconds** while the keyboard is released and reconnected.
- **Only one external display is expected.** The helper reacts to any external display coming or going. If you use other monitors, set `"displayName"` in the config to part of the display's ID shown by `kvm-follow status` (for example, `"vendor-0610"` for Apple displays).
- **The mouse is sent, never pulled.** A Logitech mouse can only be told to switch by the Mac it's currently connected to, so each Mac sends it away when the display leaves. If the helper isn't running on the Mac you're leaving, press the Easy-Switch button.
- **A Mac without the display won't keep the keyboard or mouse.** If you take one MacBook away from the desk and want to use the same mouse with it, stop the helper there first: `launchctl bootout gui/$UID/com.kvm-follow` (it restarts at next login, or run `./install.sh` again).
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
