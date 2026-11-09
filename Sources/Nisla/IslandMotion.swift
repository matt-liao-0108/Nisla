import Foundation

/// Shared deterministic timing for the native window's width and height.
enum IslandMotion {
    static func shelfDuration(opening: Bool, resizingContent: Bool = false) -> Double {
        resizingContent ? 0.32 : opening ? 0.70 : 0.58
    }

    static func hudDuration(opening: Bool) -> Double { opening ? 0.50 : 0.32 }

    static func hudProgress(_ time: Double, opening: Bool) -> (width: Double, height: Double) {
        let t = min(1, max(0, time))
        // A small, single rebound. Repeated volume changes keep the same size
        // and update only the fill, rather than restarting this entrance.
        func response(_ progress: Double) -> Double {
            let damping = 0.63, frequency = 9.6
            let root = sqrt(1 - damping * damping)
            return 1 - exp(-damping * frequency * progress)
                * (cos(frequency * root * progress) + damping / root * sin(frequency * root * progress))
        }
        let value = opening && t > 0 && t < 1 ? response(t) / response(1) : opening ? t : spring(t)
        return (value, value)
    }

    static func spring(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        if t == 0 || t == 1 { return t }
        let frequency = 9.0
        func response(_ time: Double) -> Double {
            1 - (1 + frequency * time) * exp(-frequency * time)
        }
        return min(1, max(0, response(t) / response(1)))
    }

    static func progress(_ time: Double, opening: Bool) -> (width: Double, height: Double) {
        let t = min(1, max(0, time))
        // Both dimensions travel together. One lightly underdamped expansion
        // goes beyond its destination, then settles; collapse never undershoots
        // the physical notch's height. Do not clamp the expansion to 1.
        let value = opening ? expansionSpring(t) : spring(t)
        return (value, value)
    }

    private static func expansionSpring(_ time: Double) -> Double {
        if time == 0 || time == 1 { return time }
        let damping = 0.64, frequency = 8.8
        let root = sqrt(1 - damping * damping)
        func response(_ t: Double) -> Double {
            1 - exp(-damping * frequency * t)
                * (cos(frequency * root * t) + damping / root * sin(frequency * root * t))
        }
        return response(time) / response(1)
    }

    /// A restrained spring for the system-style accessory connection toast.
    /// Top anchoring is owned by the panel, so the physical notch never moves.
    static func headphoneProgress(_ time: Double, opening: Bool) -> (width: Double, height: Double) {
        let t = min(1, max(0, time))
        func response(_ progress: Double) -> Double {
            let p = min(1, max(0, progress))
            if p == 0 || p == 1 { return p }
            let damping = 0.86, frequency = 11.5
            let root = sqrt(1 - damping * damping)
            func value(_ x: Double) -> Double {
                1 - exp(-damping * frequency * x)
                    * (cos(frequency * root * x) + damping / root * sin(frequency * root * x))
            }
            return value(p) / value(1)
        }
        if opening { return (response(t / 0.94), response((t - 0.035) / 0.965)) }
        return (spring((t - 0.04) / 0.96), spring(t))
    }
}
