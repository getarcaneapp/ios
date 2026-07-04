import Arcane
import SwiftUI

/// Circular avatar for the signed-in user: shows the server-synced profile
/// picture when one exists, otherwise falls back to the accent-gradient
/// initials circle used before avatars were supported.
struct UserAvatarCircle: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let size: CGFloat
    var font: Font = .subheadline.bold()

    var body: some View {
        Group {
            if let data = manager.currentUserAvatarData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.gradient)
                        .frame(width: size, height: size)
                    Text(initials)
                        .font(font)
                        .foregroundStyle(.white)
                }
            }
        }
        .task(id: manager.currentUser?.updatedAt) {
            await manager.refreshCurrentUserAvatar()
        }
    }

    private var initials: String {
        let user = manager.currentUser
        let source = user?.displayName?.isEmpty == false ? user!.displayName! : (user?.username ?? "?")
        return String(source.prefix(1)).uppercased()
    }
}
