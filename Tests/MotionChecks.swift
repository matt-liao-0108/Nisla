import Foundation

@main struct MotionChecks {
    static func main() {
        for opening in [true, false] {
            let start = IslandMotion.progress(0, opening: opening)
            let end = IslandMotion.progress(1, opening: opening)
            precondition(start.width == 0 && start.height == 0)
            precondition(abs(end.width - 1) < 0.000001 && abs(end.height - 1) < 0.000001)
            var previous = (width: 0.0, height: 0.0)
            for step in 0...1000 {
                let value = IslandMotion.progress(Double(step) / 1000, opening: opening)
                precondition(value.width.isFinite && value.height.isFinite)
                precondition((0...1.085).contains(value.width) && (0...1.085).contains(value.height))
                precondition(value.width == value.height)
                if !opening {
                    precondition(value.width <= 1 && value.width >= previous.width && value.height >= previous.height)
                    for expandedHeight in [234.0, 276, 408] {
                        precondition(expandedHeight + (32 - expandedHeight) * value.height >= 32)
                    }
                }
                previous = value
            }
        }
        let samples = (0...1000).map { IslandMotion.progress(Double($0) / 1000, opening: true).height }
        let peak = samples.max()!
        precondition(peak > 1.05 && peak < 1.085)
        let peakIndex = samples.firstIndex(of: peak)!
        precondition(samples[peakIndex + 100] < peak && samples.last == 1)
        precondition(samples.filter { $0 > 1.04 }.count > 20)
        precondition(IslandMotion.shelfDuration(opening: true) > IslandMotion.shelfDuration(opening: false))
        precondition(IslandMotion.shelfDuration(opening: true, resizingContent: true) == 0.32)
        print("PASS: synchronized expansion with one bounded rebound, exact endpoints and notch-safe monotonic collapse")
        for opening in [true, false] {
            let start = IslandMotion.headphoneProgress(0, opening: opening)
            let end = IslandMotion.headphoneProgress(1, opening: opening)
            precondition(start.width == 0 && start.height == 0 && end.width == 1 && end.height == 1)
            for step in 0...1000 {
                let sample = IslandMotion.headphoneProgress(Double(step) / 1000, opening: opening)
                precondition(sample.width.isFinite && sample.height.isFinite)
                precondition((0...1.015).contains(sample.width) && (0...1.015).contains(sample.height))
            }
        }
        print("PASS: headphone spring endpoints, finite layout and restrained settling without large overshoot")
        let hudSamples = (0...1000).map { IslandMotion.hudProgress(Double($0) / 1000, opening: true).height }
        precondition(hudSamples.first == 0 && hudSamples.last == 1)
        precondition(hudSamples.max()! > 1.07 && hudSamples.max()! < 1.09)
        var previousHUD = 0.0
        for step in 0...1000 {
            let closing = IslandMotion.hudProgress(Double(step) / 1000, opening: false)
            precondition(closing.height >= previousHUD && closing.height <= 1)
            previousHUD = closing.height
        }
        precondition(IslandMotion.hudDuration(opening: true) == 0.50)
        precondition(IslandMotion.hudDuration(opening: false) == 0.32)
        print("PASS: short HUD entrance has one small rebound; retraction is monotonic")
    }
}
