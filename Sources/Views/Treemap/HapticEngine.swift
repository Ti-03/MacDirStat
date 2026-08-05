import AppKit

/// Manages Force Touch trackpad feedback for the chart.
/// Fires once per new arc entered; intensity scales with node size.
@MainActor
final class HapticEngine {

    static let shared = HapticEngine()
    private let p = NSHapticFeedbackManager.defaultPerformer
    private var lastID: Int?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
    }

    // ── Hover ────────────────────────────────────────────────────────────────

    func hoverEntered(_ node: FileNode) {
        guard isEnabled, node.id != lastID else { return }
        lastID = node.id

        let (pattern, taps) = feedback(for: node)
        fire(pattern: pattern, times: taps)
    }

    func hoverExited() {
        lastID = nil
    }

    // ── Click / navigation ───────────────────────────────────────────────────

    /// Drill into a directory.
    func drillIn() {
        guard isEnabled else { return }
        fire(pattern: .levelChange, times: 1)
    }

    /// Navigate back out.
    func drillOut() {
        guard isEnabled else { return }
        fire(pattern: .generic, times: 1)
    }

    /// Select a file.
    func select() {
        guard isEnabled else { return }
        fire(pattern: .alignment, times: 1)
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// Choose pattern + tap-count based on node size.
    /// Directories always feel like a firm "snap" (alignment).
    private func feedback(for node: FileNode) -> (NSHapticFeedbackManager.FeedbackPattern, Int) {
        if node.isDirectory {
            return (.alignment, 1)
        }
        let size = node.size
        switch size {
        case ..<(1_000_000):           // < 1 MB — whisper
            return (.generic, 1)
        case ..<(50_000_000):          // 1 – 50 MB — light click
            return (.alignment, 1)
        case ..<(500_000_000):         // 50 MB – 500 MB — firm click
            return (.levelChange, 1)
        case ..<(5_000_000_000):       // 500 MB – 5 GB — double thud
            return (.levelChange, 2)
        default:                        // 5 GB+ — triple thud
            return (.levelChange, 3)
        }
    }

    /// Fire `times` haptic pulses, each 65 ms apart.
    private func fire(pattern: NSHapticFeedbackManager.FeedbackPattern, times: Int) {
        for i in 0..<times {
            if i == 0 {
                p.perform(pattern, performanceTime: .now)
            } else {
                let delay = Double(i) * 0.065
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    self.p.perform(pattern, performanceTime: .now)
                }
            }
        }
    }
}
