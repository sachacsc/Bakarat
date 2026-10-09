//
//  CounterModels.swift
//  Bakarat
//
//  SwiftData models pour le tab Compteur (mode Tricount-style). Un Counter
//  représente un groupe d'amis qui jouent ensemble plusieurs fois : joueurs +
//  scores cumulés + historique des manches. Persistance locale via SwiftData.
//  Le cloudGameId pointe vers la ligne `games` Supabase pour synchro serveur.
//

import Foundation
import SwiftData

@Model
final class Counter {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Prix d'une "ligne" (= un board perdu, avant multi). Ex : 1.0 €.
    var linePrice: Double
    /// Symbole monétaire affiché ("€", "$", "£"…).
    var currency: String
    /// Index du dealer courant (0..players.count-1). Tourne après chaque manche.
    var dealerIdx: Int
    /// True dès que le setup initial (joueurs + prix) a été validé.
    var configured: Bool
    /// games.id Supabase une fois la 1re manche cloud-sync. Null avant.
    var cloudGameId: UUID?
    /// JSON `{"<seat>": "<placeholderUUID>"}` pour les seats NON-host mappés à
    /// un placeholder créé via `create_placeholder_user`. Le seat du host
    /// n'apparaît PAS ici (son user_id vient d'AuthService).
    var cloudSeatMapJSON: String?
    /// Seat correspondant au user loggué (host) — choisi via le picker
    /// "C'est moi" à la création. Tous les autres seats sont des
    /// placeholders. nil pour les compteurs créés avant l'ajout du picker.
    var hostSeatIndex: Int?
    var createdAt: Date
    var lastUsedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CounterPlayer.counter)
    var players: [CounterPlayer] = []

    @Relationship(deleteRule: .cascade, inverse: \CounterManche.counter)
    var manches: [CounterManche] = []

    init(id: UUID = UUID(),
         name: String,
         linePrice: Double = 1.0,
         currency: String = "€",
         dealerIdx: Int = 0,
         configured: Bool = false,
         createdAt: Date = .now,
         lastUsedAt: Date = .now) {
        self.id = id
        self.name = name
        self.linePrice = linePrice
        self.currency = currency
        self.dealerIdx = dealerIdx
        self.configured = configured
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

@Model
final class CounterPlayer {
    @Attribute(.unique) var id: UUID
    /// Position dans le compteur : 0..n-1. Stable même si on ajoute/retire.
    var seat: Int
    var name: String
    /// Solde cumulé (positif = lui doit / négatif = doit aux autres).
    var score: Double
    /// Si false → joueur "inactif" : son solde reste intact mais il n'apparaît
    /// pas dans la card joueurs principale et ne participe pas aux nouvelles
    /// manches. Réactivable depuis EditPlayersSheet.
    var isActive: Bool = true
    var counter: Counter?

    init(id: UUID = UUID(), seat: Int, name: String, score: Double = 0, isActive: Bool = true) {
        self.id = id
        self.seat = seat
        self.name = name
        self.score = score
        self.isActive = isActive
    }
}

@Model
final class CounterManche {
    @Attribute(.unique) var id: UUID
    /// Numéro affiché (#1, #2, …). Stable même si on supprime des manches.
    var number: Int
    /// Seat du dealer pour cette manche.
    var dealerSeat: Int
    var validatedAt: Date
    /// JSON `[{board:0,winnerSeat:1,multi:2,isFullBoard:false}, …]`.
    /// 3 entries en mode normal, mais on garde flexible pour évolutions.
    var boardResultsJSON: String
    /// JSON `{"0": -2.0, "1": 4.0, "2": -2.0}` (seat → delta de cette manche).
    /// La somme doit valoir 0 (sauf ajustement manuel : peut différer).
    var perPlayerDeltasJSON: String
    /// True quand cette entrée représente un ajustement manuel de soldes
    /// (transfert hors-jeu, correction post-soirée…). boardResultsJSON est
    /// vide dans ce cas, et perPlayerDeltas peut ne pas sommer à 0.
    var isManualAdjustment: Bool = false
    /// True une fois cette manche poussée avec succès vers Supabase via
    /// `record_manche`. Sert à rattraper les manches jouées offline lors
    /// de la prochaine sync (CounterCloudSync pousse en ordre les non-syncées).
    var isSyncedToCloud: Bool = false
    var counter: Counter?

    init(id: UUID = UUID(),
         number: Int,
         dealerSeat: Int,
         validatedAt: Date = .now,
         boardResultsJSON: String = "[]",
         perPlayerDeltasJSON: String = "{}",
         isManualAdjustment: Bool = false) {
        self.id = id
        self.number = number
        self.dealerSeat = dealerSeat
        self.validatedAt = validatedAt
        self.boardResultsJSON = boardResultsJSON
        self.perPlayerDeltasJSON = perPlayerDeltasJSON
        self.isManualAdjustment = isManualAdjustment
    }
}

// MARK: - Codables embarqués dans les JSON

/// Résultat d'un board dans une manche du compteur. winnerSeat = nil →
/// board abandonné (personne ne paie ce board).
struct CounterBoardResult: Codable, Hashable {
    var board: Int
    /// Gagnant final (après éventuels tie-breaks).
    var winnerSeat: Int?
    /// Multiplicateur final appliqué (du dernier niveau de split si tie-break,
    /// sinon de l'annonce principale).
    var multi: Int
    /// True si ce seat a gagné les 3 boards de la manche (bonus).
    var isFullBoard: Bool
    /// Si non-nil et non-vide → ce board a déclenché un tie-break. Liste des
    /// seats des splitters (ceux qui étaient ex-aequo au niveau de la mise).
    /// Les non-splitters paient au multi base (×1), pas au multi final.
    var splitterSeats: [Int]?
}

extension CounterManche {
    var boardResults: [CounterBoardResult] {
        get {
            guard let data = boardResultsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([CounterBoardResult].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            boardResultsJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var perPlayerDeltas: [Int: Double] {
        get {
            guard let data = perPlayerDeltasJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues:
                decoded.compactMap { (k, v) in Int(k).map { ($0, v) } })
        }
        set {
            let stringKeyed = Dictionary(uniqueKeysWithValues:
                newValue.map { (String($0.key), $0.value) })
            let data = (try? JSONEncoder().encode(stringKeyed)) ?? Data("{}".utf8)
            perPlayerDeltasJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
    }
}

extension Counter {
    /// Mapping seat → placeholder UUID décodé depuis cloudSeatMapJSON.
    /// Le seat du host n'apparait PAS dans ce dict.
    var placeholderIdsBySeat: [Int: UUID] {
        get {
            guard let json = cloudSeatMapJSON,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues:
                decoded.compactMap { (k, v) in
                    guard let seat = Int(k), let uuid = UUID(uuidString: v) else { return nil }
                    return (seat, uuid)
                })
        }
        set {
            let stringKeyed = Dictionary(uniqueKeysWithValues:
                newValue.map { (String($0.key), $0.value.uuidString) })
            let data = (try? JSONEncoder().encode(stringKeyed)) ?? Data("{}".utf8)
            cloudSeatMapJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// Joueurs triés par seat (ordre stable d'affichage).
    var playersOrdered: [CounterPlayer] {
        players.sorted { $0.seat < $1.seat }
    }

    /// Joueurs actifs triés par seat (ceux qui participent aux nouvelles manches).
    var activePlayersOrdered: [CounterPlayer] {
        players.filter { $0.isActive }.sorted { $0.seat < $1.seat }
    }

    /// Joueurs inactifs triés par seat.
    var inactivePlayersOrdered: [CounterPlayer] {
        players.filter { !$0.isActive }.sorted { $0.seat < $1.seat }
    }

    /// Manches triées par date décroissante (les ajustements manuels
    /// s'interleavent chronologiquement avec les manches normales).
    var manchesOrdered: [CounterManche] {
        manches.sorted { $0.validatedAt > $1.validatedAt }
    }

    /// Numéro de la prochaine manche normale (ignore les ajustements manuels).
    var nextMancheNumber: Int {
        (manches.filter { !$0.isManualAdjustment }.map { $0.number }.max() ?? 0) + 1
    }

    /// Initiale affichée dans la chip de la liste.
    var initial: String {
        guard let c = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }

    /// Sous-titre liste : "3 manches · 5 joueurs · il y a 2h".
    var subtitle: String {
        var parts: [String] = []
        if !manches.isEmpty {
            parts.append((manches.count > 1 ? String(localized: "\(manches.count) manches") : String(localized: "1 manche")))
        }
        if !players.isEmpty {
            parts.append((players.count > 1 ? String(localized: "\(players.count) joueurs") : String(localized: "1 joueur")))
        }
        parts.append(lastUsedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
