import SwiftUI

struct ThirdPartyLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    licenseSection(title: "libFLAC", resource: "libFLAC-LICENSE")
                    licenseSection(title: "libogg", resource: "libogg-LICENSE")
                }
                .padding(24)
            }
            .navigationTitle("Third-Party Licenses")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }

    private func licenseSection(title: String, resource: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(licenseText(resource))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func licenseText(_ resource: String) -> String {
        guard let url = Bundle.main.url(
            forResource: resource,
            withExtension: "txt"
        ),
        let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Licence text unavailable."
        }
        return text
    }
}
