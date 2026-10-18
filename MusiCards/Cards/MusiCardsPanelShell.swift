import SwiftUI

#if os(macOS)
struct MusiCardsSettingsSheetHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Text(title)
                .font(.headline)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderless)
                .tint(.blue)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}
#endif
