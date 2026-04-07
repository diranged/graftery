// Copyright 2026 Matt Wise
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
