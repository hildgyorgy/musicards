import SwiftUI

#if os(macOS)
struct MusiCardsPanelShell<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(
                                .regular.interactive(),
                                in: RoundedRectangle(
                                    cornerRadius: DeckStyle.aboutOverlayCornerRadius,
                                    style: .continuous
                                )
                            )
                    } else {
                        RoundedRectangle(
                            cornerRadius: DeckStyle.aboutOverlayCornerRadius,
                            style: .continuous
                        )
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: DeckStyle.aboutOverlayCornerRadius,
                                style: .continuous
                            )
                            .stroke(
                                DeckStyle.strokeColor,
                                lineWidth: DeckStyle.strokeWidth
                            )
                        )
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DeckStyle.aboutOverlayCornerRadius,
                        style: .continuous
                    )
                )
                .shadow(
                    color: .black.opacity(0.35),
                    radius: 24,
                    x: 0,
                    y: 8
                )

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
