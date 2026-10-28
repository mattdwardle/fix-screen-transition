// kvm-follow: make a Bluetooth Magic Keyboard and a Logitech mouse follow a
// video-only USB-C switch between two Macs.
//
// When the external display disappears (you switched away), this Mac drops
// the keyboard so it reconnects to the other Mac, and tells the mouse to jump
// to the other Mac's Easy-Switch channel. When the display appears, this Mac
// pulls the keyboard back over Bluetooth.

import CoreGraphics
import Foundation
import IOBluetooth
import IOKit.hid

// MARK: - Config

struct Config: Codable {
    var keyboardAddress: String      // e.g. "aa-bb-cc-dd-ee-ff"
    var mouseProductID: Int          // e.g. 0xB037 for MX Anywhere 3S over BLE
    var otherMacMouseChannel: Int    // 1...3, the Easy-Switch channel of the OTHER Mac
    var displayName: String?         // optional: only react to a display whose name contains this

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kvm-follow/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            fail("No config at \(path.path). Run: kvm-follow setup <other-mac-channel>")
        }
        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.path)
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
    fflush(stdout)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Keyboard (IOBluetooth)

func pairedDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
}

func findMagicKeyboard() -> IOBluetoothDevice? {
    // Apple keyboards report major class 0x05 (peripheral), minor keyboard bit 0x10.
    pairedDevices().first {
        ($0.name ?? "").localizedCaseInsensitiveContains("keyboard")
            && $0.deviceClassMajor == 0x05
    }
}

func keyboard(_ cfg: Config) -> IOBluetoothDevice? {
    IOBluetoothDevice(addressString: cfg.keyboardAddress)
}

func keyboardDisconnect(_ cfg: Config) {
    guard let kb = keyboard(cfg) else { return log("keyboard: not found") }
    guard kb.isConnected() else { return log("keyboard: already disconnected") }
    let r = kb.closeConnection()
    log("keyboard: disconnect -> \(r == kIOReturnSuccess ? "ok" : String(format: "0x%x", r))")
}

func keyboardConnect(_ cfg: Config, attempts: Int = 8) {
    guard let kb = keyboard(cfg) else { return log("keyboard: not found") }
    for i in 1...attempts {
        if kb.isConnected() { return log("keyboard: connected") }
        let r = kb.openConnection()
        if r == kIOReturnSuccess && kb.isConnected() { return log("keyboard: connected (attempt \(i))") }
        // The other Mac may still be holding it for a moment; back off and retry.
        Thread.sleep(forTimeInterval: 1.0)
    }
    log("keyboard: could not connect after \(attempts) attempts")
}

// MARK: - Mouse (Logitech HID++ 2.0 over BLE)

let logitechVendor = 0x046D
let hidppUsagePage = 0xFF43
let hidppUsage = 0x0202
let hidppLongReport: UInt8 = 0x11
let hidppDevice: UInt8 = 0xFF
let softwareID: UInt8 = 0x0A

final class HIDPP {
    let device: IOHIDDevice
    private var inbox: [[UInt8]] = []
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init?(productID: Int) {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: logitechVendor,
            kIOHIDProductIDKey: productID,
            kIOHIDDeviceUsagePageKey: hidppUsagePage,
            kIOHIDDeviceUsageKey: hidppUsage,
        ] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else {
            return nil
        }
        device = dev
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { ctx, _, _, _, _, report, len in
            let me = Unmanaged<HIDPP>.fromOpaque(ctx!).takeUnretainedValue()
            me.inbox.append(Array(UnsafeBufferPointer(start: report, count: len)))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buf.deallocate()
    }

    /// Send a long HID++ 2.0 request. If `expectReply`, wait for the matching response.
    func request(feature: UInt8, function: UInt8, params: [UInt8], expectReply: Bool = true) -> [UInt8]? {
        var msg = [UInt8](repeating: 0, count: 20)
        msg[0] = hidppLongReport
        msg[1] = hidppDevice
        msg[2] = feature
        msg[3] = (function << 4) | softwareID
        for (i, p) in params.prefix(16).enumerated() { msg[4 + i] = p }
        inbox.removeAll()
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(hidppLongReport), msg, msg.count)
        guard r == kIOReturnSuccess else {
            log(String(format: "mouse: write failed 0x%x", r))
            return nil
        }
        guard expectReply else { return [] }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            if let reply = inbox.first(where: { $0.count >= 4 && ($0[2] == feature || $0[2] == 0xFF) && $0[3] == msg[3] }) {
                if reply[2] == 0xFF { log("mouse: HID++ error \(reply.prefix(7).map { String(format: "%02x", $0) })"); return nil }
                return Array(reply.dropFirst(4))
            }
        }
        log("mouse: no reply")
        return nil
    }

    /// Root feature getFeature(featureID) -> feature index on this device.
    func featureIndex(_ featureID: UInt16) -> UInt8? {
        guard let r = request(feature: 0x00, function: 0, params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]),
              let idx = r.first, idx != 0 else { return nil }
        return idx
    }

    /// CHANGE_HOST (0x1814) getHostInfo -> (hostCount, currentHost), 0-based.
    func hostInfo() -> (count: Int, current: Int)? {
        guard let idx = featureIndex(0x1814), let r = request(feature: idx, function: 0, params: []) else { return nil }
        return (Int(r[0]), Int(r[1]))
    }

    /// CHANGE_HOST setCurrentHost(host), 0-based. The device leaves immediately, so no reply.
    func setHost(_ host: Int) -> Bool {
        guard let idx = featureIndex(0x1814) else { log("mouse: CHANGE_HOST not supported"); return false }
        return request(feature: idx, function: 1, params: [UInt8(host)], expectReply: false) != nil
    }
}

func mouseSwitch(_ cfg: Config) {
    guard let m = HIDPP(productID: cfg.mouseProductID) else { return log("mouse: not connected here") }
    let ok = m.setHost(cfg.otherMacMouseChannel - 1)
    log("mouse: switch to channel \(cfg.otherMacMouseChannel) -> \(ok ? "sent" : "failed")")
}

// MARK: - Display watching

func displayName(_ id: CGDirectDisplayID) -> String {
    String(format: "vendor-%04x-model-%04x", CGDisplayVendorNumber(id), CGDisplayModelNumber(id))
}

func externalDisplays(_ cfg: Config) -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).filter { id in
        guard CGDisplayIsBuiltin(id) == 0 else { return false }
        guard let want = cfg.displayName else { return true }
        return displayName(id).localizedCaseInsensitiveContains(want)
    }
}

final class Watcher {
    let cfg: Config
    var present: Bool
    var pending: DispatchWorkItem?

    init(cfg: Config) {
        self.cfg = cfg
        present = !externalDisplays(cfg).isEmpty
    }

    func start() {
        log("watching; external display \(present ? "present" : "absent")")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Unmanaged<Watcher>.fromOpaque(ctx!).takeUnretainedValue().changed()
        }, ctx)
        RunLoop.main.run()
    }

    func changed() {
        // Reconfiguration fires in bursts; settle before acting.
        pending?.cancel()
        let work = DispatchWorkItem { [self] in
            let now = !externalDisplays(cfg).isEmpty
            guard now != present else { return }
            present = now
            if now { arrived() } else { left() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func left() {
        log("display left -> handing keyboard and mouse to the other Mac")
        keyboardDisconnect(cfg)
        mouseSwitch(cfg)
    }

    func arrived() {
        log("display arrived -> claiming keyboard")
        // Give the other Mac a moment to drop the keyboard first.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [cfg] in keyboardConnect(cfg) }
    }
}

// MARK: - CLI

func usage() -> Never {
    fail("""
    usage: kvm-follow <command>
      setup <other-mac-channel>   detect keyboard + mouse and write config
      status                      show config, keyboard, mouse and display state
      watch                       run the watcher (used by the LaunchAgent)
      leave                       do what happens when the display leaves
      arrive                      do what happens when the display arrives
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "setup":
    guard args.count == 2, let ch = Int(args[1]), (1...3).contains(ch) else { usage() }
    guard let kb = findMagicKeyboard(), let addr = kb.addressString else {
        fail("Couldn't find a paired Bluetooth keyboard. Pair the Magic Keyboard with this Mac first.")
    }
    let cfg = Config(keyboardAddress: addr, mouseProductID: 0xB037, otherMacMouseChannel: ch, displayName: nil)
    do { try cfg.save() } catch { fail("Couldn't write config: \(error)") }
    print("Keyboard: \(kb.name ?? "?") (\(addr))")
    print("Other Mac's mouse channel: \(ch)")
    print("Wrote \(Config.path.path)")

case "status":
    let cfg = Config.load()
    let kb = keyboard(cfg)
    print("keyboard  \(kb?.name ?? "not found")  \(kb?.isConnected() == true ? "connected here" : "not connected here")")
    if let m = HIDPP(productID: cfg.mouseProductID) {
        if let h = m.hostInfo() {
            print("mouse     connected here, channel \(h.current + 1) of \(h.count)")
        } else {
            print("mouse     connected here, host info unavailable")
        }
    } else {
        print("mouse     not connected here")
    }
    let ext = externalDisplays(cfg)
    print("display   \(ext.isEmpty ? "no external display" : ext.map(displayName).joined(separator: ", "))")
    print("other Mac uses mouse channel \(cfg.otherMacMouseChannel)")

case "watch":
    Watcher(cfg: Config.load()).start()

case "leave":
    let cfg = Config.load()
    keyboardDisconnect(cfg)
    mouseSwitch(cfg)

case "arrive":
    keyboardConnect(Config.load())

default:
    usage()
}
