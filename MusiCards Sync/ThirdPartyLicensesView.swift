import SwiftUI

struct SyncThirdPartyLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("rsync 3.5.0")
                        .font(.headline)

                    Text(resourceText("NOTICE", fileExtension: "md"))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    Text("GNU GPLv3 license")
                        .font(.headline)

                    Text(resourceText("COPYING"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text("popt")
                        .font(.headline)

                    Text(resourceText("popt-COPYING"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text("zlib")
                        .font(.headline)

                    Text(resourceText("zlib-LICENSE"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            .navigationTitle("Third-Party Licenses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private func resourceText(_ name: String, fileExtension: String? = "txt") -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable."
        }
        return text
    }
}
