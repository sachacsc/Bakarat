//
//  PlayRootView.swift
//  Bakarat
//
//  Tab 1 "Play" — page d'accueil unique : deux sections d'actions empilées,
//  En ligne d'abord (action principale), puis Compteur (table physique) avec
//  une couleur plus neutre pour la différencier. Une petite section
//  "Dernières sessions" en bas montre 2-3 parties récentes (tous modes).
//
//  Note UX :
//   • "Compteur" → seulement "Créer". Pas de "Rejoindre via code" : le
//     compteur est créé par l'hôte qui le partage ensuite via un lien.
//   • "En ligne" → Créer + Rejoindre via code (4 chars).
//
//  L'historique complet + dettes : tab "Comptes". Profil : tab "Profil".
//

import SwiftUI
import SwiftData

enum PlayRoute: Hashable {
    case localCounter(UUID)
    case cloudSession(UUID)
    case onlineLobby
    case onlineEnterCode
}

/// Wrapper Identifiable pour `.sheet(item:)` quand on n'a qu'une String.
private struct JoinPrefilledCode: Identifiable {
    let code: String
    var id: String { code }
}

struct PlayRootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var debts: DebtsService
    @EnvironmentObject private var deepLink: DeepLinkRouter
    @StateObject private var sessionsService = SessionsService()
    @StateObject private var onlineService = OnlineGameService()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Counter.lastUsedAt, order: .reverse) private var counters: [Counter]

    @State private var path = NavigationPath()
    @State private var showingCreateCounter = false
    /// Code rempli quand on ouvre via deep link bakarat://join/XYZ.
    /// Présente JoinByCodeSheet avec le code pré-rempli.
    @State private var pendingJoinCounterCode: String? = nil
    /// Id du Counter créé via CreateCounterSheet — consommé dans onDismiss
    /// du sheet pour push le détail (redirect direct sur le compteur neuf).
    @State private var pendingCounterPush: UUID? = nil
    @State private var joinCodeOnline: String = ""
    /// Code du dernier salon (UserDefaults, < 2 h) dont `room_heartbeat` a
    /// répondu : on propose de le reprendre.
    @State private var resumableCode: String? = nil
    @State private var isCreatingGame = false
    /// Garde-fou : le hook `-autoJoinCode` ne doit jouer qu'une fois.
    @State private var didAutoJoin = false

    private var currency: String { auth.profile?.currency ?? "EUR" }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            List {
                onlineSection
                if let code = resumableCode {
                    resumeSection(code)
                }
                counterSection
                recentSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandLogo(size: 30)
                }
            }
            .navigationDestination(for: PlayRoute.self) { route in
                switch route {
                case .localCounter(let id):
                    if let c = counters.first(where: { $0.id == id }) {
                        CounterDetailView(counter: c)
                    }
                case .cloudSession(let id):
                    if let s = sessionsService.sessions.first(where: { $0.gameId == id }) {
                        CloudSessionDetailView(session: s)
                    }
                case .onlineLobby:
                    OnlineLobbyView(service: onlineService)
                case .onlineEnterCode:
                    OnlineJoinView(
                        code: $joinCodeOnline,
                        errorMessage: onlineService.lastError
                    ) {
                        Task { await joinOnlineGame() }
                    } onCodeChange: {
                        if onlineService.lastError != nil { onlineService.lastError = nil }
                    }
                }
            }
            .sheet(item: Binding(
                get: { pendingJoinCounterCode.map { JoinPrefilledCode(code: $0) } },
                set: { newValue in pendingJoinCounterCode = newValue?.code }
            )) { wrapper in
                JoinByCodeSheet(prefilledCode: wrapper.code)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: deepLink.pendingJoinCode) { _, newCode in
                guard let code = newCode else { return }
                pendingJoinCounterCode = code
                // Consomme tout de suite côté router pour ne pas re-trigger.
                deepLink.pendingJoinCode = nil
            }
            .sheet(isPresented: $showingCreateCounter, onDismiss: {
                if let id = pendingCounterPush {
                    pendingCounterPush = nil
                    path.append(PlayRoute.localCounter(id))
                }
            }) {
                CreateCounterSheet(onCreated: { id in
                    pendingCounterPush = id
                })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: path.count) { _, newCount in
                guard newCount == 0 else { return }
                resumableCode = OnlineGameService.rememberedRoomCode()
            }
            .task(id: auth.userId) {
                if let uid = auth.userId {
                    await sessionsService.startLiveUpdates(myUserId: uid)
                }
                await bootstrapOnlineEntry()
            }
            .refreshable {
                if let uid = auth.userId {
                    await sessionsService.load(myUserId: uid)
                    await debts.load(myUserId: uid)
                }
            }
        }
    }

    // MARK: - Compteur (cartes physiques)

    @ViewBuilder
    private var counterSection: some View {
        Section {
            Button {
                showingCreateCounter = true
            } label: {
                actionRow(
                    title: "Create a counter",
                    subtitle: "You play with real cards",
                    icon: "list.bullet.clipboard.fill",
                    tint: Theme.brandRed,
                    primary: false
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        } header: {
            Text("Counter")
        }
    }

    // MARK: - Online (simulation)

    @ViewBuilder
    private var onlineSection: some View {
        Section {
            Button {
                Task { await createOnlineGame() }
            } label: {
                actionRow(
                    title: isCreatingGame ? "Creating room..." : "Create a game",
                    subtitle: "Cards are dealt virtually",
                    icon: "plus.circle.fill",
                    tint: Theme.brandRed,
                    primary: true
                )
            }
            .buttonStyle(.plain)
            .disabled(isCreatingGame)
            .listRowBackground(Theme.brandGradient)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .listRowSeparator(.hidden)

            Button {
                path.append(PlayRoute.onlineEnterCode)
            } label: {
                actionRow(
                    title: "Join a game",
                    subtitle: "Enter the host's 4-character code",
                    icon: "arrow.right.circle.fill",
                    tint: Theme.brandRed,
                    primary: false
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        } header: {
            Text("Online")
        }
    }

    // MARK: - Action row (CTA réutilisé pour les deux sections)

    @ViewBuilder
    private func actionRow(title: String, subtitle: String, icon: String, tint: Color, primary: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(primary ? .white : tint)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(primary
                              ? Color.white.opacity(0.18)
                              : tint.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(primary ? .white : Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(primary ? .white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(primary ? Color.white.opacity(0.7) : Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }

    // MARK: - Reprise d'un salon (online only)

    /// Bannière « Reprendre le salon XXXX ». Le code vient de `UserDefaults`
    /// (< 2 h) : on rejoint par `room_join`, et si le bail de l'ancien hôte est
    /// expiré, `room_claim_host` nous rendra l'animation automatiquement.
    @ViewBuilder
    private func resumeSection(_ code: String) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.brandRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reprendre le salon")
                        .font(.subheadline.weight(.semibold))
                    Text("Code \(code)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await resumeOnlineGame(code) }
                } label: {
                    Text("Reprendre")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.brandRed))
                }
                .buttonStyle(.plain)
                Button {
                    OnlineGameService.forgetRoom()
                    resumableCode = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .listRowSeparator(.hidden)
        } header: {
            Text("Reprise")
        }
    }

    // MARK: - Dernières sessions (2-3 max, tous modes confondus)

    /// 3 lignes max : on prend les sessions cloud les plus récentes (online +
    /// compteurs partagés) ET le compteur local le plus récent, triées par
    /// date d'activité.
    private var lastSessions: [UnifiedSessionRow] {
        let localCloudIds = Set(counters.compactMap { $0.cloudGameId })
        let cloudOnly = sessionsService.sessions.filter { !localCloudIds.contains($0.gameId) }
        let lastLocalCounter = counters.first.map { UnifiedSessionRow.local($0) }
        let cloudRows: [UnifiedSessionRow] = cloudOnly.prefix(3).map { .cloud($0) }
        var all: [UnifiedSessionRow] = cloudRows
        if let l = lastLocalCounter { all.append(l) }
        return all.sorted { $0.sortKey > $1.sortKey }.prefix(3).map { $0 }
    }

    @ViewBuilder
    private var recentSection: some View {
        Section {
            if lastSessions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tertiary)
                    Text("Your games will appear here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                ForEach(lastSessions) { row in
                    switch row {
                    case .local(let c):
                        NavigationLink(value: PlayRoute.localCounter(c.id)) {
                            CounterRow(counter: c)
                        }
                    case .cloud(let s):
                        NavigationLink(value: PlayRoute.cloudSession(s.gameId)) {
                            CloudSessionRow(session: s, currency: currency)
                        }
                    }
                }
            }
        } header: {
            Text("Recent sessions")
        }
    }

    // MARK: - Online actions

    /// Au premier affichage : hook `-autoJoinCode` (DEBUG), sinon on vérifie
    /// qu'un salon mémorisé (< 2 h) répond encore avant de proposer la reprise.
    private func bootstrapOnlineEntry() async {
        guard auth.userId != nil else { return }
        if let code = QALaunchOptions.autoJoinCode, !didAutoJoin {
            didAutoJoin = true
            joinCodeOnline = code
            await joinOnlineGame()
            return
        }
        if QALaunchOptions.autoCreateRoom, !didAutoJoin {
            didAutoJoin = true
            await createOnlineGame()
            return
        }
        guard resumableCode == nil, onlineService.room == nil else { return }
        guard let code = OnlineGameService.rememberedRoomCode() else { return }
        // On ne propose la reprise que si le salon répond encore.
        do {
            _ = try await onlineService.transport.heartbeat(code: code)
            resumableCode = code
        } catch {
            OnlineGameService.forgetRoom()
        }
    }

    private func createOnlineGame() async {
        guard !isCreatingGame, let uid = auth.userId else { return }
        isCreatingGame = true
        defer { isCreatingGame = false }
        await onlineService.createRoom(myUserId: uid, myDisplayName: displayName())
        guard let code = onlineService.room?.code else { return }
        path.append(PlayRoute.onlineLobby)
        #if DEBUG
        QABotRunner.shared.startIfNeeded(code: code)
        #endif
    }

    private func joinOnlineGame() async {
        guard let uid = auth.userId else { return }
        let ok = await onlineService.joinRoom(
            code: joinCodeOnline,
            myUserId: uid,
            myDisplayName: displayName()
        )
        guard ok, onlineService.room != nil else { return }
        joinCodeOnline = ""
        resumableCode = nil
        path.append(PlayRoute.onlineLobby)
    }

    /// Reprise = simple `room_join` sur le code mémorisé. Si le bail de l'hôte
    /// précédent est expiré, `room_claim_host` nous rendra l'animation ; sinon
    /// on reste guest le temps que le bail tombe.
    private func resumeOnlineGame(_ code: String) async {
        guard let uid = auth.userId else { return }
        let ok = await onlineService.joinRoom(code: code,
                                              myUserId: uid,
                                              myDisplayName: displayName())
        guard ok, onlineService.room != nil else {
            OnlineGameService.forgetRoom()
            resumableCode = nil
            return
        }
        resumableCode = nil
        path.append(PlayRoute.onlineLobby)
    }

    private func displayName() -> String {
        if let n = auth.profile?.displayName, !n.isEmpty { return n }
        if let e = auth.userEmail, let local = e.split(separator: "@").first { return String(local) }
        return "Joueur"
    }
}
