//
//  PrivacyPolicyView.swift
//  Bakarat
//
//  Privacy policy shown in-app. Markdown via AttributedString(markdown:).
//  A public canonical version is also hosted at
//  https://sachacsc.github.io/Baccarat/privacy/ (linked from App Store
//  Connect). FR localization auto-applies via Localizable.xcstrings.
//

import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Privacy Policy")
                    .font(.title2.weight(.bold))
                Text("Last updated: October 9, 2026")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    section("What we collect",
                            """
                            • **Account** — your email and a username. If you use the temporary guest mode, we only store an anonymous unique identifier (no email).
                            • **Profile** — your avatar photo (optional) if you add one.
                            • **Games** — the rounds you play — scores, board winners, per-player deltas — to display your debts and history.
                            • **Debts** — who owes you, who you owe. Bilateral "paid" markings between players.
                            """)

                    section("What we don't collect",
                            """
                            No ads, no third-party trackers (Facebook, Google Analytics, etc.). No location data. No phone contacts.
                            """)

                    section("Where your data lives",
                            """
                            Everything is hosted on **Supabase** (EU — West Europe region). Communications are encrypted in transit (TLS). Your games and balances are protected by Row-Level Security: another user can only see games they directly participated in.
                            """)

                    section("Photos",
                            """
                            When you pick a profile picture through the iOS picker, Bakarat only receives the selected image — not your full library. The image is resized to 512×512 and uploaded to your private bucket.
                            """)

                    section("Your rights",
                            """
                            You can at any time:
                            • Sign out from the Profile tab.
                            • Delete your account and all your data yourself, immediately, from the Profile tab (“Delete my account”).
                            • Request a copy of your data by emailing sacha.csc@gmail.com.
                            """)

                    section("Contact",
                            """
                            For any question, write to me: **sacha.csc@gmail.com**
                            """)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ body: String.LocalizationValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            // Text(LocalizedStringKey) interprète déjà le markdown inline, mais on
            // garde le rendu AttributedString d'origine (espaces préservés).
            Text((try? AttributedString(markdown: String(localized: body),
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(String(localized: body)))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}
