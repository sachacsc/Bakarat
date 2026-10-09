//
//  OnboardingView.swift
//  Bakarat
//
//  Shown once at first launch (gated by @AppStorage "hasSeenOnboarding").
//  Paginated TabView walking through the core concepts. The user can skip
//  or open the full RulesView for the long version.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var page: Int = 0
    @State private var showFullRules = false

    private let totalPages = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    page1.tag(0)
                    page2.tag(1)
                    page3.tag(2)
                    page4.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                bottomBar
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if page > 0 {
                        Button("Back") { withAnimation { page -= 1 } }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .navigationDestination(isPresented: $showFullRules) {
                RulesView(onClose: { showFullRules = false })
            }
        }
    }

    // MARK: - Pages

    private var page1: some View {
        VStack(spacing: 20) {
            Spacer()
            BrandLogo(size: 100)
            Text("Welcome to Bakarat")
                .font(.title.weight(.bold))
            Text("Keep score for the card game around a real table, or play online with virtual cards. Bakarat tracks the rounds and settles the debts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            Spacer()
        }
    }

    private var page2: some View {
        VStack(spacing: 20) {
            Spacer()
            HStack(spacing: 16) {
                modeCard(icon: "list.bullet.clipboard.fill", title: "Counter",
                         body: "Real cards in hand, app tracks the score.")
                modeCard(icon: "gamecontroller.fill", title: "Online",
                         body: "Cards dealt virtually, share a 4-char code to join.")
            }
            .padding(.horizontal, 24)
            Text("Two ways to play")
                .font(.title2.weight(.bold))
                .padding(.top, 20)
            Text("Pick the one that fits the moment. Both share the same scoring rules and the same account book.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            Spacer()
        }
    }

    private var page3: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 6) {
                cardRow(["AS","KH","QS","JC","TD"])
                cardRow(["2C","5D","9S","JH","KC"])
                cardRow(["3H","7S","TH","QD","AC"])
            }
            Text("Three boards per round")
                .font(.title2.weight(.bold))
                .padding(.top, 12)
            Text("Each board has 5 community cards. You combine them with your own hand to make the strongest 7-card hand: pair, flush, four of a kind, all the way up to a royal flush.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
    }

    private var page4: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "eurosign.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.brandRed)
            Text("The account book")
                .font(.title2.weight(.bold))
                .padding(.top, 8)
            Text("After each round the app updates the debts. The Accounts tab shows who owes you what, Tricount style. Tap “Mark as paid” when someone settles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Button {
                showFullRules = true
            } label: {
                Text("See full rules →")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.brandRed)
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                if page < totalPages - 1 {
                    withAnimation { page += 1 }
                } else {
                    dismiss()
                }
            } label: {
                Text(page < totalPages - 1 ? "Next" : "Let's play")
                    .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func cardRow(_ codes: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(codes, id: \.self) { c in
                CardImageView(card: Card(c), width: 44)
            }
        }
    }

    private func modeCard(icon: String, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.brandRed)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dismiss() {
        isPresented = false
    }
}
