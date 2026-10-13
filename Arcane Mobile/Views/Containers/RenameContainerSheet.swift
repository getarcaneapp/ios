import SwiftUI

/// Rename sheet shared by containers and volumes, which follow the same
/// Docker naming rules.
struct RenameContainerSheet: View {
    let currentName: String
    var resourceKind = "Container"
    var footer: String?
    let onRename: (String) async -> Result<Void, Error>

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var newName: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        currentName: String,
        resourceKind: String = "Container",
        footer: String? = nil,
        onRename: @escaping (String) async -> Result<Void, Error>
    ) {
        self.currentName = currentName
        self.resourceKind = resourceKind
        self.footer = footer
        self.onRename = onRename
        _newName = State(initialValue: currentName)
    }

    private static let nameRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9][a-zA-Z0-9_.-]+$")

    private var isValid: Bool {
        let range = NSRange(newName.startIndex..., in: newName)
        return Self.nameRegex.firstMatch(in: newName, options: [], range: range) != nil
    }

    private var hasChanged: Bool {
        newName != currentName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField(
                        title: "\(resourceKind) Name",
                        placeholder: currentName,
                        text: $newName,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Must start with a letter or digit, and contain only letters, "
                            + "digits, underscores, dots, or hyphens."
                    )
                    .submitLabel(.done)
                } header: {
                    Text("New name")
                } footer: {
                    if let footer { Text(footer) }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Rename \(resourceKind)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await submit() }
                    }
                    .disabled(!isValid || !hasChanged || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        let result = await onRename(newName)
        isSubmitting = false
        switch result {
        case .success:
            dismiss()
        case .failure(let error):
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
