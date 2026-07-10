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

/// Signed-in account identity used by navigation surfaces that open Profile.
struct UserAccountLabel: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    var avatarSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarCircle(size: avatarSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        guard let user = manager.currentUser else { return "Account" }
        if let displayName = user.displayName, !displayName.isEmpty {
            return displayName
        }
        return user.username
    }

    private var username: String {
        guard let username = manager.currentUser?.username else { return "Profile" }
        return "@\(username)"
    }
}
