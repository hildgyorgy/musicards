import SwiftUI

enum AppDesign {
    static let contentPadding: CGFloat = 28
    static let sectionGap: CGFloat = 28
    static let railWidth: CGFloat = 72
    static let railSymbolSize: CGFloat = 34
    static let railControlHeight: CGFloat = 54
    static let railSymbolWeight: Font.Weight = .bold
    static let contentGap: CGFloat = 26
    static let detailSpacing: CGFloat = 5
    static let headerTracking: CGFloat = 1.5
    static let progressHeight: CGFloat = 4
}

struct AppSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .tracking(AppDesign.headerTracking)
            .foregroundStyle(.secondary)
    }
}

struct AppRailSymbol: View {
    let systemName: String
    let isEnabled: Bool
    var isActive: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(
                size: AppDesign.railSymbolSize,
                weight: AppDesign.railSymbolWeight
            ))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                isEnabled || isActive
                    ? Color.accentColor
                    : Color.secondary.opacity(0.28)
            )
            .frame(
                width: AppDesign.railWidth,
                height: AppDesign.railControlHeight,
                alignment: .center
            )
            .contentShape(Rectangle())
    }
}

struct AppRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct AppThinProgressBar: View {
    let value: Double

    var body: some View {
        ProgressView(value: min(max(value, 0), 1), total: 1)
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .controlSize(.small)
            .frame(minHeight: AppDesign.progressHeight)
    }
}

