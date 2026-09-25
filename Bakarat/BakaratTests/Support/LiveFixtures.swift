//
//  LiveFixtures.swift
//  BakaratTests/Support
//
//  Outillage des tests protocole « live » (T31) : plusieurs identités QA dans
//  UN seul process, chacune avec son `SupabaseClient` (session en mémoire, le
//  trousseau du simulateur n'est jamais touché), branchées sur le vrai
//  Supabase.
//
//  Rien ici n'est un test : ce sont les briques (connexion, service, attente
//  par polling, annonce valide, ménage) que `OnlineProtocolLiveTests` assemble.
//
//  Le mot de passe des comptes `bakaratqa.*@bakarat.test` n'est JAMAIS en dur :
//  il arrive par l'environnement (`BAKARAT_QA_PASSWORD`), que le runner
//  transmet en `TEST_RUNNER_BAKARAT_QA_PASSWORD` (le préfixe est retiré par
//  xcodebuild à l'arrivée dans le process de test).
//

import Foundation
import Supabase
@testable import Bakarat

// MARK: - Stockage d'auth en mémoire

/// Une session par identité, jamais le trousseau partagé. Copie volontaire de
/// `InMemoryAuthStorage` (app, DEBUG only) pour que les tests ne dépendent pas
/// d'un symbole conditionnel.
final class LiveAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}

// MARK: - Fixtures

@MainActor
enum LiveFixtures {

    enum LiveError: Error, CustomStringConvertible {
        case missingPassword
        case signInFailed(String, String)
        case noRoom(String)

        var description: String {
            switch self {
            case .missingPassword:
                return "BAKARAT_QA_PASSWORD absent de l'environnement du process de test"
            case .signInFailed(let email, let reason):
                return "connexion \(email) impossible : \(reason)"
            case .noRoom(let what):
                return "pas de salon après \(what)"
            }
        }
    }

    // MARK: Environnement

    /// Les tests live ne tournent que si le runner le demande explicitement.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BAKARAT_LIVE_TESTS"] == "1"
    }

    /// Mot de passe commun des comptes QA. Jamais écrit dans le dépôt.
    static var password: String? {
        let raw = ProcessInfo.processInfo.environment["BAKARAT_QA_PASSWORD"] ?? ""
        return raw.isEmpty ? nil : raw
    }

    static let hostEmail  = "bakaratqa.host@bakarat.test"
    static let guest1Email = "bakaratqa.g1@bakarat.test"
    static let guest2Email = "bakaratqa.g2@bakarat.test"
    static let guest3Email = "bakaratqa.g3@bakarat.test"

    // MARK: Identités

    /// Un compte QA connecté, avec son propre client.
    struct Identity {
        let email: String
        let displayName: String
        let client: SupabaseClient
        let userId: UUID
    }

    /// Ouvre une session pour `email` sur un client neuf.
    static func signIn(_ email: String, displayName: String) async throws -> Identity {
        guard let password else { throw LiveError.missingPassword }
        let options = SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(storage: LiveAuthStorage())
        )
        let client = SupabaseClient(supabaseURL: SupabaseConfig.url,
                                    supabaseKey: SupabaseConfig.anonKey,
                                    options: options)
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw LiveError.signInFailed(email, error.localizedDescription)
        }
        let session = try await client.auth.session
        return Identity(email: email, displayName: displayName,
                        client: client, userId: session.user.id)
    }

    /// Service de jeu posé sur le client de cette identité (transport dédié).
    static func makeService(_ identity: Identity,
                            chaos: ChaosProfile? = nil) -> OnlineGameService {
        OnlineGameService(client: identity.client, chaos: chaos)
    }

    // MARK: Attentes

    /// Attente par polling — la seule forme d'attente fiable sur un protocole
    /// qui converge (ping Realtime + poll heartbeat). Retourne `false` si la
    /// condition n'est jamais vraie dans le budget.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 20,
                          step: TimeInterval = 0.25,
                          _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        return condition()
    }

    /// Comme `waitUntil`, mais rend le temps écoulé (pour les assertions
    /// d'expérience « la phase suivante arrive en moins de N secondes »).
    static func measureWait(timeout: TimeInterval = 20,
                            step: TimeInterval = 0.25,
                            _ condition: @MainActor () -> Bool) async -> (ok: Bool, seconds: TimeInterval) {
        let started = Date()
        let ok = await waitUntil(timeout: timeout, step: step, condition)
        return (ok, Date().timeIntervalSince(started))
    }

    static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Lecture d'état

    static func gameState(_ service: OnlineGameService) -> OnlineGameState? {
        service.room?.gameState
    }

    static func seat(of userId: UUID, in service: OnlineGameService) -> Int? {
        service.room?.gameState?.players.first { $0.userId == userId }?.seat
    }

    /// Le board sur lequel porte l'annonce en cours (board courant, ou les 5
    /// cartes du dernier tie-break).
    static func announceBoard(_ gs: OnlineGameState) -> [Card] {
        if gs.phase == .tiebreakAnnouncing, let tb = gs.tiebreakBoards.last {
            return tb.cards
        }
        guard gs.communityCards.indices.contains(gs.currentBoard) else { return [] }
        return gs.communityCards[gs.currentBoard]
    }

    /// Vrai si ce siège a déjà soumis sur la phase d'annonce en cours.
    static func hasSubmitted(_ gs: OnlineGameState, seat: Int) -> Bool {
        if gs.phase == .tiebreakAnnouncing {
            return gs.tiebreakBoards.last?.submissions[seat] != nil
        }
        return gs.submissions[seat] != nil
    }

    // MARK: Annonce valide

    /// La meilleure annonce VALIDE réalisable avec 2 cartes de la main, sinon
    /// « skip ». `locked` impose la catégorie (tie-break, cf. RULES.md).
    /// Même logique que les bots in-app, mais réécrite ici pour ne pas
    /// dépendre d'un type imbriqué compilé sous `#if DEBUG`.
    static func bestSubmission(hand: [Card], board: [Card],
                               locked: HandCategory?) -> BoardSubmission {
        let skip = BoardSubmission(categoryId: "skip", cards: [])
        guard hand.count >= 2, board.count >= 3 else { return skip }

        if let locked {
            guard let cards = HandEvaluator.autoPickCards(announced: locked, hole: hand, board: board),
                  HandEvaluator.validateAnnounce(locked, hole: cards, board: board) else { return skip }
            return BoardSubmission(categoryId: locked.id, cards: cards)
        }

        guard let best = HandEvaluator.evaluateBest(hand + board) else { return skip }
        let candidates = HandCategory.allCases
            .filter { $0.rawValue <= best.category.rawValue }
            .sorted { $0.rawValue > $1.rawValue }
        for cat in candidates {
            if let cards = HandEvaluator.autoPickCards(announced: cat, hole: hand, board: board),
               HandEvaluator.validateAnnounce(cat, hole: cards, board: board) {
                return BoardSubmission(categoryId: cat.id, cards: cards)
            }
        }
        return skip
    }

    /// Catégorie verrouillée d'un tie-break (celle qui a fait le split).
    static func lockedCategory(_ gs: OnlineGameState) -> HandCategory? {
        guard gs.phase == .tiebreakAnnouncing,
              let tb = gs.tiebreakBoards.last,
              let parent = gs.boardResults[tb.parentBoardIdx],
              let catId = parent.winningCategoryId else { return nil }
        return HandCategory.from(id: catId)
    }

    /// Soumet une annonce valide pour ce service, si c'est le moment et que ce
    /// siège n'a pas déjà soumis. Retourne vrai si une annonce est partie.
    @discardableResult
    static func submitIfNeeded(_ service: OnlineGameService, userId: UUID) async -> Bool {
        guard let gs = service.room?.gameState else { return false }
        guard gs.phase == .announcing || gs.phase == .tiebreakAnnouncing else { return false }
        guard let seat = seat(of: userId, in: service) else { return false }
        guard let me = gs.players.first(where: { $0.seat == seat }), me.inManche else { return false }
        guard !hasSubmitted(gs, seat: seat) else { return false }
        guard !gs.excludedThisBoard.contains(seat) else { return false }
        if let ff = me.forfeitFromBoard, ff <= gs.currentBoard { return false }
        if gs.phase == .tiebreakAnnouncing,
           gs.tiebreakBoards.last?.eligibleSeats.contains(seat) != true { return false }

        let submission = bestSubmission(hand: gs.hands[seat] ?? [],
                                        board: announceBoard(gs),
                                        locked: lockedCategory(gs))
        await service.submitAnnounce(submission: submission, mySeat: seat)
        return true
    }

    /// Joue automatiquement ce service (annonce dès que c'est à lui) jusqu'à
    /// annulation. À cancel dans le test.
    static func autoplay(_ service: OnlineGameService, userId: UUID) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await submitIfNeeded(service, userId: userId)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    // MARK: Ménage

    /// Quitte proprement, best effort — un test qui échoue ne doit jamais
    /// laisser un salon vivant derrière lui.
    static func cleanup(_ services: [OnlineGameService],
                        tasks: [Task<Void, Never>] = []) async {
        for t in tasks { t.cancel() }
        for s in services {
            await s.leave()
        }
    }
}
