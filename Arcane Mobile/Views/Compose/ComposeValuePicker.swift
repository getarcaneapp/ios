import SwiftUI

/// Shared choice control for new settings and existing values.
struct ComposeValuePicker: View {
    let title: String
    let options: ComposeFieldOptions
    @Binding var value: String
    @State private var custom = false

    var body: some View {
        Picker(
            title,
            selection: Binding(
                get: { custom || (!value.isEmpty && !options.values.contains(value)) ? "__custom__" : value },
                set: { selection in
                    custom = selection == "__custom__"
                    if !custom { value = selection } else if options.values.contains(value) { value = "" }
                }
            )
        ) {
            Text("Choose…").tag("")
            ForEach(options.values, id: \.self) { Text(options.label($0)).tag($0) }
            if options.allowsCustom {
                Text("Custom value…").tag("__custom__")
            } else if !value.isEmpty && !options.values.contains(value) {
                Text(value).tag("__custom__")
            }
        }
        if options.allowsCustom && (custom || (!value.isEmpty && !options.values.contains(value))) {
            TextField("Custom value or ${VARIABLE}", text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
