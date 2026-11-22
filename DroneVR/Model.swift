import SwiftUI
import Metal

final class AppModel: ObservableObject {
    @Published var status = "Iniciando..."
    @Published var connected = false
    @Published var fps = 0
    @Published var ips: [String] = []

    let settings = Settings()
    let device: MTLDevice
    let decoder: FrameDecoder
    let receiver = Receiver()

    init() {
        let dev = MTLCreateSystemDefaultDevice()!
        device = dev
        let dec = FrameDecoder(device: dev)
        decoder = dec

        receiver.onFrame = { d in dec.submit(d) }
        receiver.onState = { [weak self] text, ok in
            DispatchQueue.main.async {
                self?.status = text
                self?.connected = ok
            }
            if !ok { dec.clear() }
        }
        receiver.ensureRunning()
        refreshIPs()

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.receiver.ensureRunning()
            self?.refreshIPs()
        }
    }

    func refreshIPs() {
        ips = localIPs()
    }

    func tick() {
        fps = decoder.takeCount()
        refreshIPs()
    }
}
