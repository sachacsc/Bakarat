//
//  OnlineDealer.swift
//  Bakarat
//
//  Logique pure de distribution d'une manche (host-side). Port direct des
//  fonctions equivalentes dans src/game/* du web. Aucune dépendance UI.
//
//  Workflow :
//   1. determineCardsPerPlayer(N) → 6 / 4 / 0 selon nombre de joueurs.
//   2. dealHands(deck, orderedSeats, target) → distribue round-robin en
//      commençant après le donneur, donneur servi en dernier.
//   3. dealCommunity(deck) → 1 burn + 9 flop + 1 burn + 3 turn + 1 burn +
//      3 river. Le flop est posé board-par-board (B1c1..c3, B2c1..c3, ...).
//      Cf. RULES.md → "Ordre exact des cartes piochées".
//

import Foundation

enum OnlineDealer {

    /// Retourne le nombre de cartes par joueur (0 = trop de joueurs).
    /// 2-5 joueurs : 6 cartes. 6 joueurs : 5 cartes (simplification du web où
    /// c'est 4 reçoivent 6 + 2 reçoivent 5 ; on uniformise pour Phase 2.1).
    /// 7-8 joueurs : 4 cartes.
    static func cardsPerPlayer(activeCount: Int) -> Int {
        switch activeCount {
        case 2...5: return 6
        case 6:     return 5
        case 7...8: return 4
        default:    return 0
        }
    }

    /// Distribue les hole cards. Retourne [seat: [Card]] ou nil si pas assez
    /// de cartes.
    /// `orderedSeats` doit déjà être ordonné dans le sens : 1er à servir →
    /// donneur en dernier.
    static func dealHands(deck: inout [Card],
                          orderedSeats: [Int],
                          target: Int,
                          reserveForCommunity: Int = 18) -> [Int: [Card]]? {
        guard target > 0 else { return nil }
        var hands: [Int: [Card]] = [:]
        for s in orderedSeats { hands[s] = [] }
        for _ in 0..<target {
            for s in orderedSeats {
                if deck.count <= reserveForCommunity { return hands }
                hands[s]!.append(deck.removeFirst())
            }
        }
        return hands
    }

    /// Distribue les cartes communautaires + les 3 brûles + pré-pioche
    /// turns/rivers (à révéler progressivement).
    /// Retourne tout sous forme structurée ; le caller injecte dans le state.
    struct CommunityDeal {
        let burn1: Card
        /// 3 cartes pour chaque board, dans l'ordre B1, B2, B3.
        let flop: [[Card]]
        let burn2: Card
        /// 1 carte pour chaque board.
        let turns: [Card]
        let burn3: Card
        /// 1 carte pour chaque board.
        let rivers: [Card]
        /// Tout ce qui reste après community (sert pour les tiebreaks futurs).
        let remainingPool: [Card]
    }

    static func dealCommunity(deck: inout [Card]) -> CommunityDeal? {
        guard deck.count >= 18 else { return nil }  // 1 + 9 + 1 + 3 + 1 + 3 = 18 cartes
        let burn1 = deck.removeFirst()
        let flop: [[Card]] = (0..<3).map { _ in
            [deck.removeFirst(), deck.removeFirst(), deck.removeFirst()]
        }
        let burn2 = deck.removeFirst()
        let turns = (0..<3).map { _ in deck.removeFirst() }
        let burn3 = deck.removeFirst()
        let rivers = (0..<3).map { _ in deck.removeFirst() }
        let remaining = deck
        deck.removeAll(keepingCapacity: false)
        return CommunityDeal(
            burn1: burn1, flop: flop, burn2: burn2, turns: turns,
            burn3: burn3, rivers: rivers, remainingPool: remaining
        )
    }
}
