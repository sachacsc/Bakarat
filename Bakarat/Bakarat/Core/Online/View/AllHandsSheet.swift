//
//  AllHandsSheet.swift
//  Bakarat
//
//  Sheet pour voir les annonces de tous les joueurs sur un board donné, classées
//  de la plus forte à la plus faible. Pour chaque joueur, on affiche UNIQUEMENT
//  les cartes qu'il a sélectionnées pour son annonce (et pas toute sa main).
//

import SwiftUI

/// Cible du sheet "Autres mains" : soit un des 3 boards réguliers, soit
/// un round de tie-break (identifié par parentBoardIdx + round).
enum AllHandsTarget: Identifiable, Hashable {
    case board(idx: Int)
    case tiebreak(parent: Int, round: Int)

    var id: String {
        switch self {
        case .board(let i):              return "board-\(i)"
        case .tiebreak(let p, let r):    return "tb-\(p)-\(r)"
        }
    }
}

struct AllHandsSheet: View {
    let gs: OnlineGameState
    let target: AllHandsTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    boardHeader
                    Divider().padding(.horizontal, 16)
                    playersList
                }
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(Theme.brandRed)
                }
            }
        }
    }

    // MARK: - Données dérivées du target

    /// Cartes du board affichées en haut du sheet.
    private var boardCards: [Card] {
        switch target {
        case .board(let idx):
            return gs.communityCards[idx]
        case .tiebreak(let parent, let round):
            return gs.tiebreakBoards.first {
                $0.parentBoardIdx == parent && $0.round == round
            }?.cards ?? []
        }
    }

    /// Résultat du board (perPlayer = lignes à afficher).
    private var result: BoardResult? {
        switch target {
        case .board(let idx):
            return gs.boardResults[idx]
        case .tiebreak(let parent, let round):
            return gs.tiebreakBoards.first {
                $0.parentBoardIdx == parent && $0.round == round
            }?.result
        }
    }

    private var navTitle: String {
        switch target {
        case .board(let idx):
            return "Board \(idx + 1)"
        case .tiebreak(let parent, let round):
            return round == 0
                ? "Split B\(parent + 1)"
                : "Split B\(parent + 1) · round \(round + 1)"
        }
    }

    // MARK: - Board en haut

    @ViewBuilder
    private var boardHeader: some View {
        VStack(spacing: 8) {
            Text("Tableau")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(boardCards, id: \.self) { c in
                    CardImageView(card: c, width: 52)
                }
            }
        }
    }

    // MARK: - Liste classée

    @ViewBuilder
    private var playersList: some View {
        VStack(spacing: 10) {
            ForEach(Array(rankedRows.enumerated()), id: \.element.player.seat) { idx, row in
                playerRow(rank: idx + 1, row: row)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func playerRow(rank: Int, row: RankedRow) -> some View {
        HStack(spacing: 12) {
            // Rang
            Text("#\(rank)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(rank == 1 ? Theme.brandRed : .secondary)
                .frame(width: 26)

            // Avatar
            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(row.player.displayName.prefix(1)).uppercased())
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                )

            // Nom + catégorie/état
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.player.displayName)
                        .font(.subheadline.weight(.semibold))
                    if row.isWinner {
                        Text("🏆")
                            .font(.caption)
                    } else if row.isSplitter {
                        Text("⚡")
                            .font(.caption)
                    }
                }
                Text(row.statusLabel)
                    .font(.caption)
                    .foregroundStyle(row.statusColor)
            }

            Spacer()

            // Cartes annoncées (et pas la main entière)
            HStack(spacing: 4) {
                ForEach(row.cards, id: \.self) { c in
                    CardImageView(card: c, width: 34)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(row.isWinner ? Theme.brandRed.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Computed

    private struct RankedRow {
        let player: GamePlayer
        let cards: [Card]
        let statusLabel: String
        let statusColor: Color
        let isWinner: Bool
        let isSplitter: Bool
        /// Force de la main si évaluable (utilisée pour le tri). Skip/forfeit → nil.
        let value: HandValue?
    }

    /// Lignes triées : valides en premier (par force décroissante), puis bluffs,
    /// puis skip/forfeit/excluded en dernier.
    private var rankedRows: [RankedRow] {
        guard let result = self.result else { return [] }
        let boardCards = self.boardCards
        let splitters = Set(result.splitterSeats)

        let rows: [RankedRow] = result.perPlayer.compactMap { row in
            guard let player = gs.players.first(where: { $0.seat == row.seat }) else { return nil }
            let isWinner = (result.winnerSeat == row.seat) && !result.isSplit
            let isSplitter = splitters.contains(row.seat)

            // Display cards : pour Hauteur ou cards vides, on essaie d'auto-pick
            // pour avoir quelque chose à montrer. Sinon les cartes annoncées.
            var displayCards: [Card] = row.cards
            if displayCards.isEmpty,
               let catId = row.announcedCategoryId,
               let cat = HandCategory.from(id: catId),
               !row.isSkip, !row.isForfeit, !row.isExcluded,
               let hole = gs.hands[row.seat], !hole.isEmpty {
                displayCards = HandEvaluator.autoPickCards(announced: cat, hole: hole, board: boardCards) ?? []
            }

            // Force de la main : avec la main complète si on la connaît, sinon
            // avec les cartes soumises (l'état est expurgé côté guest — T14).
            let value: HandValue? = {
                guard !row.isSkip, !row.isForfeit, !row.isExcluded else { return nil }
                if let hole = gs.hands[row.seat], !hole.isEmpty {
                    return HandEvaluator.evaluateBest(hole + boardCards)
                }
                guard !displayCards.isEmpty else { return nil }
                return HandEvaluator.evaluateBest(displayCards + boardCards)
            }()

            let (label, color): (String, Color) = {
                if row.isExcluded { return ("Exclu", .gray) }
                if row.isForfeit  { return ("Forfait", .gray) }
                if row.isSkip     { return ("Skip", .gray) }
                if row.isBluff    {
                    if let catId = row.announcedCategoryId, let cat = HandCategory.from(id: catId) {
                        return ("Invalide (\(cat.label))", .red)
                    }
                    return ("Invalide", .red)
                }
                if let catId = row.announcedCategoryId, let cat = HandCategory.from(id: catId) {
                    return (cat.label, .secondary)
                }
                return ("—", .secondary)
            }()

            return RankedRow(player: player,
                             cards: displayCards,
                             statusLabel: label,
                             statusColor: color,
                             isWinner: isWinner,
                             isSplitter: isSplitter,
                             value: value)
        }

        return rows.sorted { a, b in
            // 1) Les rows avec value (= a annoncé valide) avant celles sans
            switch (a.value, b.value) {
            case (let av?, let bv?): return HandEvaluator.compare(av, bv) > 0
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }
}
