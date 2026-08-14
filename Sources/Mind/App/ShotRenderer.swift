import AppKit
import SwiftUI

/// Offscreen renderer for the real `AmbientView`, used to check the artwork at
/// every urgency level and panel size without waiting for an actual meeting.
///
///     MIND_SHOTS=./shots open -a Mind        # or run the binary directly
///
/// It renders each scenario for a couple of seconds of wall-clock so the
/// particle system has time to fill in, then writes a PNG and quits.
@MainActor
enum ShotRenderer {
    struct Scenario {
        let name: String
        let minutesOut: Double
        let size: CGSize
        /// Longer settle time for scenarios that need fireworks in the air.
        let settleFrames: Int
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "1-clear", minutesOut: 2000, size: CGSize(width: 360, height: 260), settleFrames: 40),
        Scenario(name: "2-distant", minutesOut: 180, size: CGSize(width: 360, height: 260), settleFrames: 60),
        Scenario(name: "3-approaching", minutesOut: 42, size: CGSize(width: 360, height: 260), settleFrames: 70),
        Scenario(name: "4-imminent", minutesOut: 9, size: CGSize(width: 360, height: 260), settleFrames: 90),
        Scenario(name: "5-critical", minutesOut: 1.2, size: CGSize(width: 360, height: 260), settleFrames: 130),
        Scenario(name: "6-starting", minutesOut: -0.2, size: CGSize(width: 360, height: 260), settleFrames: 130),
        Scenario(name: "7-micro", minutesOut: 9, size: CGSize(width: 200, height: 92), settleFrames: 80),
        Scenario(name: "8-tall", minutesOut: 25, size: CGSize(width: 340, height: 420), settleFrames: 80),
    ]

    static func run(outputDirectory: String) async {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scenario in scenarios {
            let state = AppState(prefs: .shared, demoMinutes: scenario.minutesOut)
            state.tick()

            let view = AmbientView()
                .environment(state)
                .environment(Preferences.shared)
                .frame(width: scenario.size.width, height: scenario.size.height)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.isOpaque = false

            // Each render pass advances the scene by however much real time has
            // passed, so looping here is what makes the particles evolve.
            for _ in 0..<scenario.settleFrames {
                _ = renderer.cgImage
                state.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard let image = renderer.cgImage else {
                FileHandle.standardError.write(Data("failed to render \(scenario.name)\n".utf8))
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("\(scenario.name).png")
            try? data.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
