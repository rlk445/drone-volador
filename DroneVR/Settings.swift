import Foundation
import Combine

final class Settings: ObservableObject {
    static let dZoom = 1.0, dK1 = 0.20, dK2 = 0.05, dShift = 0.10

    @Published var zoom: Double { didSet { UserDefaults.standard.set(zoom, forKey: "zoom") } }
    @Published var k1: Double { didSet { UserDefaults.standard.set(k1, forKey: "k1") } }
    @Published var k2: Double { didSet { UserDefaults.standard.set(k2, forKey: "k2") } }
    @Published var shift: Double { didSet { UserDefaults.standard.set(shift, forKey: "shift") } }

    init() {
        let d = UserDefaults.standard
        zoom = d.object(forKey: "zoom") as? Double ?? Settings.dZoom
        k1 = d.object(forKey: "k1") as? Double ?? Settings.dK1
        k2 = d.object(forKey: "k2") as? Double ?? Settings.dK2
        shift = d.object(forKey: "shift") as? Double ?? Settings.dShift
    }

    func reset() {
        zoom = Settings.dZoom; k1 = Settings.dK1; k2 = Settings.dK2; shift = Settings.dShift
    }
}
