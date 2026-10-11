import SwiftUI
import Darwin

@main
struct PowerSwitchApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

let helperPort = 47823

enum PCState { case unknown, online, offline, wrongCode }

struct ContentView: View {
    @AppStorage("host") private var host = ""
    @AppStorage("mac") private var mac = ""
    @AppStorage("code") private var code = ""
    @State private var state = PCState.unknown
    @State private var message = ""
    @State private var showSettings = false
    @State private var confirmShutdown = false
    @Environment(\.scenePhase) private var phase
    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                Spacer()
                status
                Spacer()
                Text(message).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).frame(minHeight: 36)
                bigButton("Turn On", "power", .green) { wake() }
                    .disabled(state == .online)
                HStack(spacing: 14) {
                    bigButton("Sleep", "moon.fill", .indigo) { send("sleep", done: "Going to sleep…") }
                    bigButton("Shut Down", "poweroff", .red) { confirmShutdown = true }
                }
                .disabled(state != .online)
            }
            .padding(20)
            .navigationTitle("PowerSwitch")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
            .sheet(isPresented: $showSettings, onDismiss: check) { SettingsView() }
            .confirmationDialog("Shut down the PC?", isPresented: $confirmShutdown, titleVisibility: .visible) {
                Button("Shut Down", role: .destructive) { send("shutdown", done: "Shutting down…") }
            } message: {
                Text("Over Wi-Fi, Turn On can only wake it from Sleep. Use Shut Down only if it's on an Ethernet cable.")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { if host.isEmpty { showSettings = true } else { check() } }
        .onReceive(poll) { _ in if phase == .active && !showSettings { check() } }
    }

    private var status: some View {
        let (label, color): (String, Color) = {
            switch state {
            case .unknown: return (host.isEmpty ? "Not set up" : "Checking…", .gray)
            case .online: return ("PC is on", .green)
            case .offline: return ("PC is off or asleep", .gray)
            case .wrongCode: return ("Wrong pairing code", .orange)
            }
        }()
        return VStack(spacing: 18) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 84, weight: .light))
                .foregroundColor(color)
                .shadow(color: state == .online ? .green.opacity(0.6) : .clear, radius: 24)
            Text(label).font(.title3.weight(.semibold))
            if !host.isEmpty { Text(host).font(.footnote.monospaced()).foregroundColor(.secondary) }
        }
        .animation(.easeInOut, value: state)
    }

    private func bigButton(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.large)
    }

    // MARK: - talking to the PC helper

    private func request(_ path: String, method: String = "GET", _ done: @escaping (Int?) -> Void) {
        guard let url = URL(string: "http://\(host):\(helperPort)/\(path)") else { return done(nil) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
        req.httpMethod = method
        req.setValue(code.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-Key")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async { done((resp as? HTTPURLResponse)?.statusCode) }
        }.resume()
    }

    private func check() {
        guard !host.isEmpty else { state = .unknown; return }
        request("ping") { status in
            state = status == 200 ? .online : status == 401 ? .wrongCode : .offline
            if state == .online, message.hasPrefix("Waking") { message = "" }
        }
    }

    private func send(_ action: String, done: String) {
        request(action, method: "POST") { status in
            switch status {
            case 200: message = done; state = .offline
            case 401: state = .wrongCode
            default: message = "Couldn't reach the PC. Is PowerSwitch running on it?"
            }
        }
    }

    private func wake() {
        guard let macBytes = parseMAC(mac) else { message = "Set the PC's MAC address in settings."; showSettings = true; return }
        message = WakeOnLAN.send(mac: macBytes, host: host)
            ? "Waking… it can take 10–20 seconds."
            : "Couldn't send the wake packet. Are you on the same Wi-Fi as the PC?"
    }
}

func parseMAC(_ text: String) -> [UInt8]? {
    let hex = text.filter(\.isHexDigit)
    guard hex.count == 12 else { return nil }
    return stride(from: 0, to: 12, by: 2).compactMap { i in
        UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)
    }
}

// MARK: - Wake-on-LAN

enum WakeOnLAN {
    /// Sends the magic packet (6×FF + the MAC 16 times) to UDP port 9, both directly to the PC and as broadcasts.
    /// iOS only allows broadcasts for apps with Apple's multicast entitlement, so the direct send is the one that
    /// normally lands: the router (or the sleeping Wi-Fi card's ARP offload) still knows where that address lives.
    static func send(mac: [UInt8], host: String) -> Bool {
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac, count: 16).joined())
        var targets = [host, "255.255.255.255"]
        if let b = wifiBroadcast() { targets.append(b) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var sentAny = false
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            for _ in 0..<3 {
                let n = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if n == packet.count { sentAny = true }
            }
        }
        return sentAny
    }

    /// The Wi-Fi network's broadcast address (e.g. 192.168.7.255 on a /22), from en0.
    static func wifiBroadcast() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == "en0", ifa.ifa_addr.pointee.sa_family == sa_family_t(AF_INET),
                  let dst = ifa.ifa_dstaddr else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        return nil
    }
}

// MARK: - settings

struct SettingsView: View {
    @AppStorage("host") private var host = ""
    @AppStorage("mac") private var mac = ""
    @AppStorage("code") private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    field("PC address", "192.168.1.20", $host, .numbersAndPunctuation)
                    field("MAC address", "AA:BB:CC:DD:EE:FF", $mac, .asciiCapable)
                    field("Pairing code", "ABCD23EFGH", $code, .asciiCapable)
                } footer: {
                    Text("Open PowerSwitch on the PC (power icon in the system tray) to see these. Your iPhone must be on the same Wi-Fi.")
                }
                if !mac.isEmpty && parseMAC(mac) == nil {
                    Text("That MAC address doesn't look right: it should be 12 hex digits.").foregroundColor(.orange)
                }
            }
            .navigationTitle("Your PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(host.isEmpty) }
        }
        .navigationViewStyle(.stack)
    }

    private func field(_ label: String, _ hint: String, _ value: Binding<String>, _ keyboard: UIKeyboardType) -> some View {
        HStack {
            Text(label)
            TextField(hint, text: value)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .font(.body.monospaced())
        }
    }
}
