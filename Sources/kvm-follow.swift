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

/// Page the keyboard back-to-back until it connects or `deadline` passes.
///
/// A Magic Keyboard only answers a Mac's connection request for a moment right after
/// another Mac releases it; the rest of the time each request times out after ~15 s.
/// So the Mac that wants it has to already be paging when the other lets go.
/// This blocks, so the watcher runs it in a child process (`kvm-follow page`).
/// IOBluetooth's async open stalled after one attempt inside the watcher.
func pageKeyboard(_ cfg: Config, until deadline: Date = .distantFuture) -> Bool {
    guard let kb = keyboard(cfg) else { log("keyboard: not found"); return false }
    log("keyboard: paging")
    while Date() < deadline {
        if kb.isConnected() { log("keyboard: connected"); return true }
        _ = kb.openConnection()
        Thread.sleep(forTimeInterval: 0.2)
    }
    log("keyboard: gave up paging")
    return false
}

/// Runs `kvm-follow page` in the background while the display is here.
final class KeyboardPager {
    let kb: IOBluetoothDevice
    private var child: Process?

    init(_ kb: IOBluetoothDevice) { self.kb = kb }

    func start() {
        guard child?.isRunning != true, !kb.isConnected() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["page"]
        do { try p.run(); child = p } catch { log("keyboard: couldn't start pager: \(error)") }
    }

    func stop() {
        guard let p = child, p.isRunning else { return }
        p.terminate()
        child = nil
        log("keyboard: stopped paging")
    }
}

// MARK: - Mouse (Logitech HID++ 2.0 over BLE)

let logitechVendor = 0x046D
let hidppUsagePage = 0xFF43
let hidppUsage = 0x0202
let hidppLongReport: UInt8 = 0x11
let hidppDevice: UInt8 = 0xFF
let softwareID: UInt8 = 0x0A

final class HIDPP {
    static var warnedOpen = false
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
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            // kIOReturnNotPermitted means Input Monitoring hasn't been granted.
            if !HIDPP.warnedOpen {
                HIDPP.warnedOpen = true
                log(String(format: "mouse: found but can't open it (0x%x)%@", r,
                           r == kIOReturnNotPermitted ? " - allow kvm-follow under Input Monitoring" : ""))
            }
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
    let pager: KeyboardPager
    var present: Bool
    var pending: DispatchWorkItem?
    var lastRelease = Date.distantPast

    init(cfg: Config) {
        guard let kb = keyboard(cfg) else { fail("keyboard \(cfg.keyboardAddress) not found") }
        self.cfg = cfg
        pager = KeyboardPager(kb)
        present = !externalDisplays(cfg).isEmpty
    }

    func start() {
        log("watching; external display \(present ? "present" : "absent")")
        // Talking to the mouse needs Input Monitoring; this shows the prompt the first time.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            log("mouse: Input Monitoring not granted yet - requesting it")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Unmanaged<Watcher>.fromOpaque(ctx!).takeUnretainedValue().changed()
        }, ctx)
        if present { arrived() } else { left() }
        // Safety net: catch missed display notifications, keep paging while the display
        // is here, and occasionally re-release a keyboard this Mac picked back up without it.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [self] _ in
            reconcile()
            if present {
                pager.start()
            } else if Date().timeIntervalSince(lastRelease) > 20, pager.kb.isConnected() {
                log("display not here but keyboard is -> releasing again")
                lastRelease = Date()
                keyboardDisconnect(cfg)
            }
        }
        // The mouse drops off Bluetooth when it sleeps, so it may not be here at the moment
        // the display leaves. Send it away as soon as it wakes up on a Mac without the display.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            guard !present, Date().timeIntervalSince(lastRelease) > 1.5,
                  HIDPP(productID: cfg.mouseProductID) != nil else { return }
            log("display not here but mouse is -> sending mouse away")
            mouseSwitch(cfg)
        }
        RunLoop.main.run()
    }

    func changed() {
        // Reconfiguration fires in bursts; settle before acting.
        pending?.cancel()
        let work = DispatchWorkItem { [self] in reconcile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func reconcile() {
        let now = !externalDisplays(cfg).isEmpty
        guard now != present else { return }
        present = now
        if now { arrived() } else { left() }
    }

    func left() {
        log("display not here -> handing keyboard and mouse to the other Mac")
        pager.stop()
        lastRelease = Date()
        // Give the other Mac a moment to notice the display and start paging the keyboard,
        // so it's listening during the short window after we let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard !present else { return }
            release()
        }
    }

    func release() {
        lastRelease = Date()
        keyboardDisconnect(cfg)
        mouseSwitch(cfg)
    }

    func arrived() {
        log("display here -> claiming keyboard")
        pager.start()
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
    exit(pageKeyboard(Config.load(), until: Date().addingTimeInterval(60)) ? 0 : 1)

case "page":
    exit(pageKeyboard(Config.load()) ? 0 : 1)

default:
    usage()
}
