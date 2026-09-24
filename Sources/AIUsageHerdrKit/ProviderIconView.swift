import SwiftUI
import AIUsageCore

struct ProviderIconView: View {
    let id: ProviderID

    var body: some View {
        Image(nsImage: ProviderIcon.image(for: id))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
    }
}
