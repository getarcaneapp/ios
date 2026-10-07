import Arcane

/// The server-owned resource being edited in a template authoring session.
enum TemplateEditorMode: Identifiable {
    case create
    case edit(Template)
    case defaults

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let template): "edit:\(template.id)"
        case .defaults: "defaults"
        }
    }
}
