import SwiftUI

/// App-level About window showing version, description, and project links.
///
/// Accessed from the menu bar's "About Graftery..." item. This is a
/// standalone window — not tied to any specific runner configuration.
/// It provides basic app identity and links to project resources.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: AppConstants.SFSymbol.appIcon)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text(AppConstants.appName)
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(AppConstants.appVersion)")
                .foregroundColor(.secondary)

            Text("GitHub Actions runner scale set\nbacked by Tart macOS VMs")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: AppConstants.projectURL)!)
                Link("Tart", destination: URL(string: AppConstants.tartURL)!)
                Link("Actions Scaleset", destination: URL(string: AppConstants.actionsScalesetURL)!)
            }
            .font(.callout)

            Spacer()
        }
        .frame(width: 400, height: 300)
    }
}
