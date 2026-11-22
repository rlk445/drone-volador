import SwiftUI
import MetalKit

extension View {
    @ViewBuilder func hideOverlays() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var vr = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if vr {
                VRView(model: model, onExit: { vr = false })
                    .ignoresSafeArea()
            } else {
                MenuView(model: model, settings: model.settings, onStart: { vr = true })
            }
        }
        .statusBar(hidden: true)
        .hideOverlays()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onReceive(timer) { _ in model.tick() }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var onStart: () -> Void

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                .font(.subheadline)
            Slider(value: value, in: range)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drone VR").font(.largeTitle.bold())

                Text(model.status)
                    .font(.headline)
                    .foregroundColor(model.connected ? .green : .yellow)

                Text("IP do iPhone (use no PC):").font(.subheadline)
                if model.ips.isEmpty {
                    Text("sem rede").foregroundColor(.red)
                }
                ForEach(model.ips, id: \.self) { ip in
                    Text(ip).font(.system(.title2, design: .monospaced)).bold()
                }
                Text("No PC: python pc_stream.py --ip <IP acima>")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.gray)
                Text("Quadros por segundo: \(model.fps)").font(.footnote)

                Divider().background(Color.gray)

                row("Zoom da tela", $settings.zoom, 0.5...1.8)
                row("Distorcao da lente (k1)", $settings.k1, 0.0...0.8)
                row("Distorcao borda (k2)", $settings.k2, 0.0...0.6)
                row("Aproximar imagens (+) / afastar (-)", $settings.shift, -0.4...0.6)

                HStack(spacing: 12) {
                    Button("Entrar no modo VR") { onStart() }
                        .buttonStyle(.borderedProminent)
                    Button("Restaurar padrao") { settings.reset() }
                        .buttonStyle(.bordered)
                }
                Text("Dentro do VR, toque com 2 dedos para voltar a este menu. Sem PC conectado aparece uma grade para ajustar a lente.")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 20)
        }
        .foregroundColor(.white)
    }
}

struct VRView: UIViewRepresentable {
    let model: AppModel
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: model.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.isMultipleTouchEnabled = true
        if let layer = v.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 2
        }
        let r = Renderer(device: model.device, decoder: model.decoder, settings: model.settings)
        context.coordinator.renderer = r
        v.delegate = r

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.exitTapped))
        tap.numberOfTouchesRequired = 2
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject {
        var renderer: Renderer?
        let onExit: () -> Void
        init(onExit: @escaping () -> Void) { self.onExit = onExit }
        @objc func exitTapped() { onExit() }
    }
}
