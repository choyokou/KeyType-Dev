//
//  SetupSettingsView.swift
//  KeyType
//
//  The "设置引导" Settings pane: a shortcut back into the onboarding wizard. Split out of SettingsView
//  so each sidebar category lives in its own file.
//

import SwiftUI

struct SetupSettingsView: View {
    let runSetupAgain: () -> Void

    var body: some View {
        Form {
            Section("设置引导") {
                Button("重新运行设置引导…") { runSetupAgain() }
            }
        }
        .formStyle(.grouped)
    }
}
