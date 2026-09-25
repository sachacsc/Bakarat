//
//  QABotRunner.swift
//  Bakarat
//
//  Bots in-app (docs/PLAN_ONLINE_V2.md — T33). Permet de jouer un tour complet
//  sur UN seul simulateur : `-qaBots N` lance N `OnlineGameService`, chacun sur
//  son PROPRE `SupabaseClient` (stockage d'auth en mémoire, pour ne jamais
//  écraser la session Keychain de l'app), connecté à un compte QA
//  `bakaratqa.g1..g3@bakarat.test`.
//
//  Chaque bot rejoint `-qaRoomCode`, puis, dès que son siège est éligible et
//  n'a pas encore soumis, annonce après 1–3 s une catégorie VALIDE calculée
//  avec `HandEvaluator` (sinon « skip »).
//
//  DEBUG uniquement.
//

import Foundation
import Supabase

#if DEBUG

/// Stockage d'auth en mémoire : chaque bot a sa propre session, jamais le
/// trousseau de l'app.
final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
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

@MainActor
final class QABotRunner {

    static let shared = QABotRunner()

    private var bots: [Bot] = []
    private var isRunning = false

    private init() {}

    /// Lance `QALaunchOptions.botCount` bots sur le salon `code`.
    func startIfNeeded(code: String) {
        let count = QALaunchOptions.botCount
        guard count > 0, !isRunning else { return }
        guard let password = QALaunchOptions.qaPassword, !password.isEmpty else {
            print(("[QABots] -qaBots demandé mais aucun mot de passe QA (-qaPassword / $BAKARAT_QA_PASSWORD)")); QALog.write(("[QABots] -qaBots demandé mais aucun mot de passe QA (-qaPassword / $BAKARAT_QA_PASSWORD)"))
            return
        }
        isRunning = true
        print(("[QABots] démarrage de \(count) bot(s) sur \(code)")); QALog.write(("[QABots] démarrage de \(count) bot(s) sur \(code)"))
        for index in 1...min(count, 3) {
            let chaos = (index == 1) ? QALaunchOptions.chaosProfile : nil
            let bot = Bot(index: index, code: code, password: password, chaos: chaos)
            bots.append(bot)
            bot.start()
        }
    }

    func stop() {
        for bot in bots { bot.stop() }
        bots.removeAll()
        isRunning = false
    }

    // MARK: - Un bot

    @MainActor
    final class Bot {
        private let index: Int
        private let code: String
        private let password: String
        private let chaos: ChaosProfile?
        private var service: OnlineGameService?
        private var task: Task<Void, Never>?
        /// Date à laquelle chaque phase d'annonce a été vue pour la 1re fois.
        private var seenAt: [String: Date] = [:]

        init(index: Int, code: String, password: String, chaos: ChaosProfile?) {
            self.index = index
            self.code = code
            self.password = password
            self.chaos = chaos
        }

        var email: String { "bakaratqa.g\(index)@bakarat.test" }
        var displayName: String { "Bot \(index)" }

        func start() {
            task = Task { [weak self] in
                guard let self else { return }
                await self.run()
            }
        }

        func stop() {
            task?.cancel()
            task = nil
            let service = self.service
            self.service = nil
            Task { await service?.leave() }
        }

        private func run() async {
            let options = SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(storage: InMemoryAuthStorage())
            )
            let client = SupabaseClient(supabaseURL: SupabaseConfig.url,
                                        supabaseKey: SupabaseConfig.anonKey,
                                        options: options)
            do {
                try await client.auth.signIn(email: email, password: password)
            } catch {
                print(("[QABots] \(email) : login impossible — \(error.localizedDescription)")); QALog.write(("[QABots] \(email) : login impossible — \(error.localizedDescription)"))
                return
            }
            guard let session = try? await client.auth.session else { return }
            let userId = session.user.id

            let service = OnlineGameService(client: client, chaos: chaos)
            self.service = service
            // Petit décalage pour ne pas rejoindre tous en même temps.
            try? await Task.sleep(nanoseconds: UInt64(index) * 400_000_000)
            _ = await service.joinRoom(code: code, myUserId: userId, myDisplayName: displayName)
            print(("[QABots] \(displayName) a rejoint \(code)")); QALog.write(("[QABots] \(displayName) a rejoint \(code)"))

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.tick(service: service, userId: userId)
            }
        }

        private func tick(service: OnlineGameService, userId: UUID) async {
            guard let gs = service.room?.gameState else { return }
            guard let me = gs.players.first(where: { $0.userId == userId }), me.inManche else { return }
            let seat = me.seat

            switch gs.phase {
            case .announcing:
                guard gs.submissions[seat] == nil else { return }
                guard !gs.excludedThisBoard.contains(seat) else { return }
                if let ff = me.forfeitFromBoard, ff <= gs.currentBoard { return }
                let key = "m\(gs.mancheNumber)-b\(gs.currentBoard)-r\(gs.rebidRound)"
                guard waitedEnough(key: key) else { return }
                let board = gs.communityCards.indices.contains(gs.currentBoard)
                    ? gs.communityCards[gs.currentBoard] : []
                let submission = Self.bestSubmission(hand: gs.hands[seat] ?? [],
                                                     board: board,
                                                     locked: nil)
                await service.submitAnnounce(submission: submission, mySeat: seat)

            case .tiebreakAnnouncing:
                guard let tb = gs.tiebreakBoards.last, tb.eligibleSeats.contains(seat) else { return }
                guard tb.submissions[seat] == nil else { return }
                let key = "tb-\(tb.parentBoardIdx)-\(tb.round)"
                guard waitedEnough(key: key) else { return }
                let locked = gs.boardResults[tb.parentBoardIdx]?
                    .winningCategoryId.flatMap { HandCategory.from(id: $0) }
                let submission = Self.bestSubmission(hand: gs.hands[seat] ?? [],
                                                     board: tb.cards,
                                                     locked: locked)
                await service.submitAnnounce(submission: submission, mySeat: seat)

            default:
                return
            }
        }

        /// Vrai une fois écoulé le délai aléatoire de 1 à 3 s pour cette phase.
        private func waitedEnough(key: String) -> Bool {
            if let deadline = seenAt[key] {
                return Date() >= deadline
            }
            // Première observation : on tire une échéance entre 1 et 3 s.
            seenAt[key] = Date().addingTimeInterval(Double.random(in: 1...3))
            return false
        }

        /// Meilleure annonce VALIDE réalisable avec 2 cartes de la main, sinon
        /// « skip ». `locked` impose la catégorie (tie-break).
        static func bestSubmission(hand: [Card], board: [Card], locked: HandCategory?) -> BoardSubmission {
            let skip = BoardSubmission(categoryId: "skip", cards: [])
            guard hand.count >= 2, !board.isEmpty else { return skip }

            if let locked {
                guard let cards = HandEvaluator.autoPickCards(announced: locked, hole: hand, board: board),
                      HandEvaluator.validateAnnounce(locked, hole: cards, board: board) else { return skip }
                return BoardSubmission(categoryId: locked.id, cards: cards)
            }

            guard let best = HandEvaluator.evaluateBest(hand + board) else { return skip }
            // On descend depuis la meilleure catégorie jusqu'à en trouver une
            // réalisable avec seulement 2 cartes de la main.
            var candidates: [HandCategory] = HandCategory.allCases
                .filter { $0.rawValue <= best.category.rawValue }
                .sorted { $0.rawValue > $1.rawValue }
            if candidates.isEmpty { candidates = [.highcard] }
            for cat in candidates {
                if let cards = HandEvaluator.autoPickCards(announced: cat, hole: hand, board: board),
                   HandEvaluator.validateAnnounce(cat, hole: cards, board: board) {
                    return BoardSubmission(categoryId: cat.id, cards: cards)
                }
            }
            return skip
        }
    }
}

#endif
