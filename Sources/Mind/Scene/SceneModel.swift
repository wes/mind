import Foundation
import SwiftUI

/// The animated world behind the text.
///
/// One object owns every particle and is stepped once per frame from the view's
/// `TimelineView`. It has no opinion about calendars — it takes an intensity
/// from 0 to 1 and an optional phase change, and escalates accordingly:
///
///   0.0 – 0.2  drifting clouds, maybe one toaster, almost nothing
///   0.2 – 0.55 toasters wake up and cross the sky, gentle sparkle
///   0.55 – 0.9 the flock thickens and speeds up, embers start rising
///   0.9 – 1.0  fireworks, shockwaves, the whole thing shakes
@MainActor
final class SceneModel {
    private var clouds: [Cloud] = []
    private var flyers: [Flyer] = []
    private var sparks: [Spark] = []
    private var rockets: [Rocket] = []
    private var shockwaves: [Shockwave] = []

    private var lastTime: Double = 0
    private var lastPhase: Phase = .clear
    private var rocketAccumulator: Double = 0
    private var emberAccumulator: Double = 0
    private var seedCounter: Int = 0
    private var size: CGSize = .zero

    /// Smoothed intensity — the raw value can jump when the agenda reloads and
    /// we never want the scene to snap.
    private(set) var smoothedIntensity: Double = 0

    private let maxSparks = 900
    private let maxFlyers = 26

    /// Nonisolated so views can stand one up in a `@State` initialiser.
    nonisolated init() {}

    // MARK: - Stepping

    func advance(time: Double, size: CGSize, urgency: Urgency, prefs: Preferences) {
        guard size.width > 1, size.height > 1 else { return }
        let firstFrame = lastTime == 0
        var dt = firstFrame ? 1.0 / 60.0 : time - lastTime
        lastTime = time
        // Tab-out, sleep, or a stalled frame shouldn't teleport everything.
        dt = min(max(dt, 0), 1.0 / 20.0)

        if self.size != size {
            self.size = size
            if firstFrame { seedClouds() }
        }

        let target = clamp01(urgency.intensity)
        let follow = target > smoothedIntensity ? 1.4 : 0.5  // rise faster than it falls
        smoothedIntensity += (target - smoothedIntensity) * min(1, dt * follow)

        let motion = prefs.reduceMotion ? 0.35 : 1.0
        let density = 0.35 + prefs.density * 1.3
        let intensity = smoothedIntensity

        if urgency.phase != lastPhase {
            handlePhaseChange(from: lastPhase, to: urgency.phase, prefs: prefs)
            lastPhase = urgency.phase
        }

        stepClouds(dt: dt, motion: motion)
        stepFlyers(dt: dt, intensity: intensity, motion: motion, density: density, prefs: prefs)
        stepEmbers(dt: dt, intensity: intensity, density: density)
        stepRockets(dt: dt, intensity: intensity, density: density, prefs: prefs)
        stepSparks(dt: dt)
        stepShockwaves(dt: dt)
    }

    /// Every escalation gets a physical punctuation mark, so a change in state
    /// is something you notice out of the corner of your eye.
    private func handlePhaseChange(from old: Phase, to new: Phase, prefs: Preferences) {
        guard new > old, size.width > 1 else { return }
        guard prefs.fireworksEnabled else { return }

        switch new {
        case .imminent:
            launchBurst(at: randomSkyPoint(), power: 0.7, count: 34)
        case .critical:
            for i in 0..<3 {
                launchBurst(at: randomSkyPoint(), power: 0.9, count: 44, delayIndex: i)
            }
        case .starting:
            for i in 0..<5 {
                launchBurst(at: randomSkyPoint(), power: 1.0, count: 56, delayIndex: i)
            }
        default:
            break
        }
    }

    private func randomSkyPoint() -> CGPoint {
        CGPoint(
            x: .random(in: size.width * 0.15...size.width * 0.85),
            y: .random(in: size.height * 0.12...size.height * 0.6)
        )
    }

    // MARK: - Clouds

    private func seedClouds() {
        clouds = (0..<6).map { i in
            Cloud(
                x: Double.random(in: 0...1),
                y: Double.random(in: 0.05...0.95),
                radius: Double.random(in: 0.22...0.55),
                speed: Double.random(in: 0.008...0.03) * (i.isMultiple(of: 2) ? 1 : -1),
                phase: Double.random(in: 0...(2 * .pi)),
                seed: i
            )
        }
    }

    private func stepClouds(dt: Double, motion: Double) {
        for i in clouds.indices {
            clouds[i].x += clouds[i].speed * dt * motion
            if clouds[i].x > 1.4 { clouds[i].x = -0.4 }
            if clouds[i].x < -0.4 { clouds[i].x = 1.4 }
            clouds[i].phase += dt * 0.35 * motion
        }
    }

    // MARK: - Flyers (toasters and toast)

    private func stepFlyers(dt: Double, intensity: Double, motion: Double, density: Double, prefs: Preferences) {
        let area = size.width * size.height
        let areaScale = clamp01(area / (420 * 260))
        let wanted: Int
        if prefs.toastersEnabled {
            let base = lerp(1, 13, pow(intensity, 0.85)) * density * (0.45 + areaScale * 0.85)
            wanted = min(maxFlyers, max(intensity < 0.05 ? 1 : 2, Int(base.rounded())))
        } else {
            wanted = 0
        }

        if flyers.count > wanted { flyers.removeLast(flyers.count - wanted) }
        while flyers.count < wanted {
            flyers.append(makeFlyer(intensity: intensity, offscreen: flyers.count > 1))
        }

        let unit = min(size.width, size.height)
        let speed = lerp(0.05, 0.85, pow(intensity, 1.25)) * unit * motion
        let flap = lerp(1.1, 9.5, intensity) * motion

        for i in flyers.indices {
            var f = flyers[i]
            let personal = 0.7 + Double((f.seed % 7)) * 0.09
            let vx = -speed * personal * f.direction.dx
            let vy = speed * personal * f.direction.dy
            f.position.x += vx * dt
            f.position.y += vy * dt
            // A little vertical sway keeps the flight path from looking ruled.
            f.bob += dt * (0.6 + Double(f.seed % 5) * 0.2)
            f.position.y += sin(f.bob) * unit * 0.02 * dt * 8 * motion
            f.flapPhase += dt * flap * (0.85 + Double(f.seed % 4) * 0.1)
            f.spin += dt * f.spinRate * motion * (0.4 + intensity)

            let margin = unit * 0.45
            if f.position.x < -margin || f.position.y > size.height + margin {
                f = makeFlyer(intensity: intensity, offscreen: true)
            }
            flyers[i] = f
        }
    }

    private func makeFlyer(intensity: Double, offscreen: Bool) -> Flyer {
        seedCounter += 1
        let unit = min(size.width, size.height)
        // Toast starts showing up once things are moving; calm skies are toasters only.
        let isToast = intensity > 0.3 && Int.random(in: 0..<100) < 28
        let scale = unit * Double.random(in: 0.13...0.26) * (isToast ? 0.72 : 1)

        let position: CGPoint
        if offscreen {
            // Enter from the right edge or the top, matching the flight vector.
            if Bool.random() {
                position = CGPoint(x: size.width + scale, y: .random(in: -scale...(size.height * 0.85)))
            } else {
                position = CGPoint(x: .random(in: (size.width * 0.15)...(size.width + scale)), y: -scale)
            }
        } else {
            position = CGPoint(
                x: .random(in: 0...size.width),
                y: .random(in: 0...size.height)
            )
        }

        return Flyer(
            position: position,
            direction: CGVector(dx: 1, dy: Double.random(in: 0.28...0.5)),
            scale: scale,
            flapPhase: .random(in: 0...(2 * .pi)),
            bob: .random(in: 0...(2 * .pi)),
            spin: isToast ? .random(in: -0.3...0.3) : 0,
            spinRate: isToast ? .random(in: -0.9...0.9) : 0,
            seed: seedCounter,
            isToast: isToast
        )
    }

    // MARK: - Embers, rockets, sparks

    private func stepEmbers(dt: Double, intensity: Double, density: Double) {
        guard intensity > 0.25 else { return }
        let rate = pow(smoothstep(0.25, 1.0, intensity), 1.6) * 34 * density
        emberAccumulator += rate * dt
        while emberAccumulator >= 1 {
            emberAccumulator -= 1
            guard sparks.count < maxSparks else { break }
            seedCounter += 1
            let unit = min(size.width, size.height)
            sparks.append(Spark(
                position: CGPoint(x: .random(in: 0...size.width), y: size.height + unit * 0.02),
                velocity: CGVector(dx: .random(in: -8...8), dy: .random(in: -30 ... -10) * (0.6 + intensity)),
                life: 0,
                maxLife: .random(in: 1.6...3.2),
                size: unit * .random(in: 0.006...0.014),
                drag: 0.25,
                gravity: -6,
                seed: seedCounter,
                twinkle: .random(in: 0...(2 * .pi)),
                vivid: false
            ))
        }
    }

    private func stepRockets(dt: Double, intensity: Double, density: Double, prefs: Preferences) {
        guard prefs.fireworksEnabled else { return }
        // Fireworks are the reward for being late — nothing below the alert band.
        let ramp = smoothstep(0.52, 1.0, intensity)
        guard ramp > 0 else { return }
        let rate = pow(ramp, 1.5) * 3.2 * density
        rocketAccumulator += rate * dt
        while rocketAccumulator >= 1 {
            rocketAccumulator -= 1
            launchRocket(power: 0.5 + ramp * 0.6)
        }

        let unit = min(size.width, size.height)
        for i in rockets.indices.reversed() {
            rockets[i].position.x += rockets[i].velocity.dx * dt
            rockets[i].position.y += rockets[i].velocity.dy * dt
            rockets[i].velocity.dy += unit * 0.55 * dt
            rockets[i].fuse -= dt
            if rockets[i].fuse <= 0 || rockets[i].velocity.dy > 0 {
                let r = rockets.remove(at: i)
                launchBurst(at: r.position, power: r.power, count: Int(28 + r.power * 34), hueSeed: r.seed)
            }
        }
    }

    private func launchRocket(power: Double) {
        guard rockets.count < 14 else { return }
        seedCounter += 1
        let unit = min(size.width, size.height)
        rockets.append(Rocket(
            position: CGPoint(x: .random(in: size.width * 0.1...size.width * 0.9), y: size.height + unit * 0.05),
            velocity: CGVector(dx: .random(in: -unit * 0.1...unit * 0.1), dy: -unit * Double.random(in: 0.75...1.15)),
            fuse: .random(in: 0.5...0.95),
            power: power,
            seed: seedCounter
        ))
    }

    /// The money shot: a ring of sparks with gravity, drag and a shockwave.
    private func launchBurst(at point: CGPoint, power: Double, count: Int, hueSeed: Int? = nil, delayIndex: Int = 0) {
        let unit = min(size.width, size.height)
        seedCounter += 1
        let seed = hueSeed ?? seedCounter
        let speed = unit * (0.4 + power * 0.75)
        let ringiness = Double.random(in: 0.55...1.0)

        shockwaves.append(Shockwave(
            center: point,
            radius: unit * 0.02,
            maxRadius: unit * (0.16 + power * 0.24),
            life: -Double(delayIndex) * 0.22,
            maxLife: 0.55 + power * 0.35,
            seed: seed
        ))

        for i in 0..<count {
            guard sparks.count < maxSparks else { return }
            let angle = (Double(i) / Double(count)) * 2 * .pi + Double.random(in: -0.12...0.12)
            let magnitude = speed * lerp(Double.random(in: 0.25...1.0), 1.0, ringiness)
            sparks.append(Spark(
                position: point,
                velocity: CGVector(dx: cos(angle) * magnitude, dy: sin(angle) * magnitude),
                life: -Double(delayIndex) * 0.22,
                maxLife: Double.random(in: 0.9...1.9) + power * 0.5,
                size: unit * Double.random(in: 0.005...0.011) * (0.7 + power * 0.5),
                drag: 0.85,
                gravity: unit * 0.34,
                // One colour per burst: mixed-colour sparks read as confetti.
                seed: seed,
                twinkle: .random(in: 0...(2 * .pi)),
                vivid: true
            ))
        }
    }

    private func stepSparks(dt: Double) {
        for i in sparks.indices.reversed() {
            sparks[i].life += dt
            guard sparks[i].life > 0 else { continue }
            let s = sparks[i]
            let damping = exp(-s.drag * dt)
            sparks[i].velocity.dx = s.velocity.dx * damping
            sparks[i].velocity.dy = s.velocity.dy * damping + s.gravity * dt
            sparks[i].previous = s.position
            sparks[i].position.x += sparks[i].velocity.dx * dt
            sparks[i].position.y += sparks[i].velocity.dy * dt
            if sparks[i].life >= sparks[i].maxLife {
                sparks.remove(at: i)
            }
        }
    }

    private func stepShockwaves(dt: Double) {
        for i in shockwaves.indices.reversed() {
            shockwaves[i].life += dt
            guard shockwaves[i].life > 0 else { continue }
            let progress = clamp01(shockwaves[i].life / shockwaves[i].maxLife)
            shockwaves[i].radius = lerp(0, shockwaves[i].maxRadius, 1 - pow(1 - progress, 2.2))
            if progress >= 1 { shockwaves.remove(at: i) }
        }
    }

    // MARK: - Drawing

    func draw(context: GraphicsContext, size: CGSize, palette: Palette, prefs: Preferences, time: Double) {
        let intensity = smoothedIntensity
        var ctx = context

        // At peak urgency the whole scene gets a tight, fast tremor.
        if prefs.shakeEnabled && !prefs.reduceMotion {
            let amount = pow(smoothstep(0.75, 1.0, intensity), 2) * min(size.width, size.height) * 0.012
            if amount > 0.05 {
                ctx.translateBy(
                    x: sin(time * 47) * amount,
                    y: cos(time * 39.5) * amount
                )
            }
        }

        // Additive light works beautifully on a dark sky and does nothing at
        // all on a pale one, where sparks have to be painted as solid ink.
        let paleSky = palette.isPaleSky(intensity)

        drawClouds(in: &ctx, size: size, palette: palette, intensity: intensity, time: time)
        drawFlyers(in: &ctx, palette: palette, intensity: intensity)
        drawShockwaves(in: &ctx, palette: palette, paleSky: paleSky)
        drawSparks(in: &ctx, palette: palette, time: time, paleSky: paleSky)
    }

    private func drawClouds(in ctx: inout GraphicsContext, size: CGSize, palette: Palette, intensity: Double, time: Double) {
        let unit = min(size.width, size.height)
        let opacity = lerp(0.55, 0.16, intensity)
        for cloud in clouds {
            let radius = unit * cloud.radius * (1 + sin(cloud.phase) * 0.06)
            let center = CGPoint(
                x: cloud.x * size.width,
                y: cloud.y * size.height + sin(cloud.phase * 0.7) * unit * 0.02
            )
            let tint = palette.accent(cloud.seed, intensity: intensity).lightened(0.45 - intensity * 0.3)
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [tint.color(opacity: opacity), tint.color(opacity: 0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawFlyers(in ctx: inout GraphicsContext, palette: Palette, intensity: Double) {
        for flyer in flyers {
            ctx.drawLayer { layer in
                // A soft drop shadow is what stops pale chrome from dissolving
                // into an equally pale sky.
                layer.addFilter(.shadow(
                    color: .black.opacity(0.22),
                    radius: flyer.scale * 0.09,
                    x: 0,
                    y: flyer.scale * 0.05
                ))
                layer.translateBy(x: flyer.position.x, y: flyer.position.y)
                if flyer.isToast {
                    layer.rotate(by: .radians(flyer.spin))
                    Toaster.drawToast(in: &layer, scale: flyer.scale, seed: flyer.seed, palette: palette, intensity: intensity)
                } else {
                    // Lean into the direction of travel as the flock speeds up.
                    layer.rotate(by: .radians(-0.14 * intensity))
                    Toaster.draw(
                        in: &layer,
                        scale: flyer.scale,
                        flap: sin(flyer.flapPhase),
                        seed: flyer.seed,
                        palette: palette,
                        intensity: intensity
                    )
                }
            }
        }
    }

    private func drawShockwaves(in ctx: inout GraphicsContext, palette: Palette, paleSky: Bool) {
        var layer = ctx
        layer.blendMode = paleSky ? .normal : .plusLighter
        for wave in shockwaves where wave.life > 0 {
            let progress = clamp01(wave.life / wave.maxLife)
            let alpha = pow(1 - progress, 1.6) * (paleSky ? 0.4 : 0.45)
            guard alpha > 0.01 else { continue }
            let rect = CGRect(
                x: wave.center.x - wave.radius, y: wave.center.y - wave.radius,
                width: wave.radius * 2, height: wave.radius * 2
            )
            let base = palette.spark(wave.seed)
            let tint = paleSky ? base : base.lightened(0.4)
            layer.stroke(
                Path(ellipseIn: rect),
                with: .color(tint.color(opacity: alpha)),
                lineWidth: max(0.5, wave.maxRadius * 0.03 * (1 - progress))
            )
        }
    }

    private func drawSparks(in ctx: inout GraphicsContext, palette: Palette, time: Double, paleSky: Bool) {
        var layer = ctx
        layer.blendMode = paleSky ? .normal : .plusLighter
        for spark in sparks where spark.life > 0 {
            let progress = clamp01(spark.life / spark.maxLife)
            let fade = pow(1 - progress, 1.4)
            let twinkle = 0.7 + 0.3 * sin(time * 18 + spark.twinkle)
            let alpha = fade * twinkle
            guard alpha > 0.015 else { continue }

            let base = spark.vivid
                ? palette.spark(spark.seed)
                : palette.accent(spark.seed, intensity: 1)
            let tint = paleSky ? base : base.lightened(0.15)
            let radius = spark.size * (0.6 + fade * 0.8)

            // Trail length comes from velocity, not the previous frame, so it
            // stays constant whether we're drawing at 24fps or 120.
            if spark.previous != nil {
                var trail = Path()
                trail.move(to: CGPoint(
                    x: spark.position.x - spark.velocity.dx * 0.055,
                    y: spark.position.y - spark.velocity.dy * 0.055
                ))
                trail.addLine(to: spark.position)
                layer.stroke(
                    trail,
                    with: .color(tint.color(opacity: alpha * (paleSky ? 0.75 : 0.55))),
                    style: StrokeStyle(lineWidth: radius * 1.1, lineCap: .round)
                )
            }

            let glowRect = CGRect(
                x: spark.position.x - radius * 1.7, y: spark.position.y - radius * 1.7,
                width: radius * 3.4, height: radius * 3.4
            )
            layer.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(colors: [tint.color(opacity: alpha * (paleSky ? 0.7 : 0.6)),
                                      tint.color(opacity: 0)]),
                    center: spark.position,
                    startRadius: 0,
                    endRadius: radius * 1.7
                )
            )
            let coreRect = CGRect(
                x: spark.position.x - radius * 0.55, y: spark.position.y - radius * 0.55,
                width: radius * 1.1, height: radius * 1.1
            )
            let core = paleSky ? tint.lightened(0.35) : tint.lightened(0.7)
            layer.fill(Path(ellipseIn: coreRect), with: .color(core.color(opacity: alpha)))
        }

        // Rockets, drawn last so their trails sit above the ambient embers.
        for rocket in rockets {
            let base = palette.spark(rocket.seed)
            let tint = paleSky ? base : base.lightened(0.5)
            var trail = Path()
            trail.move(to: rocket.position)
            trail.addLine(to: CGPoint(
                x: rocket.position.x - rocket.velocity.dx * 0.05,
                y: rocket.position.y - rocket.velocity.dy * 0.05
            ))
            layer.stroke(
                trail,
                with: .color(tint.color(opacity: 0.8)),
                style: StrokeStyle(lineWidth: max(1, min(size.width, size.height) * 0.006), lineCap: .round)
            )
        }
    }
}

// MARK: - Particle types

private struct Cloud {
    var x: Double
    var y: Double
    var radius: Double
    var speed: Double
    var phase: Double
    var seed: Int
}

private struct Flyer {
    var position: CGPoint
    var direction: CGVector
    var scale: Double
    var flapPhase: Double
    var bob: Double
    var spin: Double
    var spinRate: Double
    var seed: Int
    var isToast: Bool
}

private struct Spark {
    var position: CGPoint
    var previous: CGPoint?
    var velocity: CGVector
    var life: Double
    var maxLife: Double
    var size: Double
    var drag: Double
    var gravity: Double
    var seed: Int
    var twinkle: Double
    var vivid: Bool

    init(position: CGPoint, velocity: CGVector, life: Double, maxLife: Double,
         size: Double, drag: Double, gravity: Double, seed: Int, twinkle: Double,
         vivid: Bool) {
        self.position = position
        self.previous = nil
        self.velocity = velocity
        self.life = life
        self.maxLife = maxLife
        self.size = size
        self.drag = drag
        self.gravity = gravity
        self.seed = seed
        self.twinkle = twinkle
        self.vivid = vivid
    }
}

private struct Rocket {
    var position: CGPoint
    var velocity: CGVector
    var fuse: Double
    var power: Double
    var seed: Int
}

private struct Shockwave {
    var center: CGPoint
    var radius: Double
    var maxRadius: Double
    var life: Double
    var maxLife: Double
    var seed: Int
}
