import SwiftUI
import Arcane

struct VolumeBrowserView: View {
    let environmentID: EnvironmentID
    let volumeName: String
    @State private var path = ""

    var body: some View {
        DynamicResourceListView(
            title: path.isEmpty ? "Files" : path,
            systemImage: "folder",
            path: { _, client in
                let volume = ArcaneAPIHelpers.escapedPathComponent(volumeName)
                let base = client.rest.environmentPath(environmentID, "volumes/\(volume)/browse")
                return ArcaneAPIHelpers.queryPath(base, items: path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)])
            },
            emptyTitle: "No Files"
        )
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                TextField("Path", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }
}
