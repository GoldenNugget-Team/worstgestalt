//
//  AboutView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct AboutView: View {
    /// Resolved once per view instance; nil means fall back to the SF symbol.
    @State private var appIcon: UIImage?
    @State private var iconResolved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Group {
                            if let appIcon {
                                Image(uiImage: appIcon)
                                    .resizable()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                Image(systemName: "cpu.fill")
                                    .font(.system(size: 34, weight: .medium))
                                    .foregroundStyle(.tint)
                                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WorstGestalt")
                                .font(.title2.bold())
                            Text(verbatim: "Version \(Self.marketingVersion) (\(Self.buildVersion))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Credits") {
                    LabeledContent {
                        Text("awesomenull")
                    } label: {
                        Label("Main developer", systemImage: "person.crop.circle")
                    }
                    LabeledContent {
                        Text("Taj C / forcequitOS")
                    } label: {
                        Label("Exploit", systemImage: "key.horizontal")
                    }
                    .contextMenu {
                        // Kept here for the curious: the whole app is a shell
                        // around one bridging bug.
                        Button("Copy exploit name") {
                            UIPasteboard.general.string = "worse_query"
                            UILogger.log("[about] copied 'worse_query' to clipboard")
                        }
                    }
                }

                Section("Details") {
                    LabeledContent("Exploit", value: "worse_query")
                    LabeledContent("Source", value: "forcequitOS")
                    LabeledContent("Bundle ID", value: Self.bundleID)
                    LabeledContent("License", value: "GPL-3.0-or-later")
                }

                Section {
                    Text("""
                    A MobileGestalt editor riding on the worse_query bridge \
                    from forcequitOS. Respring payload: KAMUI engine (MIT). \
                    NeoSpring respring by @neonmodder123 & @skadz108.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .onAppear {
                guard !iconResolved else { return }
                iconResolved = true
                appIcon = Self.loadAppIcon()
            }
        }
    }

    /// Resolves the compiled app icon. The hand-rolled `Assets.car` carries a
    /// single MultisizeImage icon facet (`AppIcon`) — SpringBoard reads that
    /// through CFBundleIcons, but `UIImage(named:)` in-process does not resolve
    /// it, so the flat render shipped as `AppIcon.png` is the reliable source.
    private static func loadAppIcon() -> UIImage? {
        if let icon = UIImage(named: "AppIcon.png") {
            UILogger.log("[about] icon resolved from bundled AppIcon.png")
            return icon
        }
        // Catalog lookup first, in case a future Xcode-built .car starts
        // resolving in-process, then the plist manifest as a fallback.
        if let icon = UIImage(named: "AppIcon") {
            UILogger.log("[about] icon resolved from Assets.car / bundle ('AppIcon')")
            return icon
        }
        if let icon = Self.iconFromManifest() {
            UILogger.log("[about] icon resolved via CFBundleIconFiles")
            return icon
        }
        UILogger.log("[about] no icon source resolved — using SF symbol fallback")
        return nil
    }

    private static func iconFromManifest() -> UIImage? {
        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String]
        else { return nil }
        for name in files where !name.isEmpty {
            if let icon = UIImage(named: name) { return icon }
        }
        return nil
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "(unknown)"
    }
}
