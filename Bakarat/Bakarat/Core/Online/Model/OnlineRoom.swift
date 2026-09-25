//
//  OnlineRoom.swift
//  Bakarat
//
//  Modèles de la « salle durable » : ce que `online_rooms.state` contient
//  (encodé/décodé tel quel en jsonb par les RPC `room_*`).
//

import Foundation

/// Rôle du user courant dans la room.
enum OnlineRole: Equatable {
    case host
    case guest
}

/// Participant d'une room. Stable par user_id (UUID Supabase).
struct OnlineParticipant: Codable, Identifiable, Hashable {
    let userId: UUID
    var displayName: String
    var isHost: Bool
    /// Marquage UI : présence côté Realtime
    var isOnline: Bool = true

    var id: UUID { userId }
}

/// État courant de la room du point de vue du client. Le host est la source de vérité,
/// les guests reçoivent les snapshots via broadcast.
struct OnlineRoom: Codable, Equatable {
    let code: String
    /// L'hôte courant. **var** car le rôle peut être transféré en cours de
    /// partie (déco de l'hôte, ou hôte passant en spectateur).
    var hostUserId: UUID
    var participants: [OnlineParticipant]
    /// Status simplifié : 'lobby' au début, 'playing' une fois la partie lancée.
    var status: Status
    /// Prix de la ligne configuré par le host (visible en lobby, fixe pendant la partie).
    var linePrice: Double = 2.5
    /// Mode Flash : manche raccourcie (tempo réduit + auto-skip plus agressif).
    var flashMode: Bool = false
    /// Timer par annonce, en secondes (0 = désactivé, sinon countdown rolling).
    var announceTimerSeconds: Int = 0
    /// État de la manche en cours. nil tant qu'on est en lobby ou que la partie n'a pas démarré.
    var gameState: OnlineGameState?
    /// UUID Supabase de la `games` créée à la 1ère manche persistée (retourné par
    /// `record_manche`). Nil tant qu'aucune manche n'a été sauvegardée. Réutilisé
    /// pour les manches suivantes.
    var cloudGameId: UUID? = nil
    /// Historique des manches terminées (delta par joueur, gagnants par board).
    /// Visible dans le sheet "Solde & historique" depuis la toolbar de l'écran
    /// de jeu.
    var pastManches: [MancheArchive] = []

    enum Status: String, Codable {
        case lobby
        case playing
        case finished
    }

    enum CodingKeys: String, CodingKey {
        case code, hostUserId, participants, status,
             linePrice, flashMode, announceTimerSeconds, gameState, cloudGameId,
             pastManches
    }

    init(code: String,
         hostUserId: UUID,
         participants: [OnlineParticipant],
         status: Status,
         linePrice: Double = 2.5,
         flashMode: Bool = false,
         announceTimerSeconds: Int = 0,
         gameState: OnlineGameState? = nil,
         cloudGameId: UUID? = nil,
         pastManches: [MancheArchive] = []) {
        self.code = code
        self.hostUserId = hostUserId
        self.participants = participants
        self.status = status
        self.linePrice = linePrice
        self.flashMode = flashMode
        self.announceTimerSeconds = announceTimerSeconds
        self.gameState = gameState
        self.cloudGameId = cloudGameId
        self.pastManches = pastManches
    }

    // Decoding tolérant : si un client envoie un snapshot sans les nouveaux champs,
    // on tombe sur les valeurs par défaut au lieu de tout planter.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code           = try c.decode(String.self, forKey: .code)
        self.hostUserId     = try c.decode(UUID.self,   forKey: .hostUserId)
        self.participants   = try c.decode([OnlineParticipant].self, forKey: .participants)
        self.status         = try c.decode(Status.self, forKey: .status)
        self.linePrice      = try c.decodeIfPresent(Double.self, forKey: .linePrice) ?? 2.5
        self.flashMode      = try c.decodeIfPresent(Bool.self,   forKey: .flashMode) ?? false
        self.announceTimerSeconds = try c.decodeIfPresent(Int.self, forKey: .announceTimerSeconds) ?? 0
        self.gameState      = try c.decodeIfPresent(OnlineGameState.self, forKey: .gameState)
        self.cloudGameId    = try c.decodeIfPresent(UUID.self, forKey: .cloudGameId)
        self.pastManches    = try c.decodeIfPresent([MancheArchive].self, forKey: .pastManches) ?? []
    }
}

/// Archive d'une manche terminée — gardée dans `OnlineRoom.pastManches` pour
/// l'historique affiché à l'utilisateur.
struct MancheArchive: Codable, Equatable, Identifiable {
    let mancheNumber: Int
    let dealerSeat: Int
    /// Delta de score net par seat sur cette manche.
    let perPlayerDelta: [Int: Double]
    /// Liste des boards remportés par chaque joueur (seat → [boardIdx]).
    let boardsWon: [Int: [Int]]
    /// Seat du full-board winner si applicable.
    let fullBoardWinnerSeat: Int?
    /// Nombre de joueurs actifs sur cette manche.
    let numActive: Int
    /// Multiplicateur effectif de chaque board (board → multi). Permet
    /// d'afficher "B1×8" dans l'historique pour les annonces fortes.
    let boardMultis: [Int: Int]

    var id: Int { mancheNumber }

    enum CodingKeys: String, CodingKey {
        case mancheNumber, dealerSeat, perPlayerDelta, boardsWon,
             fullBoardWinnerSeat, numActive, boardMultis
    }

    init(mancheNumber: Int, dealerSeat: Int,
         perPlayerDelta: [Int: Double], boardsWon: [Int: [Int]],
         fullBoardWinnerSeat: Int?, numActive: Int,
         boardMultis: [Int: Int]) {
        self.mancheNumber = mancheNumber
        self.dealerSeat = dealerSeat
        self.perPlayerDelta = perPlayerDelta
        self.boardsWon = boardsWon
        self.fullBoardWinnerSeat = fullBoardWinnerSeat
        self.numActive = numActive
        self.boardMultis = boardMultis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mancheNumber = try c.decode(Int.self, forKey: .mancheNumber)
        self.dealerSeat = try c.decode(Int.self, forKey: .dealerSeat)
        self.perPlayerDelta = try c.decode([Int: Double].self, forKey: .perPlayerDelta)
        self.boardsWon = try c.decode([Int: [Int]].self, forKey: .boardsWon)
        self.fullBoardWinnerSeat = try c.decodeIfPresent(Int.self, forKey: .fullBoardWinnerSeat)
        self.numActive = try c.decodeIfPresent(Int.self, forKey: .numActive) ?? 0
        self.boardMultis = try c.decodeIfPresent([Int: Int].self, forKey: .boardMultis) ?? [:]
    }
}

// MARK: - Room code generation

enum RoomCode {
    /// Génère un code à 4 caractères majuscules + chiffres lisibles (pas de 0/O/1/I).
    static func random() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
}
