import Foundation
import Metal
import MetalKit
import UIKit

// MARK: - Shader (compilado em tempo de execucao)

enum Shader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Params {
        float zoom; float k1; float k2; float shift;
        float imgAspect; float eyeAspect; float pad0; float pad1;
    };

    vertex VOut vs(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 fs(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler smp [[sampler(0)]],
                       constant Params& P [[buffer(0)]]) {
        float2 uv = in.uv;
        bool isLeft = uv.x < 0.5;
        float lx = isLeft ? uv.x * 2.0 : (uv.x - 0.5) * 2.0;
        float2 e = float2(lx * 2.0 - 1.0, uv.y * 2.0 - 1.0);
        e.x += isLeft ? -P.shift : P.shift;
        float2 p = float2(e.x * P.eyeAspect, e.y);
        float r2 = dot(p, p);
        float f = 1.0 + P.k1 * r2 + P.k2 * r2 * r2;
        p *= f;
        float halfW = P.zoom * P.eyeAspect;
        float halfH = halfW / P.imgAspect;
        float2 t = float2(p.x / (2.0 * halfW) + 0.5, p.y / (2.0 * halfH) + 0.5);
        if (t.x < 0.0 || t.x > 1.0 || t.y < 0.0 || t.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        return float4(tex.sample(smp, t).rgb, 1.0);
    }
    """
}

struct Params {
    var zoom: Float
    var k1: Float
    var k2: Float
    var shift: Float
    var imgAspect: Float
    var eyeAspect: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

private let texOptions: [MTKTextureLoader.Option: Any] = [
    .SRGB: false,
    .origin: MTKTextureLoader.Origin.topLeft,
    .generateMipmaps: false
]

// MARK: - Decodificador (sempre fica com o quadro mais novo)

final class FrameDecoder {
    private let loader: MTKTextureLoader
    private let lock = NSLock()
    private var pending: Data?
    private var running = false
    private var latest: MTLTexture?
    private var count = 0
    private let queue = DispatchQueue(label: "dronevr.decode", qos: .userInteractive)

    init(device: MTLDevice) {
        loader = MTKTextureLoader(device: device)
    }

    func submit(_ data: Data) {
        lock.lock()
        pending = data
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart {
            queue.async { self.loop() }
        }
    }

    private func loop() {
        while true {
            lock.lock()
            let next = pending
            pending = nil
            if next == nil {
                running = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let d = next, let tex = try? loader.newTexture(data: d, options: texOptions) {
                lock.lock()
                latest = tex
                count += 1
                lock.unlock()
            }
        }
    }

    func currentTexture() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func clear() {
        lock.lock(); latest = nil; lock.unlock()
    }

    func takeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let c = count
        count = 0
        return c
    }
}

// MARK: - Imagem de teste (grade) quando nao tem PC conectado

func makeTestPattern() -> CGImage? {
    let size = CGSize(width: 1280, height: 720)
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = 1
    fmt.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
    let img = renderer.image { ctx in
        let c = ctx.cgContext
        UIColor.black.setFill()
        c.fill(CGRect(origin: .zero, size: size))
        c.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
        c.setLineWidth(1)
        for x in stride(from: 0, through: 1280, by: 80) {
            c.move(to: CGPoint(x: x, y: 0))
            c.addLine(to: CGPoint(x: x, y: 720))
        }
        for y in stride(from: 0, through: 720, by: 80) {
            c.move(to: CGPoint(x: 0, y: y))
            c.addLine(to: CGPoint(x: 1280, y: y))
        }
        c.strokePath()
        c.setStrokeColor(UIColor.red.cgColor)
        c.setLineWidth(4)
        c.stroke(CGRect(x: 2, y: 2, width: 1276, height: 716))
        for rad in [100.0, 200.0, 300.0] {
            c.strokeEllipse(in: CGRect(x: 640 - rad, y: 360 - rad, width: rad * 2, height: rad * 2))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 48),
            .foregroundColor: UIColor.white
        ]
        ("DRONE VR - aguardando o PC" as NSString).draw(at: CGPoint(x: 330, y: 335), withAttributes: attrs)
    }
    return img.cgImage
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let decoder: FrameDecoder
    private let settings: Settings
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var gridTexture: MTLTexture?

    init(device: MTLDevice, decoder: FrameDecoder, settings: Settings) {
        self.device = device
        self.decoder = decoder
        self.settings = settings
        self.queue = device.makeCommandQueue()!
        super.init()

        do {
            let lib = try device.makeLibrary(source: Shader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            print("Erro no shader: \(error)")
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        if let cg = makeTestPattern() {
            gridTexture = try? MTKTextureLoader(device: device).newTexture(cgImage: cg, options: texOptions)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let pipeline = pipeline, let sampler = sampler,
           let tex = decoder.currentTexture() ?? gridTexture {
            let size = view.drawableSize
            let eyeAspect = Float((size.width / 2.0) / max(size.height, 1))
            var p = Params(zoom: Float(settings.zoom),
                           k1: Float(settings.k1),
                           k2: Float(settings.k2),
                           shift: Float(settings.shift),
                           imgAspect: Float(tex.width) / Float(max(tex.height, 1)),
                           eyeAspect: eyeAspect)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
