//
//  OnlineRulesTests.swift
//  BakaratTests
//
//  T30 (docs/PLAN_ONLINE_V2.md — P3) : les règles pures, sans réseau.
//  Tout ce qui est vérifié ici est la source de vérité de RULES.md :
//  nombre de cartes par joueur, ordre de distribution (donneur en dernier),
//  ordre EXACT des cartes communautaires (flop board par board, puis une
//  carte par board au turn et au river), construction de l'état initial,
//  force des mains, et enfin l'encodage JSON de `OnlineRoom` (ce qui part
//  dans `online_rooms.state`).
//
//  Ces tests tournent dans la loop (`scripts/online-loop.sh --only unit`) et
//  en CI. Aucun d'eux ne touche Supabase.
//

import Foundation
import Testing
@testable import Bakarat

@MainActor
@Suite("T30 · Règles online (pur, sans réseau)")
struct OnlineRulesTests {

    // MARK: - Outils

    /// Deck canonique non mélangé : `Deck.full[0]` = 2♣, puis 2♦, 2♥, 2♠, 3♣…
    /// On travaille dessus pour que l'ordre de pioche soit observable.
    private static let ordered = Deck.full

    /// Participants factices (l'identité exacte n'a pas d'importance ici).
    private static func participants(_ n: Int) -> [OnlineParticipant] {
        (0..<n).map { i in
            OnlineParticipant(userId: UUID(), displayName: "J\(i)", isHost: i == 0)
        }
    }

    private static func card(_ s: String) -> Card {
        guard let c = Card(s) else { fatalError("carte de test invalide : \(s)") }
        return c
    }

    // MARK: - cardsPerPlayer (RULES.md § Distribution)

    @Test("cardsPerPlayer : 2-5 → 6, 6 → 5, 7-8 → 4, au-delà → 0")
    func cardsPerPlayer() {
        for n in 2...5 {
            #expect(OnlineDealer.cardsPerPlayer(activeCount: n) == 6,
                    "\(n) joueurs actifs doivent recevoir 6 cartes")
        }
        // Le web distribue 4×6 + 2×5 à six joueurs ; l'app uniformise à 5
        // (choix documenté dans OnlineDealer). C'est ce comportement-là qui
        // est gelé par ce test.
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 6) == 5)
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 7) == 4)
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 8) == 4)
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 9) == 0, "9 joueurs : non supporté")
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 1) == 0)
        #expect(OnlineDealer.cardsPerPlayer(activeCount: 0) == 0)
    }

    // MARK: - dealHands (donneur servi en dernier)

    @Test("dealHands : round-robin, le donneur est servi en dernier")
    func dealHandsDealerLast() throws {
        var deck = Self.ordered
        // Donneur = seat 0 → on commence après lui et on le sert en dernier.
        let orderedSeats = [1, 2, 3, 0]
        let dealt = OnlineDealer.dealHands(deck: &deck, orderedSeats: orderedSeats, target: 2)
        let hands = try #require(dealt)

        #expect(hands.count == 4)
        // Tour 1 = cartes 0..3 dans l'ordre des seats, tour 2 = cartes 4..7.
        #expect(hands[1] == [Self.ordered[0], Self.ordered[4]])
        #expect(hands[2] == [Self.ordered[1], Self.ordered[5]])
        #expect(hands[3] == [Self.ordered[2], Self.ordered[6]])
        #expect(hands[0] == [Self.ordered[3], Self.ordered[7]],
                "le donneur (dernier de orderedSeats) reçoit la dernière carte de chaque tour")
        #expect(deck.count == 52 - 8, "8 cartes consommées, le reste est intact")
        #expect(deck.first == Self.ordered[8])
    }

    @Test("dealHands : target 0 → nil (trop de joueurs)")
    func dealHandsRefusesZeroTarget() {
        var deck = Self.ordered
        let refused = OnlineDealer.dealHands(deck: &deck, orderedSeats: [0, 1], target: 0)
        #expect(refused == nil)
        #expect(deck.count == 52, "aucun prélèvement en cas de refus")
    }

    @Test("dealHands : la réserve communautaire n'est jamais entamée")
    func dealHandsKeepsCommunityReserve() throws {
        // 22 cartes, 4 joueurs, 6 cartes visées : il ne peut y en avoir que 4
        // avant d'atteindre la réserve de 18.
        var deck = Array(Self.ordered.prefix(22))
        let partial = OnlineDealer.dealHands(deck: &deck, orderedSeats: [1, 2, 3, 0], target: 6)
        let hands = try #require(partial)
        #expect(deck.count >= 18, "la réserve des 18 cartes communautaires reste entière")
        let dealtCount = hands.values.reduce(0) { $0 + $1.count }
        #expect(dealtCount == 22 - deck.count)
    }

    // MARK: - dealCommunity (ordre EXACT de RULES.md)

    @Test("dealCommunity : burn, 3 flops board par board, burn, 3 turns, burn, 3 rivers")
    func dealCommunityOrder() throws {
        var deck = Self.ordered
        let deal = OnlineDealer.dealCommunity(deck: &deck)
        let d = try #require(deal)
        let f = Self.ordered

        // [burn] 1,2,3 6,7,8 11,12,13 [burn] 4,9,14 [burn] 5,10,15
        #expect(d.burn1 == f[0])
        #expect(d.flop[0] == [f[1], f[2], f[3]], "flop du Board 1 = 3 cartes d'affilée")
        #expect(d.flop[1] == [f[4], f[5], f[6]], "puis le Board 2 — jamais colonne par colonne")
        #expect(d.flop[2] == [f[7], f[8], f[9]])
        #expect(d.burn2 == f[10])
        #expect(d.turns == [f[11], f[12], f[13]], "turn : une carte par board, B1 → B2 → B3")
        #expect(d.burn3 == f[14])
        #expect(d.rivers == [f[15], f[16], f[17]])

        // 3 brûles + 15 cartes de board = 18 cartes consommées (RULES.md,
        // tableau « Cartes utilisées par manche »).
        #expect(d.remainingPool.count == 52 - 18)
        #expect(d.remainingPool.first == f[18])
        #expect(deck.isEmpty, "dealCommunity vide le deck et rend le reste dans remainingPool")
    }

    @Test("dealCommunity : 18 cartes suffisent tout juste, le pool est alors vide")
    func dealCommunityExactlyEighteen() throws {
        // ⚠️ Le garde-fou du code est `deck.count >= 17` alors que la
        // distribution en consomme 18 (1+9+1+3+1+3). Avec exactement 17
        // cartes le code passerait le garde et planterait sur un
        // `removeFirst()` à vide. Ce cas n'est pas atteignable via
        // `buildInitialGameState` (dealHands réserve 18 cartes), mais le
        // garde reste faux d'une unité — signalé, pas corrigé ici (T30 ne
        // touche pas la logique de jeu).
        var deck = Array(Self.ordered.prefix(18))
        let deal = OnlineDealer.dealCommunity(deck: &deck)
        let d = try #require(deal)
        #expect(d.remainingPool.isEmpty)
        #expect(d.rivers.count == 3)
    }

    @Test("dealCommunity : moins de 17 cartes → nil")
    func dealCommunityRefusesShortDeck() {
        var deck = Array(Self.ordered.prefix(16))
        let deal = OnlineDealer.dealCommunity(deck: &deck)
        #expect(deal == nil)
    }

    // MARK: - Tailles de pool (tableau de RULES.md)

    @Test("52 − mains − 18 = pool de tie-break")
    func poolSizes() throws {
        // (joueurs actifs, cartes en main au total, pool restant) — RULES.md.
        let cases = [(4, 24, 10), (5, 30, 4), (7, 28, 6), (8, 32, 2)]
        for (activeCount, expectedHandCards, expectedPool) in cases {
            let target = OnlineDealer.cardsPerPlayer(activeCount: activeCount)
            #expect(target * activeCount == expectedHandCards)

            var deck = Deck.shuffled()
            let seats = Array(0..<activeCount)
            let dealt = OnlineDealer.dealHands(deck: &deck, orderedSeats: seats, target: target)
            let hands = try #require(dealt)
            let handCards = hands.values.reduce(0) { $0 + $1.count }
            #expect(handCards == expectedHandCards)

            let deal = OnlineDealer.dealCommunity(deck: &deck)
            let community = try #require(deal)
            #expect(community.remainingPool.count == expectedPool,
                    "52 − \(expectedHandCards) − 18 doit valoir \(expectedPool)")
        }
    }

    // MARK: - buildInitialGameState

    @Test("buildInitialGameState : sièges, mains, boards vides, scores à zéro")
    func buildInitialGameStateBasics() throws {
        let ps = Self.participants(4)
        let gs = try #require(OnlineGameService.buildInitialGameState(
            mancheNumber: 1, participants: ps, dealerSeat: 0, linePrice: 2.5
        ))

        #expect(gs.mancheNumber == 1)
        #expect(gs.linePrice == 2.5)
        #expect(gs.phase == .dealing)
        #expect(gs.currentBoard == 0)
        #expect(gs.rebidRound == 0)
        #expect(gs.dealerSeat == 0)

        // Les seats sont l'index du participant, dans l'ordre.
        #expect(gs.players.map(\.seat) == [0, 1, 2, 3])
        #expect(gs.players.map(\.userId) == ps.map(\.userId))
        #expect(gs.players.allSatisfy { $0.inManche })
        #expect(gs.players.allSatisfy { $0.connected })
        #expect(gs.players.allSatisfy { $0.forfeitFromBoard == nil })

        // 4 joueurs → 6 cartes chacun, toutes distinctes.
        #expect(gs.hands.count == 4)
        #expect(gs.hands.values.allSatisfy { $0.count == 6 })
        let allHandCards = gs.hands.values.flatMap { $0 }
        #expect(Set(allHandCards).count == 24, "aucune carte distribuée deux fois")

        // Rien n'est encore révélé : les boards sont vides, tout est en attente.
        #expect(gs.communityCards == [[], [], []])
        #expect(gs.pendingFlop.count == 3)
        #expect(gs.pendingFlop.allSatisfy { $0.count == 3 })
        #expect(gs.pendingTurns.count == 3)
        #expect(gs.pendingRivers.count == 3)
        #expect(gs.burns.count == 3)
        #expect(gs.burnsRevealed == 0)
        #expect(gs.submissions.isEmpty)
        #expect(gs.boardResults.count == 3)
        #expect(gs.boardResults.allSatisfy { $0 == nil })
        #expect(gs.tiebreakBoards.isEmpty)
        #expect(gs.excludedThisBoard.isEmpty)
        #expect(gs.fullBoardWinnerSeat == nil)

        // initialScores : une entrée par siège, toutes à zéro à la manche 1.
        #expect(gs.initialScores.count == 4)
        #expect(gs.initialScores.values.allSatisfy { $0 == 0 })

        // Aucune carte n'est servie deux fois entre mains, brûles et boards.
        let community = gs.pendingFlop.flatMap { $0 } + gs.pendingTurns + gs.pendingRivers
        let served = allHandCards + gs.burns + community
        #expect(served.count == 24 + 18)
        #expect(Set(served).count == served.count, "le deck n'a servi aucune carte en double")
    }

    @Test("buildInitialGameState : les spectateurs n'ont pas de cartes")
    func buildInitialGameStateSpectators() throws {
        let ps = Self.participants(5)
        let gs = try #require(OnlineGameService.buildInitialGameState(
            mancheNumber: 3, participants: ps, dealerSeat: 2,
            linePrice: 1, spectatorSeats: [4]
        ))

        #expect(gs.players.count == 5, "le spectateur reste dans la liste des joueurs")
        let spectator = try #require(gs.players.first { $0.seat == 4 })
        #expect(!spectator.inManche)
        #expect(spectator.wantsToSpectate)
        #expect(gs.hands[4] == nil, "un spectateur ne reçoit AUCUNE carte")

        // 4 actifs → 6 cartes chacun.
        #expect(gs.hands.count == 4)
        #expect(gs.hands.values.allSatisfy { $0.count == 6 })
        #expect(gs.initialScores.count == 5, "les scores couvrent aussi les spectateurs")
    }

    @Test("buildInitialGameState : 9 joueurs actifs → nil")
    func buildInitialGameStateRefusesNine() {
        let gs = OnlineGameService.buildInitialGameState(
            mancheNumber: 1, participants: Self.participants(9),
            dealerSeat: 0, linePrice: 2.5
        )
        #expect(gs == nil, "au-delà de 8 joueurs actifs, la distribution est impossible")
    }

    @Test("buildInitialGameState : 9 participants dont 1 spectateur → distribution possible")
    func buildInitialGameStateNineWithSpectator() throws {
        let gs = try #require(OnlineGameService.buildInitialGameState(
            mancheNumber: 1, participants: Self.participants(9),
            dealerSeat: 0, linePrice: 2.5, spectatorSeats: [8]
        ))
        #expect(gs.hands.count == 8)
        #expect(gs.hands.values.allSatisfy { $0.count == 4 }, "8 actifs → 4 cartes chacun")
    }

    // MARK: - Force des mains (scoring : HandEvaluator)

    @Test("HandEvaluator : paire, carré, quinte flush, royale")
    func handCategories() throws {
        let board = [Self.card("9c"), Self.card("Jd"), Self.card("Qh"),
                     Self.card("5s"), Self.card("3c")]

        // Paire d'As (une carte de la main + une du board… ici deux du board
        // ne suffisent pas, on prend un As dans la main).
        let pair = try #require(HandEvaluator.evaluateBest(
            [Self.card("Ac"), Self.card("Ad")] + board
        ))
        #expect(pair.category == .pair)

        // Carré d'As : 2 As en main + 2 As au board.
        let quadBoard = [Self.card("Ah"), Self.card("As"), Self.card("9c"),
                         Self.card("Jd"), Self.card("Qh")]
        let quads = try #require(HandEvaluator.evaluateBest(
            [Self.card("Ac"), Self.card("Ad")] + quadBoard
        ))
        #expect(quads.category == .quads)
        #expect(quads.category.multi == 8, "carré = ×8 (RULES.md)")

        // Quinte flush 5♥-9♥.
        let sflushBoard = [Self.card("7h"), Self.card("8h"), Self.card("9h"),
                           Self.card("2c"), Self.card("3d")]
        let sflush = try #require(HandEvaluator.evaluateBest(
            [Self.card("5h"), Self.card("6h")] + sflushBoard
        ))
        #expect(sflush.category == .sflush)
        #expect(sflush.category.multi == 16)

        // Royale.
        let royalBoard = [Self.card("Qh"), Self.card("Kh"), Self.card("Ah"),
                          Self.card("2c"), Self.card("3d")]
        let royal = try #require(HandEvaluator.evaluateBest(
            [Self.card("Th"), Self.card("Jh")] + royalBoard
        ))
        #expect(royal.category == .royal)
        #expect(royal.category.multi == 20)
    }

    @Test("HandEvaluator : la force départage à catégorie égale")
    func handComparison() {
        let quadAces = HandEvaluator.evaluate5([
            Self.card("Ac"), Self.card("Ad"), Self.card("Ah"), Self.card("As"), Self.card("2c")
        ])
        let quadKings = HandEvaluator.evaluate5([
            Self.card("Kc"), Self.card("Kd"), Self.card("Kh"), Self.card("Ks"), Self.card("Ac")
        ])
        #expect(HandEvaluator.compare(quadAces, quadKings) > 0,
                "carré d'As bat carré de Rois")

        let kingsAceKicker = quadKings
        let kingsQueenKicker = HandEvaluator.evaluate5([
            Self.card("Kc"), Self.card("Kd"), Self.card("Kh"), Self.card("Ks"), Self.card("Qc")
        ])
        #expect(HandEvaluator.compare(kingsAceKicker, kingsQueenKicker) > 0,
                "à carré égal, le kicker tranche")
        #expect(HandEvaluator.compare(quadAces, quadAces) == 0)
    }

    @Test("validateAnnounce : une annonce au-dessus de sa main est un bluff")
    func validateAnnounceRejectsBluff() {
        let board = [Self.card("9s"), Self.card("Jh"), Self.card("Qd"),
                     Self.card("3c"), Self.card("4h")]
        let hole = [Self.card("2c"), Self.card("7d")]   // rien du tout

        #expect(HandEvaluator.validateAnnounce(.highcard, hole: hole, board: board),
                "Hauteur est toujours réalisable")
        #expect(!HandEvaluator.validateAnnounce(.pair, hole: hole, board: board),
                "annoncer Paire sans paire = bluff")
        #expect(!HandEvaluator.validateAnnounce(.quads, hole: hole, board: board))

        // Annoncer MOINS que ce qu'on a reste valide (RULES.md : on annonce ce
        // qu'on pense pouvoir réaliser, pas exactement sa main).
        let strongHole = [Self.card("Jc"), Self.card("Jd")]
        #expect(HandEvaluator.validateAnnounce(.trips, hole: strongHole, board: board))
        #expect(HandEvaluator.validateAnnounce(.pair, hole: strongHole, board: board))
        #expect(!HandEvaluator.validateAnnounce(.straight, hole: strongHole, board: board))
    }

    @Test("autoPickCards : Hauteur se joue sans sélection manuelle")
    func autoPickHighcard() throws {
        let board = [Self.card("9s"), Self.card("Jh"), Self.card("Qd"),
                     Self.card("3c"), Self.card("4h")]
        let hole = [Self.card("2c"), Self.card("7d"), Self.card("Kh"), Self.card("8s")]
        let picked = try #require(
            HandEvaluator.autoPickCards(announced: .highcard, hole: hole, board: board)
        )
        #expect(picked.count == 2)
        #expect(picked.allSatisfy { hole.contains($0) })
        #expect(HandEvaluator.validateAnnounce(.highcard, hole: picked, board: board))
    }

    // MARK: - Encodage de OnlineRoom (ce qui part dans online_rooms.state)

    /// Une room complète : c'est exactement la forme que `room_publish` reçoit.
    private struct FixtureError: Error { let message: String }

    private static func sampleRoom() throws -> OnlineRoom {
        let ps = participants(3)
        guard var gs = OnlineGameService.buildInitialGameState(
            mancheNumber: 2, participants: ps, dealerSeat: 1, linePrice: 0.5
        ) else { throw FixtureError(message: "distribution impossible pour la fixture") }
        gs.submissions[0] = BoardSubmission(categoryId: "pair",
                                            cards: [card("Ac"), card("Ad")])
        gs.submissions[1] = BoardSubmission(categoryId: "skip", cards: [])
        gs.communityCards[0] = [card("2c"), card("3d"), card("4h")]

        var room = OnlineRoom(code: "AB2C",
                              hostUserId: ps[0].userId,
                              participants: ps,
                              status: .playing,
                              linePrice: 0.5,
                              flashMode: true,
                              announceTimerSeconds: 30,
                              gameState: gs)
        room.pastManches = [
            MancheArchive(mancheNumber: 1, dealerSeat: 0,
                          perPlayerDelta: [0: 1.0, 1: -0.5, 2: -0.5],
                          boardsWon: [0: [0, 1], 1: [2], 2: []],
                          fullBoardWinnerSeat: nil, numActive: 3,
                          boardMultis: [0: 1, 1: 8, 2: 1])
        ]
        return room
    }

    @Test("OnlineRoom : aller-retour JSON sans perte")
    func roomRoundTrip() throws {
        let room = try Self.sampleRoom()
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(OnlineRoom.self, from: data)
        #expect(decoded == room, "l'état publié doit revenir identique de Postgres")
    }

    @Test("OnlineRoom : `hands` est un objet à clés string, pas un tableau")
    func handsEncodeAsStringKeyedObject() throws {
        let room = try Self.sampleRoom()
        let data = try JSONEncoder().encode(room)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let gameState = try #require(json["gameState"] as? [String: Any])

        let hands = try #require(gameState["hands"] as? [String: Any],
                                 "hands DOIT être un objet jsonb (clé = seat en string)")
        #expect(Set(hands.keys) == ["0", "1", "2"])
        let seatZero = try #require(hands["0"] as? [String])
        #expect(seatZero.count == 6)
        #expect(seatZero.allSatisfy { Card($0) != nil },
                "les cartes sont encodées en \"RS\" (\"TS\", \"AC\"…)")

        // Même forme pour les dictionnaires indexés par seat de l'archive.
        let past = try #require(json["pastManches"] as? [[String: Any]])
        let delta = try #require(past[0]["perPlayerDelta"] as? [String: Any])
        #expect(Set(delta.keys) == ["0", "1", "2"])

        // Et pour les soumissions.
        let submissions = try #require(gameState["submissions"] as? [String: Any])
        #expect(Set(submissions.keys) == ["0", "1"])
    }

    @Test("OnlineRoom : un état ancien sans `pastManches` décode en []")
    func decodesLegacyStateWithoutPastManches() throws {
        let host = UUID()
        let json = """
        {
          "code": "QATE",
          "hostUserId": "\(host.uuidString)",
          "participants": [
            {"userId": "\(host.uuidString)", "displayName": "Hôte", "isHost": true, "isOnline": true}
          ],
          "status": "lobby"
        }
        """
        let room = try JSONDecoder().decode(OnlineRoom.self, from: Data(json.utf8))

        #expect(room.code == "QATE")
        #expect(room.hostUserId == host)
        #expect(room.pastManches.isEmpty, "absent → [], jamais une erreur de décodage")
        #expect(room.gameState == nil)
        #expect(room.cloudGameId == nil)
        #expect(room.linePrice == 2.5, "valeur par défaut")
        #expect(room.flashMode == false)
        #expect(room.announceTimerSeconds == 0)
        #expect(room.participants.first?.isOnline == true)
    }

    @Test("RoomCode : 4 caractères sans 0/O/1/I")
    func roomCodeShape() {
        let ambiguous: Set<Character> = ["0", "O", "1", "I"]
        for _ in 0..<200 {
            let code = RoomCode.random()
            #expect(code.count == 4)
            #expect(code.allSatisfy { $0.isUppercase || $0.isNumber })
            #expect(code.allSatisfy { !ambiguous.contains($0) },
                    "les caractères ambigus sont bannis du code de salon")
        }
    }
}
