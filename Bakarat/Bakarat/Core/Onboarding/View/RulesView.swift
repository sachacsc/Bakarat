//
//  RulesView.swift
//  Bakarat
//
//  Full walkthrough of how Bakarat is played. Tries to match what's
//  actually shipped in the app (counter mode UI is the simplest model
//  of truth: pick a winner per board + a multi tier). The physical deal
//  explanation matches the source counters use around a real table.
//

import SwiftUI

struct RulesView: View {
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    // Example deck used throughout the walkthrough so the user follows
    // one concrete game from deal to settlement.
    private let board1: [String] = ["8H", "JS", "2C", "9D", "AS"]
    private let board2: [String] = ["KH", "KD", "5C", "QS", "3H"]
    private let board3: [String] = ["AC", "AS", "AD", "AH", "7C"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                intro
                playersAndDeck
                cardsPerPlayer
                dealingTheBoards
                announcingWinner
                multiTiers
                scoring
                fullBoard
                splitSection
                wrapUp
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("How to play")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Bakarat")
                .font(.title.weight(.bold))
            Text("A card game played around a table with friends. Each round splits into 3 community boards. Whoever makes the strongest hand on a board wins it, and gets paid by the losers based on a fixed line price.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var playersAndDeck: some View {
        ruleCard(title: "Players and deck") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("**1 standard deck** of 52 cards.")
                bullet("**2 to 8 active players** per round.")
                bullet("The dealer rotates after each round (clockwise).")
                bullet("Before starting, players agree on a **line price** (often €2.50).")
            }
        }
    }

    private var cardsPerPlayer: some View {
        ruleCard(title: "How many cards each player gets") {
            VStack(alignment: .leading, spacing: 10) {
                Text("It depends on table size:")
                    .font(.subheadline)
                VStack(spacing: 0) {
                    tableRow("2 to 5 players", "6 cards each", isHeader: false)
                    Divider()
                    tableRow("6 players", "5 cards each", isHeader: false)
                    Divider()
                    tableRow("7 to 8 players", "4 cards each", isHeader: false)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("The dealer is served last. Distribution starts with the player on their left and goes clockwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dealingTheBoards: some View {
        ruleCard(title: "Dealing the boards") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Three boards are laid out in front of all players. They get filled in three passes:")
                    .font(.subheadline)

                phaseBlock(
                    number: "1",
                    title: "Burn, then flop",
                    body: "Burn 1 card (face down, ignored). Then deal **3 cards face-up on Board 1**, then **3 on Board 2**, then **3 on Board 3**. That's the flop, board by board."
                )
                HStack(spacing: 6) {
                    cardRow(Array(board1.prefix(3)))
                }
                HStack(spacing: 6) {
                    cardRow(Array(board2.prefix(3)))
                }
                HStack(spacing: 6) {
                    cardRow(Array(board3.prefix(3)))
                }

                phaseBlock(
                    number: "2",
                    title: "Burn, then turn",
                    body: "Burn another card. Add **1 card to Board 1**, **1 to Board 2**, **1 to Board 3**. Each board now has 4 cards."
                )

                phaseBlock(
                    number: "3",
                    title: "Burn, then river",
                    body: "Burn one last card. Add the final card on each board. Each board ends up with **5 community cards**."
                )

                VStack(spacing: 4) {
                    cardRow(board1)
                    cardRow(board2)
                    cardRow(board3)
                }
                .padding(.top, 4)

                Text("In short: 3 burns total, 5 cards per board, 3 boards. The 3 boards are played independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var announcingWinner: some View {
        ruleCard(title: "Who wins a board") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Each player makes the strongest **5-card hand** using exactly **2 cards from their hand** and the **5 cards on the board**, Texas Hold'em style. The strongest 5-card hand wins the board, following standard poker rankings: high card, pair, two pair, three of a kind, straight, flush, full, four of a kind, straight flush, royal flush.")
                    .font(.subheadline)
                Text("Bakarat cares about **which tier** the winning hand falls into. That tier sets the multiplier.")
                    .font(.subheadline)
            }
        }
    }

    private var multiTiers: some View {
        ruleCard(title: "Multiplier tiers") {
            VStack(alignment: .leading, spacing: 14) {
                multiRow(
                    label: "Normal",
                    multi: "×1",
                    desc: "High card through full house. Most boards land here."
                )
                Divider()
                multiRow(
                    label: "Four of a kind",
                    multi: "×8",
                    desc: "Same rank, four of them. Triggers the first big multiplier."
                )
                exampleHand(hand: ["AS","AH"], board: ["AC","AD","2H","5S","7C"])

                Divider()
                multiRow(
                    label: "Straight flush",
                    multi: "×16",
                    desc: "Five consecutive cards, same suit."
                )
                exampleHand(hand: ["9S","TS"], board: ["JS","QS","KS","2H","5C"])

                Divider()
                multiRow(
                    label: "Royal flush",
                    multi: "×20",
                    desc: "10 to Ace, same suit. The strongest possible hand."
                )
                exampleHand(hand: ["TS","JS"], board: ["QS","KS","AS","2H","5C"])
            }
        }
    }

    private var scoring: some View {
        ruleCard(title: "Scoring") {
            VStack(alignment: .leading, spacing: 10) {
                Text("With N active players, line price `p`, and the winner's multiplier `m`:")
                    .font(.subheadline)
                bullet("**Winner** gets `p × m × (N − 1)`.")
                bullet("**Each other player** pays `p × m`.")

                Text("Example with 4 players at €2.50 per line:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                exampleScoring(
                    boardLabel: "Board 1",
                    desc: "Alice wins with a pair (×1).",
                    rows: [("Alice", "+€7.50"), ("Bob, Charlie, Daniel", "−€2.50 each")]
                )
                exampleScoring(
                    boardLabel: "Board 2",
                    desc: "Bob wins with four of a kind (×8).",
                    rows: [("Bob", "+€60.00"), ("Alice, Charlie, Daniel", "−€20.00 each")]
                )
                exampleScoring(
                    boardLabel: "Board 3",
                    desc: "Charlie wins with a straight (×1).",
                    rows: [("Charlie", "+€7.50"), ("Alice, Bob, Daniel", "−€2.50 each")]
                )

                Text("End of round, net deltas: Alice +€2.50, Bob +€35.00, Charlie −€15.00, Daniel −€22.50. Sum = 0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    private var fullBoard: some View {
        ruleCard(title: "Full Board bonus") {
            VStack(alignment: .leading, spacing: 8) {
                Text("If the **same player wins all 3 boards** of a round, they get a Full Board bonus on top of the per-board payouts.")
                    .font(.subheadline)
                bullet("Winner gets `p × (N − 1)` extra.")
                bullet("Each other player pays `p × 1` extra.")
                Text("In a manual counter, the app highlights a Full Board banner once you've selected the same winner on the 3 boards, so you can double-check before validating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var splitSection: some View {
        ruleCard(title: "Split (tie-break)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("If two or more players tie at the top of a board, they go to a split. In the manual counter, just tick the multiple players who tied. A new selection grid appears below to pick the final winner among them.")
                    .font(.subheadline)
                bullet("Splitters pay the winner at the **tie-break multiplier**.")
                bullet("Non-splitters pay the winner at **×1**.")
            }
        }
    }

    private var wrapUp: some View {
        ruleCard(title: "After the round") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each round, balances update automatically. The Accounts tab shows the running ledger: who owes you, who you owe, in minimal transactions.")
                    .font(.subheadline)
                Text("Tap **Paid** on a debt to mark it settled. The other player sees it instantly. The game session greys out once everyone is squared up.")
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func ruleCard<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Markdown inline (gras, code) sur une chaîne déjà localisée.
    private static func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private func bullet(_ text: String.LocalizationValue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.subheadline).foregroundStyle(.secondary)
            Text(Self.inlineMarkdown(String(localized: text)))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tableRow(_ label: LocalizedStringKey, _ value: LocalizedStringKey, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(isHeader ? .caption.weight(.bold) : .caption)
                .foregroundStyle(isHeader ? .secondary : .primary)
                .frame(minWidth: 110, alignment: .leading)
            Text(value)
                .font(isHeader ? .caption.weight(.bold) : .caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func phaseBlock(number: String, title: LocalizedStringKey, body: String.LocalizationValue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.brandRed))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(Self.inlineMarkdown(String(localized: body)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cardRow(_ codes: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(codes, id: \.self) { c in
                CardImageView(card: Card(c), width: 42)
            }
        }
    }

    private func multiRow(label: LocalizedStringKey, multi: String, desc: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(multi)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.brandRed))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exampleHand(hand: [String], board: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(hand, id: \.self) { c in
                CardImageView(card: Card(c), width: 32)
            }
            Text("+").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            ForEach(board, id: \.self) { c in
                CardImageView(card: Card(c), width: 32)
            }
        }
    }

    private func exampleScoring(boardLabel: String, desc: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(boardLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
                Text(desc).font(.caption)
            }
            ForEach(rows, id: \.0) { (who, amount) in
                HStack {
                    Text(who).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(amount).font(.caption2.monospaced()).foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
