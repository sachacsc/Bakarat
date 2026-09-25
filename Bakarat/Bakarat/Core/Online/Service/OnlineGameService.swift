//
//  OnlineGameService.swift
//  Bakarat
//
//  Service ObservableObject du mode Online, posé sur `RoomTransport`
//  (docs/PLAN_ONLINE_V2.md — T13).
//
//  Ce qui a changé par rapport à la v1 :
//   • L'état ne vit plus dans la RAM de l'hôte mais dans `online_rooms`
//     (jsonb versionné). Toute écriture passe par un CAS `room_publish`
//     (`expected_version`) : deux écritures concurrentes ne s'écrasent jamais.
//   • Il n'y a plus de broadcast, plus de presence Realtime, plus d'élection
//     d'hôte maison, plus de reprise par UserDefaults. La reprise = `room_get`
//     + `room_claim_host` (bail serveur, un seul gagnant).
//   • Le tempo de l'hôte est une boucle de **pas idempotents** : chaque pas
//     relit l'état après son attente et ne fait rien si la phase (ou le nombre
//     de cartes) n'est plus celle attendue. Un pas rejoué après suspension iOS
//     est donc inoffensif.
//
//  Toute la logique de jeu (scoring, reveal, tie-break, rebid, full board,
//  distribution) est inchangée — seule la façon de lire et d'écrire l'état a
//  bougé.
//

import Combine
import Foundation
import Supabase

@MainActor
final class OnlineGameService: ObservableObject {

    // MARK: - État publié

    @Published private(set) var room: OnlineRoom?
    @Published private(set) var role: OnlineRole?
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?
    /// État de la connexion (bannière UI).
    @Published private(set) var connectionState: RoomTransport.ConnectionState = .offline
    /// Nom de la personne qui anime la partie (bannière « X anime maintenant »).
    @Published private(set) var hostDisplayName: String?
    /// Vrai pendant une resynchronisation (retour au premier plan, réseau revenu).
    @Published private(set) var isReconnecting: Bool = false
    /// Décalage horloge locale → serveur (secondes). `Date() + offset ≈ now()`.
    @Published private(set) var serverTimeOffset: TimeInterval = 0
    /// Code du salon en cours d'ouverture (loader lobby).
    @Published private(set) var pendingChannelCode: String?
    /// Libellé de diagnostic affiché sous le loader / l'erreur.
    @Published private(set) var channelStatusLabel: String?

    enum Phase: Equatable {
        /// Pas encore dans une room (vue entry)
        case idle
        /// En cours d'ouverture du salon (loader)
        case connecting
        /// Connecté, en lobby (avant start)
        case lobby
        /// La partie est lancée
        case playing
        /// On a quitté
        case left
    }

    // MARK: - Dépendances

    let transport: RoomTransport
    private let client: SupabaseClient

    // MARK: - État interne

    private(set) var myUserId: UUID?
    private var myDisplayName: String = "Joueur"
    /// Version de la ligne `online_rooms` correspondant à `room`.
    private(set) var version: Int64 = 0
    /// Membres tels que le serveur les connaît (présence + bail).
    private(set) var members: [RoomMember] = []
    private var serverNow: Date = Date()
    private var hostLeaseUntil: Date = Date(timeIntervalSince1970: 0)
    private var serverHostUserId: UUID?

    private var snapshotTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var hostDriverTask: Task<Void, Never>?
    private var touchActiveTask: Task<Void, Never>?
    private var isClaimingHost = false
    private var lastClaimAttempt: Date = .distantPast
    private var isResolvingBoard = false
    /// Manches déjà persistées (idempotence de `record_manche`).
    private var recordedManches: Set<Int> = []

    /// Intervalle de heartbeat du `touch_game_active` (historique « En cours »).
    private static let touchInterval: TimeInterval = 30
    /// Grâce de présence : au-delà, le joueur est marqué déconnecté.
    private static let presenceGraceSeconds: TimeInterval = 20
    /// Au-delà, et seulement s'il bloque le reveal, il est mis en forfait.
    private static let forfeitSilenceSeconds: TimeInterval = 60
    /// Marge avant de considérer le bail d'hôte comme expiré.
    private static let leaseSlackSeconds: TimeInterval = 5

    // MARK: - Init

    /// `client` nil = client partagé de l'app. Injectable pour les bots QA.
    init(client: SupabaseClient? = nil,
         chaos: ChaosProfile? = nil) {
        let resolved = client ?? SupabaseClientProvider.shared
        self.client = resolved
        self.transport = RoomTransport(client: resolved, chaos: chaos)
        self.transport.onHeartbeat = { [weak self] hb in
            guard let self else { return }
            Task { await self.handleHeartbeat(hb) }
        }
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        #if DEBUG
        let tag: String
        switch role {
        case .host:  tag = "HOST "
        case .guest: tag = "GUEST"
        case .none:  tag = "?    "
        }
        print("[Online \(tag)] \(msg)")
        QALog.write("[Online \(tag)] \(msg)")
        #endif
    }

    // MARK: - Reprise (code mémorisé)

    private static let lastRoomCodeKey = "online_last_room_code"
    private static let lastRoomAtKey = "online_last_room_at"
    /// Au-delà de 2 h, on ne propose plus de reprendre le salon.
    private static let lastRoomMaxAge: TimeInterval = 2 * 60 * 60

    static func rememberRoom(code: String) {
        UserDefaults.standard.set(code, forKey: lastRoomCodeKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRoomAtKey)
    }

    static func forgetRoom() {
        UserDefaults.standard.removeObject(forKey: lastRoomCodeKey)
        UserDefaults.standard.removeObject(forKey: lastRoomAtKey)
    }

    /// Code du dernier salon rejoint, s'il date de moins de 2 h.
    static func rememberedRoomCode() -> String? {
        guard let code = UserDefaults.standard.string(forKey: lastRoomCodeKey) else { return nil }
        let at = UserDefaults.standard.double(forKey: lastRoomAtKey)
        guard at > 0, Date().timeIntervalSince1970 - at < lastRoomMaxAge else {
            forgetRoom()
            return nil
        }
        return code
    }

    // MARK: - API publique : création / join / départ

    /// Crée un salon et devient hôte. Le code est généré côté client (ou forcé
    /// par `-qaRoomCode` en DEBUG) : en cas de collision `CODE_TAKEN`, on
    /// réessaie avec un autre code.
    func createRoom(myUserId: UUID, myDisplayName: String) async {
        guard await ensureSession() else { return }
        self.myUserId = myUserId
        self.myDisplayName = myDisplayName
        self.lastError = nil
        self.phase = .connecting
        self.role = .host

        var forcedCode = QALaunchOptions.forcedRoomCode
        var attempt = 0
        while attempt < 5 {
            attempt += 1
            let code = forcedCode ?? RoomCode.random()
            forcedCode = nil
            let seed = OnlineRoom(code: code,
                                  hostUserId: myUserId,
                                  participants: [OnlineParticipant(userId: myUserId,
                                                                   displayName: myDisplayName,
                                                                   isHost: true)],
                                  status: .lobby)
            pendingChannelCode = code
            do {
                let env = try await transport.create(code: code,
                                                     displayName: myDisplayName,
                                                     state: seed)
                applyEnvelope(env)
                await finishOpening(code: code)
                await ensureGameInCloud()
                startTouchActiveLoop()
                startHostDriver()
                return
            } catch RoomError.codeTaken {
                log("createRoom: code \(code) déjà pris, nouvel essai")
                continue
            } catch {
                await failConnection(RoomError.from(error).userMessage)
                return
            }
        }
        await failConnection("Impossible de créer un salon (codes déjà pris). Réessayez.")
    }

    /// Rejoint un salon existant. Retourne false si le code a un format invalide.
    @discardableResult
    func joinRoom(code rawCode: String, myUserId: UUID, myDisplayName: String) async -> Bool {
        let code = rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 4 else {
            lastError = "Code invalide (4 caractères attendus)."
            return false
        }
        guard await ensureSession() else { return true }
        self.myUserId = myUserId
        self.myDisplayName = myDisplayName
        self.lastError = nil
        self.phase = .connecting
        self.pendingChannelCode = code
        self.role = .guest

        do {
            let env = try await transport.join(code: code, displayName: myDisplayName)
            applyEnvelope(env)
            await finishOpening(code: code)
            startTouchActiveLoop()
            if role == .host { startHostDriver() }
            return true
        } catch {
            await failConnection(RoomError.from(error).userMessage)
            return true
        }
    }

    /// Ouvre le transport (channel + poll) et branche les flux.
    private func finishOpening(code: String) async {
        Self.rememberRoom(code: code)
        do {
            try await transport.open(code: code)
        } catch {
            log("open transport: \(error.localizedDescription)")
        }
        observeTransport()
        phase = (room?.status == .playing) ? .playing : .lobby
        pendingChannelCode = nil
    }

    private func observeTransport() {
        snapshotTask?.cancel()
        let stream = transport.snapshots
        snapshotTask = Task { [weak self] in
            for await env in stream {
                guard let self, !Task.isCancelled else { return }
                self.applyEnvelope(env)
                await self.reactToSnapshot()
            }
        }
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            // `connectionState` est @Published sur le transport : on le recopie
            // dans le service pour que les vues n'observent qu'un objet.
            for await state in self.transport.$connectionState.values {
                guard !Task.isCancelled else { return }
                self.connectionState = state
                self.channelStatusLabel = state.rawValue
            }
        }
    }

    /// Vérifie qu'on a bien une session Supabase. Plus de `signInAnonymously`
    /// en fallback (T03a) : on remonte une erreur claire.
    private func ensureSession() async -> Bool {
        do {
            _ = try await client.auth.session
            return true
        } catch {
            lastError = RoomError.noSession.userMessage
            phase = .idle
            role = nil
            room = nil
            return false
        }
    }

    private func failConnection(_ message: String) async {
        lastError = message
        phase = .idle
        pendingChannelCode = nil
        role = nil
        room = nil
        await transport.close()
    }

    /// Quitte le salon — geste EXPLICITE uniquement (T03b).
    func leave() async {
        let code = room?.code
        log("leave code=\(code ?? "?")")
        hostDriverTask?.cancel(); hostDriverTask = nil
        touchActiveTask?.cancel(); touchActiveTask = nil
        snapshotTask?.cancel(); snapshotTask = nil
        connectionTask?.cancel(); connectionTask = nil
        if let code {
            try? await transport.leaveRoom(code: code)
        }
        await transport.close()
        Self.forgetRoom()
        room = nil
        role = nil
        members = []
        version = 0
        recordedManches = []
        hostDisplayName = nil
        pendingChannelCode = nil
        phase = .left
    }

    // MARK: - Cycle de vie iOS (T20)

    /// Retour au premier plan : resync + reprise du tempo (idempotente).
    func handleForeground() async {
        guard room != nil else { return }
        isReconnecting = true
        await transport.resync()
        isReconnecting = false
        if role == .host { resumeFromCurrentPhase() }
    }

    /// Passage en arrière-plan : on coupe le tempo (il repartira au retour).
    func handleBackground() {
        hostDriverTask?.cancel()
        hostDriverTask = nil
    }

    // MARK: - Application d'une enveloppe

    private func applyEnvelope(_ env: RoomEnvelope) {
        guard env.version > version else { return }
        version = env.version
        room = env.state
        members = env.members
        serverNow = env.serverNow
        hostLeaseUntil = env.hostLeaseUntil
        serverHostUserId = env.hostUserId
        serverTimeOffset = env.serverNow.timeIntervalSinceNow
        hostDisplayName = env.state.participants
            .first(where: { $0.userId == env.hostUserId })?.displayName

        if env.state.status == .playing, phase != .left { phase = .playing }
        else if phase == .connecting { phase = .lobby }

        applyRoleFromServer(hostUserId: env.hostUserId)
    }

    private func applyRoleFromServer(hostUserId: UUID) {
        guard let me = myUserId else { return }
        let shouldBeHost = (hostUserId == me)
        if shouldBeHost, role != .host {
            log("je deviens hôte (bail serveur)")
            role = .host
            startHostDriver()
            startTouchActiveLoop()
        } else if !shouldBeHost, role == .host {
            log("un autre client anime la partie — je repasse guest")
            role = .guest
            hostDriverTask?.cancel()
            hostDriverTask = nil
        }
    }

    /// Réaction à chaque snapshot : présence + reveal si tout le monde a soumis
    /// (hôte), relève du bail (guest).
    private func reactToSnapshot() async {
        if role == .host {
            await syncPresenceFlags()
            await checkAllSubmitted()
        } else {
            await evaluateHostLease()
        }
    }

    private func handleHeartbeat(_ hb: RoomHeartbeat) async {
        members = hb.members
        serverNow = hb.serverNow
        hostLeaseUntil = hb.hostLeaseUntil
        serverHostUserId = hb.hostUserId
        serverTimeOffset = hb.serverNow.timeIntervalSinceNow
        applyRoleFromServer(hostUserId: hb.hostUserId)
        if role == .host {
            await syncPresenceFlags()
        } else {
            await evaluateHostLease()
        }
    }

    // MARK: - Bail d'hôte et relève (T22)

    /// Guest : si le bail est expiré depuis > 5 s et que je suis le plus petit
    /// seat connecté, je réclame l'animation.
    private func evaluateHostLease() async {
        guard role == .guest, let code = room?.code, let me = myUserId else { return }
        guard !isClaimingHost else { return }
        guard hostLeaseUntil < serverNow.addingTimeInterval(-Self.leaseSlackSeconds) else { return }
        guard Date().timeIntervalSince(lastClaimAttempt) > 3 else { return }
        guard lowestConnectedCandidate() == me else { return }

        isClaimingHost = true
        lastClaimAttempt = Date()
        defer { isClaimingHost = false }
        do {
            let env = try await transport.claimHost(code: code)
            applyEnvelope(env)
            if env.hostUserId == me {
                log("bail repris — j'anime la partie")
                role = .host
                resumeFromCurrentPhase()
                startTouchActiveLoop()
            }
        } catch RoomError.leaseActive {
            // Quelqu'un d'autre a gagné la course : rien à faire.
        } catch {
            log("room_claim_host: \(error.localizedDescription)")
        }
    }

    /// Plus petit seat parmi les membres connectés et non partis.
    private func lowestConnectedCandidate() -> UUID? {
        guard let room else { return nil }
        let connectedIds = Set(connectedMemberIds())
        let seatByUser: [UUID: Int]
        if let gs = room.gameState {
            seatByUser = Dictionary(uniqueKeysWithValues: gs.players.map { ($0.userId, $0.seat) })
        } else {
            seatByUser = Dictionary(uniqueKeysWithValues:
                room.participants.enumerated().map { ($0.element.userId, $0.offset) })
        }
        let candidates = seatByUser
            .filter { connectedIds.contains($0.key) }
            .sorted { $0.value < $1.value }
        return candidates.first?.key
    }

    private func connectedMemberIds() -> [UUID] {
        members.compactMap { m in
            guard m.leftAt == nil else { return nil }
            guard serverNow.timeIntervalSince(m.lastSeenAt) <= Self.presenceGraceSeconds else { return nil }
            return m.userId
        }
    }

    // MARK: - Présence avec grâce (T23)

    /// Hôte : reporte `connected` dans `gs.players` (seulement quand ça change)
    /// et ne pose un forfait qu'après 60 s de silence pendant une phase
    /// d'annonce où ce siège bloque le reveal.
    private func syncPresenceFlags() async {
        guard role == .host, let gs = room?.gameState else { return }
        let now = serverNow
        var connectedByUser: [UUID: Bool] = [:]
        var silentByUser: [UUID: Bool] = [:]
        for m in members {
            let silence = now.timeIntervalSince(m.lastSeenAt)
            connectedByUser[m.userId] = (m.leftAt == nil) && silence <= Self.presenceGraceSeconds
            silentByUser[m.userId] = (m.leftAt != nil) || silence > Self.forfeitSilenceSeconds
        }
        guard !connectedByUser.isEmpty else { return }

        let isAnnouncePhase = (gs.phase == .announcing || gs.phase == .tiebreakAnnouncing)
        let blocking = blockingSeats(in: gs)

        await mutateGameState { state in
            for i in state.players.indices {
                let uid = state.players[i].userId
                if let c = connectedByUser[uid], state.players[i].connected != c {
                    state.players[i].connected = c
                }
                // Forfait : silence long ET ce siège bloque le reveal.
                if isAnnouncePhase,
                   silentByUser[uid] == true,
                   blocking.contains(state.players[i].seat),
                   state.players[i].inManche,
                   state.players[i].forfeitFromBoard == nil {
                    state.players[i].forfeitFromBoard = state.currentBoard
                }
            }
        }
    }

    /// Sièges dont on attend encore une annonce (ils bloquent le reveal).
    private func blockingSeats(in gs: OnlineGameState) -> Set<Int> {
        if gs.phase == .announcing {
            return eligibleSeats(in: gs).subtracting(Set(gs.submissions.keys))
        }
        if gs.phase == .tiebreakAnnouncing, let tb = gs.tiebreakBoards.last {
            return Set(tb.eligibleSeats).subtracting(Set(tb.submissions.keys))
        }
        return []
    }

    // MARK: - Mutation hôte (CAS)

    /// Applique une mutation à la room et la publie (CAS). En cas de conflit,
    /// on repart de l'état renvoyé par le serveur et on rejoue la mutation
    /// (5 tentatives max).
    @discardableResult
    private func mutate(_ apply: (inout OnlineRoom) -> Void) async -> Bool {
        guard role == .host else { return false }
        for _ in 0..<5 {
            guard let base = room else { return false }
            let expected = version
            var candidate = base
            apply(&candidate)
            if candidate == base { return true }   // rien à écrire
            do {
                let result = try await transport.publish(code: candidate.code,
                                                         expectedVersion: expected,
                                                         state: candidate,
                                                         status: candidate.status.rawValue)
                applyEnvelope(result.room)
                if result.conflict { continue }
                return true
            } catch RoomError.notHost {
                log("room_publish → NOT_HOST : je repasse guest")
                role = .guest
                hostDriverTask?.cancel()
                hostDriverTask = nil
                await transport.resync()
                return false
            } catch {
                lastError = RoomError.from(error).userMessage
                return false
            }
        }
        log("mutate: 5 conflits CAS d'affilée, abandon")
        return false
    }

    /// Variante gameState, avec précondition évaluée sur l'état FRAIS au moment
    /// de l'écriture (c'est ce qui rend les pas de tempo idempotents).
    @discardableResult
    private func mutateGameState(when precondition: (OnlineGameState) -> Bool = { _ in true },
                                 _ apply: (inout OnlineGameState) -> Void) async -> Bool {
        await mutate { room in
            guard var gs = room.gameState, precondition(gs) else { return }
            apply(&gs)
            room.gameState = gs
        }
    }

    /// Conservé pour la lisibilité des appels historiques.
    private func updateGameState(_ apply: (inout OnlineGameState) -> Void) async {
        await mutateGameState(apply)
    }

    // MARK: - Réglages (host)

    func updateSettings(linePrice: Double? = nil,
                        flashMode: Bool? = nil,
                        announceTimerSeconds: Int? = nil) async {
        guard role == .host else { return }
        let changed = await mutate { room in
            if let v = linePrice            { room.linePrice = v }
            if let v = flashMode            { room.flashMode = v }
            if let v = announceTimerSeconds { room.announceTimerSeconds = v }
        }
        if changed, room?.cloudGameId != nil {
            await ensureGameInCloud()
        }
    }

    // MARK: - Démarrage de manche

    /// Host : démarre la 1ère manche. Le tempo est ensuite porté par le driver.
    func startGame() async {
        guard role == .host, let current = room else { return }
        guard current.participants.count >= 2 else {
            lastError = "Au moins 2 joueurs requis."
            return
        }
        guard let initialGameState = OnlineGameService.buildInitialGameState(
            mancheNumber: 1,
            participants: current.participants,
            dealerSeat: 0,
            linePrice: current.linePrice
        ) else {
            lastError = "Distribution impossible (trop de joueurs ou bug)."
            return
        }
        let ok = await mutate { room in
            guard room.status == .lobby else { return }
            room.status = .playing
            room.gameState = initialGameState
        }
        if ok {
            phase = .playing
            startHostDriver()
        }
    }

    /// Host : démarre la manche suivante (rotation du donneur, scores conservés).
    func startNextManche() async {
        guard role == .host, let current = room, let gs = current.gameState else { return }
        guard gs.phase == .mancheEnd else { return }

        let spectatorSeats = Set(gs.players.filter { $0.wantsToSpectate }.map { $0.seat })
        let n = gs.players.count
        guard n > 0 else { return }
        var nextDealer = (gs.dealerSeat + 1) % n
        var safety = 0
        while spectatorSeats.contains(nextDealer) && safety < n {
            nextDealer = (nextDealer + 1) % n
            safety += 1
        }
        guard !spectatorSeats.contains(nextDealer) else {
            log("startNextManche: pas assez de joueurs actifs")
            return
        }

        guard var newState = OnlineGameService.buildInitialGameState(
            mancheNumber: gs.mancheNumber + 1,
            participants: current.participants,
            dealerSeat: nextDealer,
            linePrice: current.linePrice,
            spectatorSeats: spectatorSeats
        ) else {
            log("startNextManche: build failed")
            return
        }

        // Carry-over des scores.
        let oldScores = Dictionary(uniqueKeysWithValues: gs.players.map { ($0.seat, $0.score) })
        for i in 0..<newState.players.count {
            newState.players[i].score = oldScores[newState.players[i].seat] ?? 0
        }
        newState.initialScores = Dictionary(
            uniqueKeysWithValues: newState.players.map { ($0.seat, $0.score) }
        )

        let targetManche = newState.mancheNumber
        await mutateGameState(when: { $0.phase == .mancheEnd && $0.mancheNumber < targetManche }) { state in
            state = newState
        }
        startHostDriver()
    }

    // MARK: - Driver de tempo (hôte) — pas idempotents

    /// Délais de pacing (nanosecondes).
    private static let revealInterval: UInt64    = 700_000_000
    private static let burnPause: UInt64         = 1_200_000_000
    private static let preAnnouncePause: UInt64  = 1_500_000_000
    private static let boardRevealPause: UInt64  = 5_000_000_000
    private static let tiebreakRevealPause: UInt64 = 4_000_000_000
    private static let splitBadgePause: UInt64   = 2_500_000_000
    private static let dealPause: UInt64         = 3_000_000_000
    private static let idleTick: UInt64          = 400_000_000

    /// (Re)lance la boucle de tempo. Idempotent : la boucle repart TOUJOURS de
    /// l'état courant, donc reprendre au milieu d'un reveal ne rejoue rien.
    func resumeFromCurrentPhase() {
        startHostDriver()
    }

    private func startHostDriver() {
        hostDriverTask?.cancel()
        guard role == .host else { return }
        hostDriverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.role == .host else { return }
                guard let gs = self.room?.gameState else {
                    try? await Task.sleep(nanoseconds: Self.idleTick)
                    continue
                }
                await self.driveOneStep(gs)
            }
        }
    }

    /// Un seul pas de tempo. Chaque pas : attente → relecture → précondition →
    /// écriture. Sans précondition satisfaite, le pas ne fait rien.
    private func driveOneStep(_ gs: OnlineGameState) async {
        switch gs.phase {

        case .dealing:
            // On laisse les joueurs encaisser leur main (tension dramatique).
            try? await Task.sleep(nanoseconds: Self.dealPause)
            guard !Task.isCancelled else { return }
            await mutateGameState(when: { $0.phase == .dealing }) { state in
                state.phase = .flop
                state.burnsRevealed = max(state.burnsRevealed, 1)
            }

        case .flop:
            if let (board, index) = nextMissingCommunityCard(gs, target: 3) {
                try? await Task.sleep(nanoseconds: Self.revealInterval)
                guard !Task.isCancelled else { return }
                await mutateGameState(when: {
                    $0.phase == .flop && $0.communityCards[board].count == index
                }) { state in
                    state.communityCards[board].append(state.pendingFlop[board][index])
                }
            } else {
                try? await Task.sleep(nanoseconds: Self.burnPause)
                guard !Task.isCancelled else { return }
                await mutateGameState(when: {
                    $0.phase == .flop && $0.communityCards.allSatisfy { $0.count >= 3 }
                }) { state in
                    state.phase = .turn
                    state.burnsRevealed = max(state.burnsRevealed, 2)
                }
            }

        case .turn:
            if let (board, index) = nextMissingCommunityCard(gs, target: 4) {
                try? await Task.sleep(nanoseconds: Self.revealInterval)
                guard !Task.isCancelled else { return }
                await mutateGameState(when: {
                    $0.phase == .turn && $0.communityCards[board].count == index
                }) { state in
                    state.communityCards[board].append(state.pendingTurns[board])
                }
            } else {
                try? await Task.sleep(nanoseconds: Self.burnPause)
                guard !Task.isCancelled else { return }
                await mutateGameState(when: {
                    $0.phase == .turn && $0.communityCards.allSatisfy { $0.count >= 4 }
                }) { state in
                    state.phase = .river
                    state.burnsRevealed = max(state.burnsRevealed, 3)
                }
            }

        case .river:
            if let (board, index) = nextMissingCommunityCard(gs, target: 5) {
                try? await Task.sleep(nanoseconds: Self.revealInterval)
                guard !Task.isCancelled else { return }
                await mutateGameState(when: {
                    $0.phase == .river && $0.communityCards[board].count == index
                }) { state in
                    state.communityCards[board].append(state.pendingRivers[board])
                }
            } else {
                // Les 15 cartes sont là : pause, puis annonces du board courant.
                try? await Task.sleep(nanoseconds: Self.preAnnouncePause)
                guard !Task.isCancelled else { return }
                await enterAnnouncing()
            }

        case .announcing, .tiebreakAnnouncing:
            await handleAnnounceDeadlineIfNeeded()
            await checkAllSubmitted()
            try? await Task.sleep(nanoseconds: Self.idleTick)

        case .boardReveal:
            if gs.boardResults.indices.contains(gs.currentBoard),
               gs.boardResults[gs.currentBoard] != nil {
                // Le board courant est résolu → on avance.
                let board = gs.currentBoard
                try? await Task.sleep(nanoseconds: Self.boardRevealPause)
                guard !Task.isCancelled else { return }
                await advanceAfterReveal(expectedBoard: board)
            } else {
                // Board suivant déjà armé : on ouvre les annonces.
                try? await Task.sleep(nanoseconds: Self.preAnnouncePause)
                guard !Task.isCancelled else { return }
                await enterAnnouncing()
            }

        case .tiebreakReveal:
            let index = gs.tiebreakBoards.count - 1
            try? await Task.sleep(nanoseconds: Self.tiebreakRevealPause)
            guard !Task.isCancelled else { return }
            await advanceAfterTiebreakReveal(expectedIndex: index)

        case .mancheEnd:
            await recordMancheToSupabase()
            try? await Task.sleep(nanoseconds: Self.idleTick)
        }
    }

    /// Premier (board, index) dont la carte communautaire manque pour atteindre
    /// `target` cartes. nil = tous les boards sont complets.
    private func nextMissingCommunityCard(_ gs: OnlineGameState, target: Int) -> (Int, Int)? {
        for board in 0..<min(3, gs.communityCards.count) {
            let count = gs.communityCards[board].count
            if count < target { return (board, count) }
        }
        return nil
    }

    // MARK: - Annonces

    /// Host : ouvre la phase d'annonces pour le board courant.
    func enterAnnouncing() async {
        guard role == .host, let current = room else { return }
        let deadline = computeDeadline(seconds: current.announceTimerSeconds)
        await mutateGameState(when: { $0.phase == .river || $0.phase == .boardReveal }) { gs in
            gs.phase = .announcing
            gs.submissions = [:]
            gs.excludedThisBoard = []
            gs.rebidRound = 0
            gs.announceDeadline = deadline
        }
    }

    /// Calcule un timestamp absolu (epoch sec) à atteindre, ou nil si désactivé.
    private func computeDeadline(seconds: Int) -> TimeInterval? {
        guard seconds > 0 else { return nil }
        return Date().timeIntervalSince1970 + Double(seconds)
    }

    /// Host : à l'échéance du timer, auto-skip pour les sièges silencieux.
    private func handleAnnounceDeadlineIfNeeded() async {
        guard role == .host, let gs = room?.gameState else { return }
        guard let deadline = gs.announceDeadline else { return }
        guard Date().timeIntervalSince1970 >= deadline else { return }
        await timerExpired()
    }

    private func timerExpired() async {
        guard role == .host, let gs = room?.gameState else { return }
        if gs.phase == .announcing {
            let eligible = eligibleSeats(in: gs)
            await mutateGameState(when: { $0.phase == .announcing }) { state in
                for seat in eligible where state.submissions[seat] == nil {
                    state.submissions[seat] = BoardSubmission(categoryId: "skip", cards: [])
                }
                state.announceDeadline = nil
            }
        } else if gs.phase == .tiebreakAnnouncing {
            await mutateGameState(when: { $0.phase == .tiebreakAnnouncing && !$0.tiebreakBoards.isEmpty }) { state in
                guard var tb = state.tiebreakBoards.last else { return }
                for seat in tb.eligibleSeats where tb.submissions[seat] == nil {
                    tb.submissions[seat] = BoardSubmission(categoryId: "skip", cards: [])
                }
                state.tiebreakBoards[state.tiebreakBoards.count - 1] = tb
                state.announceDeadline = nil
            }
        }
    }

    /// Guest/host : envoie son annonce. Le guest passe par `room_submit`
    /// (le serveur fusionne, l'hôte ne peut jamais l'effacer).
    func submitAnnounce(submission: BoardSubmission, mySeat: Int) async {
        guard let code = room?.code else { return }
        if role == .host {
            await applyLocalSubmission(seat: mySeat, submission: submission)
            await checkAllSubmitted()
        } else {
            do {
                let env = try await transport.submit(code: code, seat: mySeat, submission: submission)
                applyEnvelope(env)
            } catch RoomError.alreadySubmitted {
                // Déjà pris en compte — rien à signaler.
            } catch {
                lastError = RoomError.from(error).userMessage
            }
        }
    }

    /// Hôte : applique sa propre annonce (mêmes règles que le RPC serveur).
    private func applyLocalSubmission(seat: Int, submission: BoardSubmission) async {
        guard let gs = room?.gameState else { return }
        switch gs.phase {
        case .announcing:
            await mutateGameState(when: { state in
                state.phase == .announcing
                && state.submissions[seat] == nil
                && !state.excludedThisBoard.contains(seat)
                && Self.cardsBelongToHand(submission, hand: state.hands[seat] ?? [])
            }) { state in
                state.submissions[seat] = submission
            }
        case .tiebreakAnnouncing:
            await mutateGameState(when: { state in
                guard state.phase == .tiebreakAnnouncing, let tb = state.tiebreakBoards.last else { return false }
                return tb.eligibleSeats.contains(seat)
                    && tb.submissions[seat] == nil
                    && Self.cardsBelongToHand(submission, hand: state.hands[seat] ?? [])
            }) { state in
                guard var tb = state.tiebreakBoards.last else { return }
                tb.submissions[seat] = submission
                state.tiebreakBoards[state.tiebreakBoards.count - 1] = tb
            }
        default:
            return
        }
    }

    private static func cardsBelongToHand(_ submission: BoardSubmission, hand: [Card]) -> Bool {
        if submission.categoryId == "skip" { return true }
        // Main inconnue (état expurgé) : on laisse passer, le serveur tranche.
        if hand.isEmpty { return true }
        return submission.cards.allSatisfy { hand.contains($0) }
    }

    /// Host, idempotent : si tous les éligibles ont soumis, on révèle.
    private func checkAllSubmitted() async {
        guard role == .host, !isResolvingBoard, let gs = room?.gameState else { return }
        if gs.phase == .announcing {
            let eligible = eligibleSeats(in: gs)
            guard Set(gs.submissions.keys).isSuperset(of: eligible) else { return }
            isResolvingBoard = true
            defer { isResolvingBoard = false }
            await revealBoard()
        } else if gs.phase == .tiebreakAnnouncing, let tb = gs.tiebreakBoards.last {
            let stillEligible = tb.eligibleSeats.filter { seat in
                guard let p = gs.players.first(where: { $0.seat == seat }) else { return false }
                return p.forfeitFromBoard == nil
            }
            guard Set(tb.submissions.keys).isSuperset(of: Set(stillEligible)) else { return }
            isResolvingBoard = true
            defer { isResolvingBoard = false }
            await revealTiebreakBoard()
        }
    }

    // MARK: - Spectateur / kick

    /// Demande à passer en spectateur (ou à revenir) pour la MANCHE SUIVANTE.
    func setSelfSpectator(_ wantsToSpectate: Bool) async {
        guard let uid = myUserId, let code = room?.code, let gs = room?.gameState else { return }
        guard let seat = gs.players.first(where: { $0.userId == uid })?.seat else { return }
        if role == .host {
            await applySpectatorChange(seat: seat, wantsToSpectate: wantsToSpectate)
        } else {
            do {
                let env = try await transport.setSpectator(code: code, seat: seat, wants: wantsToSpectate)
                applyEnvelope(env)
            } catch {
                lastError = RoomError.from(error).userMessage
            }
        }
    }

    private func applySpectatorChange(seat: Int, wantsToSpectate: Bool) async {
        await mutateGameState { gs in
            guard let i = gs.players.firstIndex(where: { $0.seat == seat }) else { return }
            guard gs.players[i].wantsToSpectate != wantsToSpectate else { return }
            gs.players[i].wantsToSpectate = wantsToSpectate
        }
    }

    /// Host : exclut un joueur (force-disconnect explicite).
    func kickPlayer(seat: Int) async {
        guard role == .host, let myId = myUserId else { return }
        await mutateGameState { gs in
            guard let i = gs.players.firstIndex(where: { $0.seat == seat }) else { return }
            guard gs.players[i].userId != myId else { return }   // pas de kick sur soi
            gs.players[i].connected = false
            if gs.players[i].inManche,
               gs.players[i].forfeitFromBoard == nil,
               gs.phase != .mancheEnd {
                gs.players[i].forfeitFromBoard = gs.currentBoard
            }
            gs.players[i].wantsToSpectate = true
        }
        await checkAllSubmitted()
    }

    // MARK: - Reveal du board (logique de jeu inchangée)

    /// Host : reveal du board courant. Détermine winner / split / abandon,
    /// stocke dans boardResults[currentBoard].
    func revealBoard() async {
        guard role == .host, let current = room, var gs = current.gameState else { return }
        guard gs.phase == .announcing else { return }

        let boardIdx = gs.currentBoard
        let boardCards = gs.communityCards[boardIdx]
        var perPlayer: [PlayerBoardResult] = []
        for player in gs.players where player.inManche {
            let sub = gs.submissions[player.seat]
            let isExcluded = gs.excludedThisBoard.contains(player.seat)
            let isForfeit  = player.forfeitFromBoard.map { $0 <= boardIdx } ?? false
            let isSkip     = sub?.categoryId == "skip"
            let cards      = sub?.cards ?? []
            var isValid = false
            if let categoryId = sub?.categoryId,
               let cat = HandCategory.from(id: categoryId),
               !isSkip, !isExcluded, !isForfeit {
                isValid = HandEvaluator.validateAnnounce(cat, hole: cards, board: boardCards)
            }
            let isBluff = sub != nil && !isSkip && !isExcluded && !isForfeit && !isValid
            perPlayer.append(PlayerBoardResult(
                userId: player.userId, seat: player.seat,
                announcedCategoryId: sub?.categoryId,
                cards: cards, isValid: isValid, isBluff: isBluff,
                isSkip: isSkip, isExcluded: isExcluded, isForfeit: isForfeit
            ))
        }

        let validResults = perPlayer.filter { $0.isValid }
        var winnerSeat: Int?
        var winningCategoryId: String?
        var finalMulti = 1
        var isSplit = false
        var splitterSeats: [Int] = []
        var abandoned = false

        if validResults.isEmpty {
            // Tous les annonceurs ont bluffé → on les exclut.
            let bluffers = perPlayer.filter { $0.isBluff }.map { $0.seat }
            gs.excludedThisBoard.append(contentsOf: bluffers)

            let nonExcludedSeats = gs.players
                .filter { $0.inManche && !gs.excludedThisBoard.contains($0.seat) }
                .map { $0.seat }
            if !nonExcludedSeats.isEmpty && gs.rebidRound < 2 {
                let deadline = computeDeadline(seconds: current.announceTimerSeconds)
                let round = gs.rebidRound + 1
                log("revealBoard: ALL BLUFF, rebid #\(round)")
                await mutateGameState(when: { $0.phase == .announcing && $0.rebidRound < round }) { state in
                    for seat in bluffers where !state.excludedThisBoard.contains(seat) {
                        state.excludedThisBoard.append(seat)
                    }
                    state.rebidRound = round
                    state.submissions = [:]
                    state.announceDeadline = deadline
                }
                return
            }
            abandoned = true
        } else {
            // L'annonce du joueur PRIME : on compare au sein de la catégorie annoncée.
            let sorted = validResults.sorted { a, b in
                guard let ca = a.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }),
                      let cb = b.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }) else { return false }
                if ca != cb { return ca.rawValue > cb.rawValue }
                return compareWithinCategory(ca, a: a.cards, b: b.cards, board: boardCards) > 0
            }
            let top = sorted[0]
            let topCat = top.announcedCategoryId.flatMap { HandCategory.from(id: $0) }
            let tied = sorted.filter { r in
                guard r.announcedCategoryId == top.announcedCategoryId,
                      let cat = topCat else { return false }
                return compareWithinCategory(cat, a: r.cards, b: top.cards, board: boardCards) == 0
            }
            if tied.count >= 2 {
                isSplit = true
                splitterSeats = tied.map { $0.seat }
                winnerSeat = nil
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            } else {
                winnerSeat = top.seat
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            }
        }

        let result = BoardResult(
            board: boardIdx, winnerSeat: winnerSeat,
            winningCategoryId: winningCategoryId, finalMulti: finalMulti,
            isSplit: isSplit, splitterSeats: splitterSeats,
            perPlayer: perPlayer, abandoned: abandoned
        )
        let excluded = gs.excludedThisBoard

        if isSplit {
            // Pas de scoring : on attend le tie-break.
            await mutateGameState(when: {
                $0.phase == .announcing && $0.currentBoard == boardIdx
            }) { state in
                state.excludedThisBoard = excluded
                state.boardResults[boardIdx] = result
                state.announceDeadline = nil
            }
            // Petit délai pour montrer le badge ⚡ Split.
            try? await Task.sleep(nanoseconds: Self.splitBadgePause)
            guard !Task.isCancelled else { return }
            await enterTiebreak(parentBoardIdx: boardIdx,
                                eligibleSeats: splitterSeats,
                                round: 0)
            return
        }

        await mutateGameState(when: {
            $0.phase == .announcing && $0.currentBoard == boardIdx
        }) { state in
            state.excludedThisBoard = excluded
            state.boardResults[boardIdx] = result
            self.applyBoardScoring(gs: &state, result: result)
            state.phase = .boardReveal
            state.announceDeadline = nil
        }
    }

    /// Compare deux annonces AU SEIN de la catégorie annoncée.
    private func compareWithinCategory(_ cat: HandCategory,
                                       a: [Card],
                                       b: [Card],
                                       board: [Card]) -> Int {
        if cat == .highcard {
            let aTop = a.map { $0.rank.value }.max() ?? 0
            let bTop = b.map { $0.rank.value }.max() ?? 0
            return aTop - bTop
        }
        let bestA = HandEvaluator.evaluateBest(a + board)
        let bestB = HandEvaluator.evaluateBest(b + board)
        guard let bA = bestA, let bB = bestB else { return 0 }
        return HandEvaluator.compare(bA, bB)
    }

    // MARK: - Tie-break

    /// Host : entre dans un round de tie-break sur un board virtuel (5 cartes
    /// tirées hors hole cards des splitters et hors tie-breaks précédents).
    private func enterTiebreak(parentBoardIdx: Int,
                               eligibleSeats: [Int],
                               round: Int) async {
        guard role == .host, let current = room, let gs = current.gameState else { return }

        let splitterHoles = Set(eligibleSeats.flatMap { gs.hands[$0] ?? [] })
        let alreadyUsedInTiebreaks = Set(gs.tiebreakBoards.flatMap { $0.cards })
        var pool = Deck.full.filter {
            !splitterHoles.contains($0) && !alreadyUsedInTiebreaks.contains($0)
        }
        pool.shuffle()

        guard pool.count >= 5 else {
            log("enterTiebreak: pool épuisé (\(pool.count)), winner arbitraire")
            if let first = eligibleSeats.first {
                await finalizeParentBoard(parentBoardIdx: parentBoardIdx, winnerSeat: first)
            }
            return
        }

        // Les cartes sont tirées UNE fois, hors de la mutation (qui peut être
        // rejouée en cas de conflit CAS).
        let tb = TiebreakBoard(
            parentBoardIdx: parentBoardIdx,
            round: round,
            cards: Array(pool.prefix(5)),
            eligibleSeats: eligibleSeats
        )
        let deadline = computeDeadline(seconds: current.announceTimerSeconds)
        let expectedCount = gs.tiebreakBoards.count

        await mutateGameState(when: { $0.tiebreakBoards.count == expectedCount }) { state in
            state.tiebreakBoards.append(tb)
            state.phase = .tiebreakAnnouncing
            state.announceDeadline = deadline
        }
    }

    /// Host : évalue le tie-break courant.
    private func revealTiebreakBoard() async {
        guard role == .host, let current = room, let gs = current.gameState else { return }
        guard gs.phase == .tiebreakAnnouncing else { return }
        guard var tb = gs.tiebreakBoards.last,
              let parentResult = gs.boardResults[tb.parentBoardIdx],
              let catId = parentResult.winningCategoryId,
              let lockedCat = HandCategory.from(id: catId) else { return }

        let tbCards = tb.cards
        var perPlayer: [PlayerBoardResult] = []
        for seat in tb.eligibleSeats {
            guard let player = gs.players.first(where: { $0.seat == seat }) else { continue }
            let sub = tb.submissions[seat]
            let cards = sub?.cards ?? []
            let isSkip = sub?.categoryId == "skip"
            var isValid = false
            if !isSkip, !cards.isEmpty {
                isValid = HandEvaluator.validateAnnounce(lockedCat, hole: cards, board: tbCards)
            } else if !isSkip, lockedCat == .highcard {
                isValid = true
            }
            let isBluff = !isSkip && !isValid
            perPlayer.append(PlayerBoardResult(
                userId: player.userId, seat: seat,
                announcedCategoryId: catId,
                cards: cards, isValid: isValid, isBluff: isBluff,
                isSkip: isSkip, isExcluded: false, isForfeit: false
            ))
        }

        let validResults = perPlayer.filter { $0.isValid }
        var winnerSeat: Int? = nil
        var isSplit = false
        var splitterSeats: [Int] = []

        if validResults.isEmpty {
            winnerSeat = tb.eligibleSeats.first
        } else {
            let sorted = validResults.sorted { a, b in
                compareWithinCategory(lockedCat, a: a.cards, b: b.cards, board: tbCards) > 0
            }
            let top = sorted[0]
            let tied = sorted.filter { r in
                compareWithinCategory(lockedCat, a: r.cards, b: top.cards, board: tbCards) == 0
            }
            if tied.count >= 2 {
                isSplit = true
                splitterSeats = tied.map { $0.seat }
            } else {
                winnerSeat = top.seat
            }
        }

        tb.result = BoardResult(
            board: tb.parentBoardIdx,
            winnerSeat: winnerSeat,
            winningCategoryId: catId,
            finalMulti: parentResult.finalMulti,
            isSplit: isSplit,
            splitterSeats: splitterSeats,
            perPlayer: perPlayer,
            abandoned: false
        )
        let resolved = tb
        let index = gs.tiebreakBoards.count - 1

        await mutateGameState(when: {
            $0.phase == .tiebreakAnnouncing
            && $0.tiebreakBoards.count == index + 1
            && $0.tiebreakBoards[index].result == nil
        }) { state in
            state.tiebreakBoards[index] = resolved
            state.phase = .tiebreakReveal
            state.announceDeadline = nil
        }
    }

    /// Après la pause de `tiebreakReveal` : re-split ou finalisation du parent.
    private func advanceAfterTiebreakReveal(expectedIndex: Int) async {
        guard role == .host, let gs = room?.gameState else { return }
        guard gs.phase == .tiebreakReveal else { return }
        guard gs.tiebreakBoards.count == expectedIndex + 1,
              let tb = gs.tiebreakBoards.last,
              let result = tb.result else { return }
        if result.isSplit {
            await enterTiebreak(parentBoardIdx: tb.parentBoardIdx,
                                eligibleSeats: result.splitterSeats,
                                round: tb.round + 1)
        } else if let winner = result.winnerSeat {
            await finalizeParentBoard(parentBoardIdx: tb.parentBoardIdx, winnerSeat: winner)
        }
    }

    /// Host : applique le résultat du tie-break au board parent.
    private func finalizeParentBoard(parentBoardIdx: Int, winnerSeat: Int) async {
        guard role == .host, let gs = room?.gameState else { return }
        guard var parentResult = gs.boardResults[parentBoardIdx] else { return }
        parentResult.winnerSeat = winnerSeat
        parentResult.isSplit = false

        // Le scoring utilise la VRAIE meilleure main du gagnant sur le board de
        // split : si l'annonce parent était une suite et qu'il fait un carré,
        // il touche ×8 et pas ×1.
        if let lastTb = gs.tiebreakBoards.last,
           let winnerHole = gs.hands[winnerSeat],
           let best = HandEvaluator.evaluateBest(winnerHole + lastTb.cards) {
            let upgradedCat = best.category
            if upgradedCat.multi > parentResult.finalMulti {
                log("finalizeParentBoard: multi ×\(parentResult.finalMulti) → ×\(upgradedCat.multi)")
                parentResult.winningCategoryId = upgradedCat.id
                parentResult.finalMulti = upgradedCat.multi
            }
        }

        let finalResult = parentResult
        await mutateGameState(when: {
            ($0.phase == .tiebreakReveal || $0.phase == .tiebreakAnnouncing)
            && $0.boardResults[parentBoardIdx]?.winnerSeat == nil
        }) { state in
            state.boardResults[parentBoardIdx] = finalResult
            self.applyBoardScoring(gs: &state, result: finalResult)
            state.phase = .boardReveal
            state.announceDeadline = nil
        }
    }

    // MARK: - Enchaînement des boards / fin de manche

    /// Host : après le reveal du board `expectedBoard`, on passe au suivant ou
    /// on termine la manche. Idempotent.
    func advanceAfterReveal(expectedBoard: Int) async {
        guard role == .host, let gs = room?.gameState else { return }
        guard gs.phase == .boardReveal, gs.currentBoard == expectedBoard else { return }
        guard gs.boardResults.indices.contains(expectedBoard),
              gs.boardResults[expectedBoard] != nil else { return }

        if expectedBoard < 2 {
            await mutateGameState(when: {
                $0.phase == .boardReveal && $0.currentBoard == expectedBoard
            }) { state in
                state.currentBoard += 1
            }
        } else {
            await mutateGameState(when: {
                $0.phase == .boardReveal && $0.currentBoard == 2
            }) { state in
                self.applyFullBoardBonus(gs: &state)
                state.phase = .mancheEnd
            }
            // Archive locale de la manche pour le sheet « Solde & historique ».
            if let updated = room?.gameState, updated.phase == .mancheEnd {
                let archive = buildMancheArchive(gs: updated)
                await mutate { room in
                    guard !room.pastManches.contains(where: { $0.mancheNumber == archive.mancheNumber }) else { return }
                    room.pastManches.append(archive)
                }
            }
        }
    }

    /// Construit l'archive d'une manche terminée.
    private func buildMancheArchive(gs: OnlineGameState) -> MancheArchive {
        var perPlayerDelta: [Int: Double] = [:]
        var boardsWon: [Int: [Int]] = [:]
        var boardMultis: [Int: Int] = [:]
        for r in gs.boardResults.compactMap({ $0 }) {
            boardMultis[r.board] = r.finalMulti
        }
        for p in gs.players {
            perPlayerDelta[p.seat] = p.score - (gs.initialScores[p.seat] ?? 0)
            boardsWon[p.seat] = gs.boardResults.compactMap { r -> Int? in
                guard let r else { return nil }
                return r.winnerSeat == p.seat ? r.board : nil
            }
        }
        let numActive = gs.players.filter { $0.inManche }.count
        return MancheArchive(
            mancheNumber: gs.mancheNumber,
            dealerSeat: gs.dealerSeat,
            perPlayerDelta: perPlayerDelta,
            boardsWon: boardsWon,
            fullBoardWinnerSeat: gs.fullBoardWinnerSeat,
            numActive: numActive,
            boardMultis: boardMultis
        )
    }

    // MARK: - Scoring (RULES.md)

    /// Score d'un board : gagnant +prix×multi×(N-1), chaque autre joueur actif
    /// paie prix×multi. Skip/forfeit comptent comme « loser ».
    private func applyBoardScoring(gs: inout OnlineGameState, result: BoardResult) {
        guard !result.abandoned, let winnerSeat = result.winnerSeat else { return }
        let prix = gs.linePrice
        let multi = Double(result.finalMulti)
        let activeSeats = gs.players.filter { $0.inManche }.map { $0.seat }
        let N = activeSeats.count
        guard N >= 2 else { return }

        let winnerGain = prix * multi * Double(N - 1)
        let loserCost  = prix * multi

        for i in 0..<gs.players.count {
            let seat = gs.players[i].seat
            guard gs.players[i].inManche else { continue }
            if seat == winnerSeat {
                gs.players[i].score += winnerGain
            } else {
                gs.players[i].score -= loserCost
            }
        }
    }

    /// Bonus « Full Board » : même joueur sur les 3 boards → +prix×(N-1).
    private func applyFullBoardBonus(gs: inout OnlineGameState) {
        let winners = gs.boardResults.compactMap { $0?.winnerSeat }
        guard winners.count == 3, Set(winners).count == 1, let fbWinner = winners.first else {
            return
        }
        let prix = gs.linePrice
        let activeSeats = gs.players.filter { $0.inManche }.map { $0.seat }
        let N = activeSeats.count
        guard N >= 2 else { return }

        let bonus = prix * Double(N - 1)
        let cost  = prix

        for i in 0..<gs.players.count {
            let seat = gs.players[i].seat
            guard gs.players[i].inManche else { continue }
            if seat == fbWinner {
                gs.players[i].score += bonus
            } else {
                gs.players[i].score -= cost
            }
        }
        gs.fullBoardWinnerSeat = fbWinner
    }

    // MARK: - Persistance Supabase (record_manche, T15)

    /// Host : envoie la manche au RPC `record_manche`, avec 3 tentatives et un
    /// backoff 1/2/4 s. Le RPC est idempotent côté SQL (manche_number + game).
    private func recordMancheToSupabase() async {
        guard role == .host, let current = room, let gs = current.gameState else { return }
        guard gs.phase == .mancheEnd else { return }
        guard !recordedManches.contains(gs.mancheNumber) else { return }

        let numActive = gs.players.filter { $0.inManche }.count
        guard numActive >= 2 else {
            recordedManches.insert(gs.mancheNumber)
            return
        }
        recordedManches.insert(gs.mancheNumber)

        let participants = current.participants.enumerated().map { idx, p in
            RecordMancheParticipant(seat_index: idx, user_id: p.userId.uuidString, guest_name: nil)
        }

        let boardResults: [RecordMancheBoardResult] = (0..<3).compactMap { i in
            guard let r = gs.boardResults[i] else {
                return RecordMancheBoardResult(board: i, winner_seat: nil,
                                               category_id: nil, multi: 1,
                                               is_split: false, abandoned: true)
            }
            return RecordMancheBoardResult(
                board: r.board,
                winner_seat: r.winnerSeat,
                category_id: r.winningCategoryId,
                multi: r.finalMulti,
                is_split: r.isSplit,
                abandoned: r.abandoned
            )
        }

        let resultsPerSeat: [RecordMancheResultPerSeat] = gs.players.map { p in
            let initial = gs.initialScores[p.seat] ?? 0
            let boardsWon = gs.boardResults.compactMap { r -> Int? in
                guard let r else { return nil }
                return r.winnerSeat == p.seat ? r.board : nil
            }
            return RecordMancheResultPerSeat(
                seat_index: p.seat,
                delta: p.score - initial,
                boards_won_json: boardsWon
            )
        }

        let params = RecordMancheParams(
            p_game_id: current.cloudGameId?.uuidString,
            p_mode: "online",
            p_line_price: current.linePrice,
            p_currency: "EUR",
            p_settings_json: RecordMancheSettings(flash_mode: current.flashMode,
                                                  announce_timer_seconds: current.announceTimerSeconds),
            p_participants: participants,
            p_manche_number: gs.mancheNumber,
            p_dealer_seat: gs.dealerSeat,
            p_num_active: numActive,
            p_board_results: boardResults,
            p_full_board_seat: gs.fullBoardWinnerSeat,
            p_results_per_seat: resultsPerSeat
        )

        var delay: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            do {
                let response = try await client.rpc("record_manche", params: params).execute()
                let returnedGameId = try JSONDecoder().decode(UUID.self, from: response.data)
                if current.cloudGameId == nil {
                    await mutate { room in
                        guard room.cloudGameId == nil else { return }
                        room.cloudGameId = returnedGameId
                    }
                }
                log("record_manche OK (essai \(attempt))")
                return
            } catch {
                log("record_manche échec \(attempt)/3 : \(error.localizedDescription)")
                if attempt == 3 {
                    // On laisse la manche retentable par le prochain hôte.
                    recordedManches.remove(gs.mancheNumber)
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
    }

    // MARK: - Cycle de vie cloud (ensure + touch)

    /// Host : crée la `games` Supabase (ou synchronise ses participants).
    private func ensureGameInCloud() async {
        guard role == .host, let current = room else { return }

        let participantsPayload = current.participants.enumerated().map { idx, p in
            EnsureGameParticipant(seat_index: idx, user_id: p.userId.uuidString, guest_name: nil)
        }
        let params = EnsureGameParams(
            p_game_id: current.cloudGameId?.uuidString,
            p_mode: "online",
            p_line_price: current.linePrice,
            p_currency: "EUR",
            p_settings_json: RecordMancheSettings(flash_mode: current.flashMode,
                                                  announce_timer_seconds: current.announceTimerSeconds),
            p_participants: participantsPayload
        )
        do {
            let response = try await client.rpc("ensure_game_and_participants", params: params).execute()
            let returnedGameId = try JSONDecoder().decode(UUID.self, from: response.data)
            if current.cloudGameId == nil {
                await mutate { room in
                    guard room.cloudGameId == nil else { return }
                    room.cloudGameId = returnedGameId
                }
            }
        } catch {
            log("ensure_game FAILED: \(error.localizedDescription)")
        }
    }

    /// Bump `last_active_at` toutes les 30 s (historique « En cours »).
    private func startTouchActiveLoop() {
        touchActiveTask?.cancel()
        touchActiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.touchActiveOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.touchInterval * 1_000_000_000))
            }
        }
    }

    private func touchActiveOnce() async {
        guard let gameId = room?.cloudGameId else { return }
        struct TouchParams: Encodable { let p_game_id: String }
        _ = try? await client.rpc("touch_game_active",
                                  params: TouchParams(p_game_id: gameId.uuidString)).execute()
    }

    // MARK: - Utilitaires

    /// Sièges encore éligibles à soumettre une annonce sur le board courant.
    private func eligibleSeats(in gs: OnlineGameState) -> Set<Int> {
        var result: Set<Int> = []
        for p in gs.players where p.inManche {
            if gs.excludedThisBoard.contains(p.seat) { continue }
            if let ff = p.forfeitFromBoard, ff <= gs.currentBoard { continue }
            result.insert(p.seat)
        }
        return result
    }

    // MARK: - Construction de l'état initial (host)

    /// Construit l'état initial d'une manche : seats fixes, deck mélangé,
    /// mains distribuées, community pré-piochée, brûles cachées.
    static func buildInitialGameState(
        mancheNumber: Int,
        participants: [OnlineParticipant],
        dealerSeat: Int,
        linePrice: Double,
        spectatorSeats: Set<Int> = []
    ) -> OnlineGameState? {
        let players = participants.enumerated().map { idx, p in
            let isSpect = spectatorSeats.contains(idx)
            return GamePlayer(
                userId: p.userId, displayName: p.displayName,
                seat: idx, score: 0,
                inManche: !isSpect, connected: true, forfeitFromBoard: nil,
                wantsToSpectate: isSpect
            )
        }
        let activeSeats = players.filter { $0.inManche }.map { $0.seat }
        let target = OnlineDealer.cardsPerPlayer(activeCount: activeSeats.count)
        guard target > 0 else { return nil }

        let n = players.count
        guard n > 0 else { return nil }
        let dealOrderAll: [Int] = (1...n).map { (dealerSeat + $0) % n }
        let dealOrder = dealOrderAll.filter { activeSeats.contains($0) }

        var deck = Deck.shuffled()
        guard let hands = OnlineDealer.dealHands(
            deck: &deck, orderedSeats: dealOrder, target: target
        ) else { return nil }

        guard let community = OnlineDealer.dealCommunity(deck: &deck) else { return nil }

        var state = OnlineGameState(
            mancheNumber: mancheNumber,
            linePrice: linePrice,
            players: players,
            dealerSeat: dealerSeat,
            phase: .dealing,
            currentBoard: 0,
            rebidRound: 0,
            hands: hands,
            burns: [community.burn1, community.burn2, community.burn3],
            burnsRevealed: 0,
            communityCards: [[], [], []],
            pendingFlop: community.flop,
            pendingTurns: community.turns,
            pendingRivers: community.rivers,
            submissions: [:],
            boardResults: [nil, nil, nil],
            fullBoardWinnerSeat: nil,
            excludedThisBoard: [],
            tiebreakBoards: []
        )
        state.initialScores = Dictionary(
            uniqueKeysWithValues: players.map { ($0.seat, $0.score) }
        )
        return state
    }
}

// MARK: - RPC record_manche payload types

private struct RecordMancheParticipant: Encodable {
    let seat_index: Int
    let user_id: String?
    let guest_name: String?
}

private struct RecordMancheBoardResult: Encodable {
    let board: Int
    let winner_seat: Int?
    let category_id: String?
    let multi: Int
    let is_split: Bool
    let abandoned: Bool
}

private struct RecordMancheResultPerSeat: Encodable {
    let seat_index: Int
    let delta: Double
    let boards_won_json: [Int]
}

private struct RecordMancheSettings: Encodable {
    let flash_mode: Bool
    let announce_timer_seconds: Int
}

private struct RecordMancheParams: Encodable {
    let p_game_id: String?
    let p_mode: String
    let p_line_price: Double
    let p_currency: String
    let p_settings_json: RecordMancheSettings
    let p_participants: [RecordMancheParticipant]
    let p_manche_number: Int
    let p_dealer_seat: Int
    let p_num_active: Int
    let p_board_results: [RecordMancheBoardResult]
    let p_full_board_seat: Int?
    let p_results_per_seat: [RecordMancheResultPerSeat]

    enum CodingKeys: String, CodingKey {
        case p_game_id, p_mode, p_line_price, p_currency, p_settings_json,
             p_participants, p_manche_number, p_dealer_seat, p_num_active,
             p_board_results, p_full_board_seat, p_results_per_seat
    }

    // ⚠️ encode `null` explicite (pas `encodeIfPresent`) pour que PostgREST
    // matche la signature à 12 paramètres (sinon PGRST202).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_game_id, forKey: .p_game_id)
        try c.encode(p_mode, forKey: .p_mode)
        try c.encode(p_line_price, forKey: .p_line_price)
        try c.encode(p_currency, forKey: .p_currency)
        try c.encode(p_settings_json, forKey: .p_settings_json)
        try c.encode(p_participants, forKey: .p_participants)
        try c.encode(p_manche_number, forKey: .p_manche_number)
        try c.encode(p_dealer_seat, forKey: .p_dealer_seat)
        try c.encode(p_num_active, forKey: .p_num_active)
        try c.encode(p_board_results, forKey: .p_board_results)
        try c.encode(p_full_board_seat, forKey: .p_full_board_seat)
        try c.encode(p_results_per_seat, forKey: .p_results_per_seat)
    }
}

// MARK: - RPC ensure_game_and_participants payload types

private struct EnsureGameParticipant: Encodable {
    let seat_index: Int
    let user_id: String?
    let guest_name: String?
}

private struct EnsureGameParams: Encodable {
    let p_game_id: String?
    let p_mode: String
    let p_line_price: Double
    let p_currency: String
    let p_settings_json: RecordMancheSettings
    let p_participants: [EnsureGameParticipant]

    enum CodingKeys: String, CodingKey {
        case p_game_id, p_mode, p_line_price, p_currency,
             p_settings_json, p_participants
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_game_id, forKey: .p_game_id)
        try c.encode(p_mode, forKey: .p_mode)
        try c.encode(p_line_price, forKey: .p_line_price)
        try c.encode(p_currency, forKey: .p_currency)
        try c.encode(p_settings_json, forKey: .p_settings_json)
        try c.encode(p_participants, forKey: .p_participants)
    }
}
