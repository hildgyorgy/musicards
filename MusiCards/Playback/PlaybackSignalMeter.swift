import SwiftUI

private struct SideSignalMeterKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesSideSignalMeter: Bool {
        get { self[SideSignalMeterKey.self] }
        set { self[SideSignalMeterKey.self] = newValue }
    }
}

/// The same measured RMS display in either orientation. No timer or audio ownership.
struct PlaybackSignalMeter: View, Animatable {
    enum Axis { case horizontal, vertical }

    var left: Double
    var right: Double
    var axis: Axis = .horizontal

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(left, right) }
        set { left = newValue.first; right = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            let count = 32
            let horizontalStep = min(6, size.width / CGFloat(count))
            let diameter = axis == .horizontal ? min(2.3, horizontalStep * 0.6) : 3.2
            for (channel, level) in [left, right].enumerated() {
                for dot in 0..<count {
                    let lit = level > Double(dot) / Double(count)
                    let color = lit
                        ? (dot >= count - 3 ? Color.red : Color.accentColor)
                        : Color.secondary.opacity(0.12)
                    let rect: CGRect
                    switch axis {
                    case .horizontal:
                        rect = CGRect(x: CGFloat(dot) * horizontalStep, y: CGFloat(channel) * 5,
                                      width: diameter, height: diameter)
                    case .vertical:
                        let step = max(0, size.height - diameter) / CGFloat(count - 1)
                        rect = CGRect(x: CGFloat(channel) * max(0, size.width - diameter),
                                      y: max(0, size.height - diameter) - CGFloat(dot) * step,
                                      width: diameter, height: diameter)
                    }
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }
}
