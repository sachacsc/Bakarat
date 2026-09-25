//
//  RoomTransport.swift
//  Bakarat
//
//  Transport de la « salle durable » (docs/PLAN_ONLINE_V2.md — T12).
//
//  La vérité vit dans Postgres (`online_rooms` + `online_room_members`), pas
//  dans la RAM d'un téléphone. Ce transport ne fait QUE trois choses :
//
//   1. appeler les RPC `room_*` (toutes `security definer`), écritures
//      sérialisées dans une file (une seule en vol) ;
//   2. écouter le channel Realtime `room:CODE` — un `UPDATE` sur la ligne est
//      traité comme un simple **ping** : on ne décode jamais le record, on
//      rappelle `room_get` ;
//   3. poller `room_heartbeat` (2 s en lobby, 5 s en partie) : ça renouvelle
//      notre `last_seen_at` (et le bail si on est hôte) et ça nous dit si la
//      `version` a bougé — auquel cas on relit `room_get`.
//
//  Perdre un message ne coûte plus rien : on relit. Le service de jeu ne voit
//  que des `RoomEnvelope` ordonnés (version strictement croissante).
//

import Combine
import Foundation
import Network
import Realtime
import Supabase

// MARK: - Modèles d'enveloppe (retours des RPC)

/// Un membre du salon tel que le serveur le connaît (table `online_room_members`).
struct RoomMember: Codable, Equatable, Identifiable, Sendable {
    let userId: UUID
    let displayName: String
    let lastSeenAt: Date
    let leftAt: Date?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case lastSeenAt = "last_seen_at"
        case leftAt = "left_at"
    }

    init(userId: UUID, displayName: String, lastSeenAt: Date, leftAt: Date?) {
        self.userId = userId
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.leftAt = leftAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = try c.decode(UUID.self, forKey: .userId)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "?"
        self.lastSeenAt = try c.decodePostgresDate(forKey: .lastSeenAt) ?? Date(timeIntervalSince1970: 0)
        self.leftAt = try c.decodePostgresDate(forKey: .leftAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userId, forKey: .userId)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(PostgresTimestamp.string(from: lastSeenAt), forKey: .lastSeenAt)
        try c.encode(leftAt.map(PostgresTimestamp.string(from:)), forKey: .leftAt)
    }
}

/// Retour de `room_get` / `room_join` / `room_create` / `room_submit` /
/// `room_set_spectator` / `room_claim_host`. La `state` est un `OnlineRoom`
/// encodé, avec `gameState.hands` expurgé côté serveur (seule ma main, sauf si
/// je suis l'hôte ou si la phase est `mancheEnd`).
struct RoomEnvelope: Codable, Equatable, Sendable {
    let code: String
    let version: Int64
    let status: String
    let hostUserId: UUID
    let hostLeaseUntil: Date
    let serverNow: Date
    let cloudGameId: UUID?
    let state: OnlineRoom
    let members: [RoomMember]

    enum CodingKeys: String, CodingKey {
        case code, version, status, state, members
        case hostUserId = "host_user_id"
        case hostLeaseUntil = "host_lease_until"
        case serverNow = "server_now"
        case cloudGameId = "cloud_game_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(String.self, forKey: .code)
        self.version = try c.decode(Int64.self, forKey: .version)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "lobby"
        self.hostUserId = try c.decode(UUID.self, forKey: .hostUserId)
        self.hostLeaseUntil = try c.decodePostgresDate(forKey: .hostLeaseUntil) ?? Date(timeIntervalSince1970: 0)
        self.serverNow = try c.decodePostgresDate(forKey: .serverNow) ?? Date()
        self.cloudGameId = try c.decodeIfPresent(UUID.self, forKey: .cloudGameId)
        self.state = try c.decode(OnlineRoom.self, forKey: .state)
        self.members = try c.decodeIfPresent([RoomMember].self, forKey: .members) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(version, forKey: .version)
        try c.encode(status, forKey: .status)
        try c.encode(hostUserId, forKey: .hostUserId)
        try c.encode(PostgresTimestamp.string(from: hostLeaseUntil), forKey: .hostLeaseUntil)
        try c.encode(PostgresTimestamp.string(from: serverNow), forKey: .serverNow)
        try c.encode(cloudGameId, forKey: .cloudGameId)
        try c.encode(state, forKey: .state)
        try c.encode(members, forKey: .members)
    }
}

/// Retour léger de `room_heartbeat` — sert de poll.
struct RoomHeartbeat: Codable, Equatable, Sendable {
    let version: Int64
    let hostUserId: UUID
    let hostLeaseUntil: Date
    let serverNow: Date
    let members: [RoomMember]

    enum CodingKeys: String, CodingKey {
        case version, members
        case hostUserId = "host_user_id"
        case hostLeaseUntil = "host_lease_until"
        case serverNow = "server_now"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int64.self, forKey: .version)
        self.hostUserId = try c.decode(UUID.self, forKey: .hostUserId)
        self.hostLeaseUntil = try c.decodePostgresDate(forKey: .hostLeaseUntil) ?? Date(timeIntervalSince1970: 0)
        self.serverNow = try c.decodePostgresDate(forKey: .serverNow) ?? Date()
        self.members = try c.decodeIfPresent([RoomMember].self, forKey: .members) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(hostUserId, forKey: .hostUserId)
        try c.encode(PostgresTimestamp.string(from: hostLeaseUntil), forKey: .hostLeaseUntil)
        try c.encode(PostgresTimestamp.string(from: serverNow), forKey: .serverNow)
        try c.encode(members, forKey: .members)
    }
}

/// Retour de `room_publish` : `conflict = true` quand la version attendue ne
/// correspond plus (rien n'a été écrit), avec l'état frais à ré-appliquer.
struct PublishResult: Codable, Equatable, Sendable {
    let conflict: Bool
    let room: RoomEnvelope
}

// MARK: - Erreurs typées

/// Les RPC lèvent des `raise exception` en MAJUSCULES_SNAKE. PostgREST les
/// remonte dans `PostgrestError.message` — on les mappe ici.
enum RoomError: Error, Equatable, Sendable {
    case notAuthenticated
    case roomNotFound
    case notMember
    case notHost
    case leaseActive
    case badPhase
    case notYourSeat
    case notEligible
    case badCards
    case alreadySubmitted
    case badSubmission
    case roomFinished
    case codeTaken
    case badCode
    case badState
    case badStatus
    case codeExhausted
    case noSession
    case timedOut
    case other(String)

    /// Mappe un message PostgREST (ou n'importe quelle erreur) vers un cas typé.
    static func from(_ error: Error) -> RoomError {
        if let already = error as? RoomError { return already }
        let message: String
        if let pg = error as? PostgrestError {
            message = pg.message
        } else {
            message = (error as NSError).localizedDescription
        }
        return Self.from(message: message)
    }

    static func from(message: String) -> RoomError {
        let upper = message.uppercased()
        // On cherche le token (le message peut être préfixé par PostgREST).
        if upper.contains("NOT_AUTHENTICATED") { return .notAuthenticated }
        if upper.contains("ROOM_NOT_FOUND") { return .roomNotFound }
        if upper.contains("NOT_MEMBER") { return .notMember }
        if upper.contains("NOT_HOST") { return .notHost }
        if upper.contains("LEASE_ACTIVE") { return .leaseActive }
        if upper.contains("BAD_PHASE") { return .badPhase }
        if upper.contains("NOT_YOUR_SEAT") { return .notYourSeat }
        if upper.contains("NOT_ELIGIBLE") { return .notEligible }
        if upper.contains("BAD_CARDS") { return .badCards }
        if upper.contains("ALREADY_SUBMITTED") { return .alreadySubmitted }
        if upper.contains("BAD_SUBMISSION") { return .badSubmission }
        if upper.contains("ROOM_FINISHED") { return .roomFinished }
        if upper.contains("CODE_TAKEN") { return .codeTaken }
        if upper.contains("CODE_EXHAUSTED") { return .codeExhausted }
        if upper.contains("BAD_CODE") { return .badCode }
        if upper.contains("BAD_STATE") { return .badState }
        if upper.contains("BAD_STATUS") { return .badStatus }
        return .other(message)
    }

    /// Message affichable à l'utilisateur (français).
    var userMessage: String {
        switch self {
        case .notAuthenticated: return "Session expirée. Reconnectez-vous pour jouer en ligne."
        case .roomNotFound:     return "Aucun salon trouvé avec ce code."
        case .notMember:        return "Vous ne faites plus partie de ce salon."
        case .notHost:          return "Vous n'animez plus cette partie."
        case .leaseActive:      return "Un autre joueur anime déjà la partie."
        case .badPhase:         return "Action impossible à ce moment de la manche."
        case .notYourSeat:      return "Ce siège n'est pas le vôtre."
        case .notEligible:      return "Vous ne pouvez pas annoncer sur ce board."
        case .badCards:         return "Ces cartes ne sont pas dans votre main."
        case .alreadySubmitted: return "Votre annonce a déjà été enregistrée."
        case .badSubmission:    return "Annonce invalide."
        case .roomFinished:     return "Cette partie est terminée."
        case .codeTaken:        return "Ce code de salon est déjà pris."
        case .badCode:          return "Code de salon invalide."
        case .badState:         return "État de partie invalide."
        case .badStatus:        return "Statut de partie invalide."
        case .codeExhausted:    return "Impossible de générer un code libre. Réessayez."
        case .noSession:        return "Session expirée. Reconnectez-vous pour jouer en ligne."
        case .timedOut:         return "Le serveur ne répond pas. Vérifiez votre connexion."
        case .other(let m):     return m
        }
    }
}

// MARK: - Chaos (T24)

/// Profil de perturbation injecté par `-chaos <nom>` (DEBUG). Appliqué DANS le
/// transport, jamais dans la logique de jeu.
struct ChaosProfile: Sendable {
    /// Nom du profil (pour les logs et `summary.json`).
    var name: String
    /// Pourcentage de pings Realtime purement ignorés (0-100).
    var dropPingsPercent: Int = 0
    /// Latence artificielle ajoutée à chaque RPC, en millisecondes.
    var extraLatencyMs: Int = 0
    /// Quand cette phase est vue dans un snapshot : coupe le socket et suspend
    /// le poll pendant N secondes, puis `resync()`.
    var socketKill: (phase: String, seconds: Int)? = nil
    /// Envoie un second `room_publish` concurrent (scénario « double hôte »).
    var duplicatePublish: Bool = false

    static func named(_ name: String) -> ChaosProfile? {
        switch name {
        case "guest-blip-10s":
            return ChaosProfile(name: name, socketKill: (phase: "announcing", seconds: 10))
        case "host-lock-30s":
            return ChaosProfile(name: name, socketKill: (phase: "boardReveal", seconds: 30))
        case "drop-30pct":
            return ChaosProfile(name: name, dropPingsPercent: 30)
        case "slow-3s":
            return ChaosProfile(name: name, extraLatencyMs: 3000)
        case "double-host":
            return ChaosProfile(name: name, duplicatePublish: true)
        default:
            return nil
        }
    }
}

// MARK: - Journal (T40 / summary.json)

struct RoomTransportLogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let at: Date
    /// `subscribe_ms`, `resync`, `cas_conflict`, `host_claim`, `rpc_error`, `poll_tick`…
    let event: String
    let detail: String
    let durationMs: Int?

    init(event: String, detail: String = "", durationMs: Int? = nil) {
        self.id = UUID()
        self.at = Date()
        self.event = event
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Ring buffer en mémoire (500 entrées max).
struct RoomTransportLog: Codable, Sendable {
    static let capacity = 500
    private(set) var entries: [RoomTransportLogEntry] = []

    mutating func append(_ entry: RoomTransportLogEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Compteurs agrégés, directement exploitables par `summary.json`.
    var counters: [String: Int] {
        var result: [String: Int] = [:]
        for e in entries { result[e.event, default: 0] += 1 }
        return result
    }
}

// MARK: - Transport

@MainActor
final class RoomTransport: ObservableObject {

    /// État de connexion exposé à l'UI.
    enum ConnectionState: String, Sendable {
        case connected
        case reconnecting
        case offline
    }

    // MARK: Publié

    @Published private(set) var connectionState: ConnectionState = .offline
    /// Dernière enveloppe reçue (version la plus haute connue).
    @Published private(set) var latest: RoomEnvelope?
    /// Journal de diagnostic (ring buffer).
    @Published private(set) var journal = RoomTransportLog()

    /// Appelé à chaque `room_heartbeat` réussi (poll). Sert au bail d'hôte et à
    /// la présence côté service.
    var onHeartbeat: ((RoomHeartbeat) -> Void)?

    // MARK: Configuration

    /// Intervalle de poll en lobby / en partie (configurable pour les tests).
    var lobbyPollInterval: TimeInterval = 2
    var gamePollInterval: TimeInterval = 5
    /// Timeouts (secondes).
    var rpcTimeout: TimeInterval = 15
    var subscribeTimeout: TimeInterval = 30

    // MARK: Interne

    let client: SupabaseClient
    private(set) var chaos: ChaosProfile?

    /// File d'écritures sérialisée (une seule opération réseau en vol).
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var code: String?
    private var channel: RealtimeChannelV2?
    private var pingTask: Task<Void, Never>?
    private var channelStatusTask: Task<Void, Never>?
    private var clientStatusTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var chaosKillTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    private var pollSuspended = false
    private var chaosKillArmed = true

    /// Version la plus haute déjà émise — protège des relectures désordonnées.
    private var lastEmittedVersion: Int64 = 0
    /// Continuations des flux `snapshots` (plusieurs consommateurs possibles).
    private var snapshotContinuations: [UUID: AsyncStream<RoomEnvelope>.Continuation] = [:]

    private var channelStatus: RealtimeChannelStatus = .unsubscribed
    private var socketStatus: RealtimeClientStatus = .disconnected

    // MARK: Init

    /// `client` nil = client partagé de l'app. Injectable pour les bots QA et
    /// les tests à plusieurs identités (chacun son `SupabaseClient`).
    init(client: SupabaseClient? = nil, chaos: ChaosProfile? = nil) {
        self.client = client ?? SupabaseClientProvider.shared
        self.chaos = chaos
    }

    /// Flux ordonné des enveloppes. N'émet que si `version` progresse.
    var snapshots: AsyncStream<RoomEnvelope> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RoomEnvelope>.makeStream()
        snapshotContinuations[id] = continuation
        // On résout la référence faible AVANT le Task : capturer la variable
        // `self` elle-même dans du code concurrent est une erreur en Swift 6.
        continuation.onTermination = { [weak self] _ in
            guard let transport = self else { return }
            Task { @MainActor in
                transport.snapshotContinuations[id] = nil
            }
        }
        return stream
    }

    /// Dump JSON du journal (pour `summary.json` / T40).
    func dumpJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(journal)) ?? Data()
    }

    // MARK: - Cycle de vie

    /// Ouvre le salon : subscribe au channel (ping), démarre le poll et la
    /// surveillance réseau. À appeler APRÈS `create` ou `join`.
    func open(code: String) async throws {
        self.code = code
        await teardownChannel()
        connectionState = .reconnecting

        let ch = client.realtimeV2.channel("room:\(code)")
        self.channel = ch

        // Le ping est un simple signal : on ne décode JAMAIS le record.
        // Les callbacks doivent être posés AVANT `subscribeWithError()`.
        let pingStream = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "online_rooms",
            filter: RealtimePostgresFilter.eq("code", value: code)
        )
        pingTask = Task { [weak self] in
            for await action in pingStream {
                if Task.isCancelled { return }
                // Le heartbeat de l'hôte renouvelle le bail toutes les 5 s sans
                // changer `version` : on ne relit que si la version a bougé.
                let recordVersion = action.record["version"]?.intValue.map { Int64($0) }
                await self?.handlePing(recordVersion: recordVersion)
            }
        }

        let channelStatuses = ch.statusChange
        channelStatusTask = Task { [weak self] in
            for await status in channelStatuses {
                if Task.isCancelled { return }
                self?.channelStatus = status
                self?.refreshConnectionState()
            }
        }

        let socketStatuses = client.realtimeV2.statusChange
        clientStatusTask = Task { [weak self] in
            for await status in socketStatuses {
                if Task.isCancelled { return }
                self?.socketStatus = status
                self?.refreshConnectionState()
            }
        }

        let started = Date()
        do {
            try await roomWithTimeout(seconds: subscribeTimeout) {
                try await ch.subscribeWithError()
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            note("subscribe_ms", detail: code, durationMs: ms)
        } catch {
            note("rpc_error", detail: "subscribe: \(error.localizedDescription)")
            // On ne jette pas : le poll seul suffit à faire tourner la partie.
        }

        channelStatus = ch.status
        socketStatus = client.realtimeV2.status
        refreshConnectionState()

        startPolling()
        startPathMonitor()
    }

    /// Ferme tout : channel, poll, monitor réseau.
    func close() async {
        pollTask?.cancel(); pollTask = nil
        chaosKillTask?.cancel(); chaosKillTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
        await teardownChannel()
        code = nil
        latest = nil
        lastEmittedVersion = 0
        connectionState = .offline
        for (_, c) in snapshotContinuations { c.finish() }
        snapshotContinuations.removeAll()
    }

    private func teardownChannel() async {
        pingTask?.cancel(); pingTask = nil
        channelStatusTask?.cancel(); channelStatusTask = nil
        clientStatusTask?.cancel(); clientStatusTask = nil
        if let ch = channel {
            await ch.unsubscribe()
            await client.realtimeV2.removeChannel(ch)
        }
        channel = nil
        channelStatus = .unsubscribed
    }

    /// Re-synchronisation complète : reconnecte le socket si besoin, rejoint le
    /// channel s'il n'est plus `subscribed`, relit `room_get`, relance le poll.
    func resync() async {
        guard let code else { return }
        note("resync", detail: code)
        connectionState = .reconnecting
        pollSuspended = false

        if client.realtimeV2.status != .connected {
            await client.realtimeV2.connect()
        }
        if let ch = channel, ch.status != .subscribed {
            await ch.unsubscribe()
            do {
                try await roomWithTimeout(seconds: subscribeTimeout) {
                    try await ch.subscribeWithError()
                }
            } catch {
                note("rpc_error", detail: "resubscribe: \(error.localizedDescription)")
            }
        } else if channel == nil {
            try? await open(code: code)
            return
        }

        channelStatus = channel?.status ?? .unsubscribed
        socketStatus = client.realtimeV2.status
        refreshConnectionState()

        _ = try? await refreshNow()
        startPolling()
    }

    /// Relit `room_get` maintenant et émet si la version a progressé.
    @discardableResult
    func refreshNow() async throws -> RoomEnvelope {
        guard let code else { throw RoomError.roomNotFound }
        let env = try await get(code: code)
        return env
    }

    // MARK: - RPC typés

    /// `p_code` nil = code tiré au sort par le serveur. Les trois paramètres
    /// sont TOUJOURS envoyés nommés, `null` explicite compris (piège PGRST202).
    func create(code: String?, displayName: String, state: OnlineRoom) async throws -> RoomEnvelope {
        struct Params: Encodable {
            let p_code: String?
            let p_display_name: String
            let p_state: OnlineRoom

            enum CodingKeys: String, CodingKey { case p_code, p_display_name, p_state }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_code, forKey: .p_code)   // encode `null`, pas d'omission
                try c.encode(p_display_name, forKey: .p_display_name)
                try c.encode(p_state, forKey: .p_state)
            }
        }
        let env: RoomEnvelope = try await rpc(
            "room_create",
            params: Params(p_code: code, p_display_name: displayName, p_state: state)
        )
        ingest(env)
        return env
    }

    func join(code: String, displayName: String) async throws -> RoomEnvelope {
        struct Params: Encodable {
            let p_code: String
            let p_display_name: String
        }
        let env: RoomEnvelope = try await rpc(
            "room_join",
            params: Params(p_code: code, p_display_name: displayName)
        )
        ingest(env)
        return env
    }

    @discardableResult
    func get(code: String) async throws -> RoomEnvelope {
        struct Params: Encodable { let p_code: String }
        let env: RoomEnvelope = try await rpc("room_get", params: Params(p_code: code))
        ingest(env)
        return env
    }

    func publish(code: String,
                 expectedVersion: Int64,
                 state: OnlineRoom,
                 status: String) async throws -> PublishResult {
        struct Params: Encodable {
            let p_code: String
            let p_expected_version: Int64
            let p_state: OnlineRoom
            let p_status: String
        }
        let params = Params(p_code: code, p_expected_version: expectedVersion,
                            p_state: state, p_status: status)
        #if DEBUG
        if chaos?.duplicatePublish == true, let payload = try? anyJSON(from: params) {
            // Scénario « double hôte » : un second publish concurrent avec la
            // même version attendue — l'un des deux doit repartir en conflit.
            let client = self.client
            Task.detached {
                _ = try? await client.rpc("room_publish", params: payload).execute()
            }
        }
        #endif
        let result: PublishResult = try await rpc("room_publish", params: params)
        if result.conflict {
            note("cas_conflict", detail: "expected=\(expectedVersion) server=\(result.room.version)")
        }
        ingest(result.room)
        return result
    }

    func submit(code: String, seat: Int, submission: BoardSubmission) async throws -> RoomEnvelope {
        struct Params: Encodable {
            let p_code: String
            let p_seat: Int
            let p_submission: BoardSubmission
        }
        let env: RoomEnvelope = try await rpc(
            "room_submit",
            params: Params(p_code: code, p_seat: seat, p_submission: submission)
        )
        ingest(env)
        return env
    }

    func setSpectator(code: String, seat: Int, wants: Bool) async throws -> RoomEnvelope {
        struct Params: Encodable {
            let p_code: String
            let p_seat: Int
            let p_wants: Bool
        }
        let env: RoomEnvelope = try await rpc(
            "room_set_spectator",
            params: Params(p_code: code, p_seat: seat, p_wants: wants)
        )
        ingest(env)
        return env
    }

    func claimHost(code: String) async throws -> RoomEnvelope {
        struct Params: Encodable { let p_code: String }
        let env: RoomEnvelope = try await rpc("room_claim_host", params: Params(p_code: code))
        note("host_claim", detail: code)
        ingest(env)
        return env
    }

    @discardableResult
    func heartbeat(code: String) async throws -> RoomHeartbeat {
        struct Params: Encodable { let p_code: String }
        let hb: RoomHeartbeat = try await rpc("room_heartbeat", params: Params(p_code: code))
        return hb
    }

    func leaveRoom(code: String) async throws {
        struct Params: Encodable { let p_code: String }
        _ = try await rpcRaw("room_leave", params: Params(p_code: code))
    }

    // MARK: - Plomberie RPC

    /// Appelle un RPC dans la file sérialisée, avec timeout, chaos et mapping
    /// d'erreur. Le décodage utilise le décodeur Supabase (dates Postgres).
    private func rpc<T: Decodable>(_ fn: String, params: some Encodable) async throws -> T {
        let data = try await rpcRaw(fn, params: params)
        do {
            return try PostgrestClient.Configuration.jsonDecoder.decode(T.self, from: data)
        } catch {
            note("rpc_error", detail: "\(fn): décodage \(error)")
            throw RoomError.other("Réponse illisible du serveur (\(fn)).")
        }
    }

    /// Les paramètres sont convertis en `AnyJSON` (Sendable) AVANT de franchir
    /// la frontière de tâche du timeout — sinon leur conformance `Encodable`,
    /// isolée au MainActor par défaut dans ce projet, ne passe pas.
    private func anyJSON(from params: some Encodable) throws -> AnyJSON {
        let data = try PostgrestClient.Configuration.jsonEncoder.encode(params)
        return try JSONDecoder().decode(AnyJSON.self, from: data)
    }

    @discardableResult
    private func rpcRaw(_ fn: String, params: some Encodable) async throws -> Data {
        let client = self.client
        let timeout = rpcTimeout
        let latency = chaos?.extraLatencyMs ?? 0
        do {
            let payload = try anyJSON(from: params)
            await acquireWriteSlot()
            defer { releaseWriteSlot() }
            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency) * 1_000_000)
            }
            return try await roomWithTimeout(seconds: timeout) {
                try await client.rpc(fn, params: payload).execute().data
            }
        } catch {
            let mapped = RoomError.from(error)
            note("rpc_error", detail: "\(fn): \(mapped)")
            throw mapped
        }
    }

    /// Attend que l'écriture précédente soit terminée (file sérialisée).
    private func acquireWriteSlot() async {
        while isWriting {
            await withCheckedContinuation { continuation in
                writeWaiters.append(continuation)
            }
        }
        isWriting = true
    }

    private func releaseWriteSlot() {
        isWriting = false
        if !writeWaiters.isEmpty {
            writeWaiters.removeFirst().resume()
        }
    }

    // MARK: - Ingestion / émission

    /// Prend en compte une enveloppe : n'émet que si la version progresse.
    private func ingest(_ env: RoomEnvelope) {
        guard env.version > lastEmittedVersion else { return }
        lastEmittedVersion = env.version
        latest = env
        for (_, c) in snapshotContinuations { c.yield(env) }
        applyChaosOnSnapshot(env)
    }

    // MARK: - Ping Realtime

    private func handlePing(recordVersion: Int64?) async {
        if let percent = chaos?.dropPingsPercent, percent > 0,
           Int.random(in: 0..<100) < percent {
            note("poll_tick", detail: "ping ignoré (chaos \(chaos?.name ?? "?"))")
            return
        }
        guard let code, !pollSuspended else { return }
        // Version connue et pas plus récente → c'est un simple renouvellement
        // de bail, rien à relire.
        if let recordVersion, recordVersion <= lastEmittedVersion { return }
        _ = try? await get(code: code)
    }

    // MARK: - Poll (room_heartbeat)

    private func startPolling() {
        pollTask?.cancel()
        guard let code else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.currentPollInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                if self.pollSuspended { continue }
                await self.pollOnce(code: code)
            }
        }
    }

    private func currentPollInterval() -> TimeInterval {
        (latest?.status == "playing") ? gamePollInterval : lobbyPollInterval
    }

    private func pollOnce(code: String) async {
        do {
            let hb = try await heartbeat(code: code)
            note("poll_tick", detail: "v\(hb.version)")
            onHeartbeat?(hb)
            if hb.version > lastEmittedVersion {
                _ = try? await get(code: code)
            }
            if connectionState != .connected, channelStatus == .subscribed {
                refreshConnectionState()
            }
        } catch {
            // Erreur déjà journalisée par rpcRaw. Le poll continue.
            if connectionState == .connected { connectionState = .reconnecting }
        }
    }

    // MARK: - État de connexion

    private func refreshConnectionState() {
        let newValue: ConnectionState
        if !lastPathSatisfied {
            newValue = .offline
        } else {
            switch (socketStatus, channelStatus) {
            case (.connected, .subscribed): newValue = .connected
            case (.disconnected, _):        newValue = .reconnecting
            default:                        newValue = .reconnecting
            }
        }
        if newValue != connectionState { connectionState = newValue }
    }

    // MARK: - Réseau (T21)

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                let wasUnsatisfied = !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                self.refreshConnectionState()
                if satisfied && wasUnsatisfied {
                    self.note("resync", detail: "réseau revenu")
                    await self.resync()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.bakarat.room-path-monitor"))
    }

    // MARK: - Chaos (T24)

    private func applyChaosOnSnapshot(_ env: RoomEnvelope) {
        #if DEBUG
        guard let chaos, let kill = chaos.socketKill, chaosKillArmed else { return }
        guard env.state.gameState?.phase.rawValue == kill.phase else { return }
        chaosKillArmed = false
        note("resync", detail: "chaos \(chaos.name) : socket coupé \(kill.seconds)s en \(kill.phase)")
        pollSuspended = true
        client.realtimeV2.disconnect()
        connectionState = .offline
        chaosKillTask?.cancel()
        chaosKillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(kill.seconds) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pollSuspended = false
            await self.resync()
        }
        #endif
    }

    // MARK: - Journal

    private func note(_ event: String, detail: String = "", durationMs: Int? = nil) {
        journal.append(RoomTransportLogEntry(event: event, detail: detail, durationMs: durationMs))
        #if DEBUG
        print("[RoomTransport] \(event) \(detail)")
        QALog.write("[RoomTransport] \(event) \(detail)")
        #endif
    }
}

// MARK: - Timeout

/// Exécute `operation` avec un timeout dur. `T` est toujours `Data` ou `Void`
/// ici : la frontière de tâche n'a donc jamais à transporter de type isolé.
nonisolated func roomWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RoomError.timedOut
        }
        guard let first = try await group.next() else { throw RoomError.timedOut }
        group.cancelAll()
        return first
    }
}

// MARK: - Timestamps Postgres

/// Postgres renvoie des `timestamptz` en ISO 8601 avec offset
/// (`2026-09-25T10:00:00.123456+00:00`). On parse nous-mêmes plutôt que de
/// dépendre d'une stratégie de décodage : c'est le format le plus variable.
nonisolated enum PostgresTimestamp {
    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }

        // Variante sans fuseau (timestamp sans time zone) → on suppose UTC.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ssZ",
                       "yyyy-MM-dd HH:mm:ss"] {
            fallback.dateFormat = format
            if let d = fallback.date(from: raw) { return d }
        }
        return nil
    }

    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

extension KeyedDecodingContainer {
    /// Décode un timestamp Postgres, en tolérant string ISO ou epoch numérique.
    func decodePostgresDate(forKey key: Key) throws -> Date? {
        guard contains(key) else { return nil }
        if (try? decodeNil(forKey: key)) == true { return nil }
        if let s = try? decode(String.self, forKey: key) {
            return PostgresTimestamp.parse(s)
        }
        if let n = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }
}
