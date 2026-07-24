import SwiftUI

struct RemoteImage: View {
    let url: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 4

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(Theme.card)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(Theme.textSecondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
