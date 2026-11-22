import Foundation
import Network

/// O iPhone escuta na porta 5600. O PC conecta e manda quadros JPEG:
/// [4 bytes tamanho big-endian][bytes JPEG]
final class Receiver {
    var onFrame: ((Data) -> Void)?
    var onState: ((String, Bool) -> Void)?

    let port: UInt16 = 5600
    private var listener: NWListener?
    private var current: NWConnection?
    private let queue = DispatchQueue(label: "dronevr.net", qos: .userInteractive)

    func ensureRunning() {
        queue.async {
            if self.listener == nil { self.startListener() }
        }
    }

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.service = NWListener.Service(name: "DroneVR", type: "_dronevr._tcp")
            l.stateUpdateHandler = { [weak self, weak l] st in
                guard let self = self, let l = l else { return }
                switch st {
                case .ready:
                    self.onState?("Aguardando o PC...", false)
                case .failed(let e):
                    self.onState?("Erro de rede: \(e)", false)
                    l.cancel()
                    if self.listener === l { self.listener = nil }
                    self.queue.asyncAfter(deadline: .now() + 1.0) { self.ensureRunning() }
                case .cancelled:
                    if self.listener === l { self.listener = nil }
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener = l
            l.start(queue: queue)
        } catch {
            onState?("Erro: \(error)", false)
            queue.asyncAfter(deadline: .now() + 2.0) { self.ensureRunning() }
        }
    }

    private func accept(_ c: NWConnection) {
        current?.cancel()
        current = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self = self, let c = c, self.current === c else { return }
            switch st {
            case .ready:
                self.onState?("PC conectado", true)
                self.readHeader(c)
            case .failed, .cancelled:
                self.onState?("Aguardando o PC...", false)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self, self.current === c else { return }
            if let d = data, d.count == 4 {
                let b = [UInt8](d)
                let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                if len > 0 && len < 8_000_000 {
                    self.readBody(c, len)
                } else {
                    c.cancel()
                }
            } else if error != nil || isComplete {
                c.cancel()
            }
        }
    }

    private func readBody(_ c: NWConnection, _ len: Int) {
        c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, isComplete, error in
            guard let self = self, self.current === c else { return }
            if let d = data, d.count == len {
                self.onFrame?(d)
                self.readHeader(c)
            } else if error != nil || isComplete {
                c.cancel()
            }
        }
    }
}

/// IPs do iPhone (Wi-Fi = en0, hotspot USB = bridge100...)
func localIPs() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = first
    while true {
        let ifa = ptr.pointee
        let name = String(cString: ifa.ifa_name)
        let flags = Int32(ifa.ifa_flags)
        if let addr = ifa.ifa_addr,
           addr.pointee.sa_family == UInt8(AF_INET),
           (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
           name.hasPrefix("en") || name.hasPrefix("bridge") {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        guard let next = ifa.ifa_next else { break }
        ptr = next
    }
    return result
}
