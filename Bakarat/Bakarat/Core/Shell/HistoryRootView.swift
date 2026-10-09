//
//  HistoryRootView.swift
//  Bakarat
//
//  Tab 2 "Comptes" — carnet de comptes complet, axé sur le solde :
//   • Section "Dettes en cours" en haut (cachée si rien à régler) : bilan
//     net + chips Tu dois / On te doit + agrégat par joueur (tap → push
//     PlayerDebtDetailView pour gérer le marquage payé).
//   • Section "Mes parties" : liste UNIFIÉE des sessions (compteurs locaux
//     SwiftData + sessions cloud où je suis participant — online ou
//     compteurs partagés par un autre host). Déduplique sur cloudGameId.
//
//  Pas de bouton + ici : la création se fait dans le tab "Play" (qui est
//  la seule entrée). Pas de "Rejoindre via code" non plus — le partage
//  de compteur passe par lien, et la création de partie online aussi
//  depuis Play.
//

import SwiftUI
import SwiftData

// MARK: - Routes & rows

enum SessionRoute: Hashable {
    case localCounter(UUID)         // counter.id (SwiftData)
    case cloudSession(UUID)         // games.id (cloud-only)
    case playerDebt(UUID)           // otherUserId (push aggregate detail)
}

enum UnifiedSessionRow: Identifiable, Hashable {
    case local(Counter)
    case cloud(CloudSession)

    var id: String {
        switch self {
        case .local(let c): return "local-\(c.id.uuidString)"
        case .cloud(let s): return "cloud-\(s.gameId.uuidString)"
        }
    }
    var sortKey: Date {
        switch self {
        case .local(let c): return c.lastUsedAt
        case .cloud(let s): return s.lastActivity
        }
    }

    static func == (lhs: UnifiedSessionRow, rhs: UnifiedSessionRow) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - View

struct HistoryRootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var debts: DebtsService
    @StateObject private var sessionsService = SessionsService()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Counter.lastUsedAt, order: .reverse) private var counters: [Counter]

    @State private var path = NavigationPath()
    /// Row dont l'utilisateur a swipé pour supprimer. On confirme via alert
    /// avant d'appeler le bon flow (local delete / cloud delete / leave).
    @State private var pendingDelete: UnifiedSessionRow? = nil
    @State private var deleteError: String? = nil

    private var currency: String { auth.profile?.currency ?? "EUR" }

    /// Cloud sessions qui n'ont PAS d'équivalent SwiftData local (= compteurs
    /// rejoints via share code par un autre host, ou parties online).
    private var cloudOnly: [CloudSession] {
        let localCloudIds = Set(counters.compactMap { $0.cloudGameId })
        return sessionsService.sessions.filter { !localCloudIds.contains($0.gameId) }
    }

    private var unifiedRows: [UnifiedSessionRow] {
        let local: [UnifiedSessionRow]  = counters.map { .local($0) }
        let cloud: [UnifiedSessionRow]  = cloudOnly.map { .cloud($0) }
        return (local + cloud).sorted { $0.sortKey > $1.sortKey }
    }

    private var showDebtsSection: Bool {
        !debts.perPlayer.isEmpty || abs(debts.net) >= 0.005
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if showDebtsSection {
                    debtsSection
                }
                sessionsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SessionRoute.self) { route in
                switch route {
                case .localCounter(let id):
                    if let c = counters.first(where: { $0.id == id }) {
                        CounterDetailView(counter: c)
                    }
                case .cloudSession(let id):
                    if let s = sessionsService.sessions.first(where: { $0.gameId == id }) {
                        CloudSessionDetailView(session: s)
                    }
                case .playerDebt(let otherId):
                    if let agg = debts.perPlayer.first(where: { $0.otherUserId == otherId }) {
                        PlayerDebtDetailView(aggregate: agg, currency: currency)
                    }
                }
            }
            .refreshable {
                if let uid = auth.userId {
                    await sessionsService.load(myUserId: uid)
                    await debts.load(myUserId: uid)
                }
            }
            .task(id: auth.userId) {
                if let uid = auth.userId {
                    await sessionsService.startLiveUpdates(myUserId: uid)
                }
            }
            .alert(
                Text(pendingDelete.map { confirmTitle(for: $0) } ?? ""),
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { row in
                Button(confirmActionTitle(for: row), role: .destructive) {
                    performPendingDelete()
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { row in
                Text(confirmMessage(for: row))
            }
            .alert("Action unavailable", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: { Text(deleteError ?? "") }
        }
    }

    // MARK: - Dettes section

    @ViewBuilder
    private var debtsSection: some View {
        Section {
            // Hero row — net + chips
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("Net balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(signedAmount(debts.net))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(netColor)
                        .contentTransition(.numericText(value: debts.net))
                        .animation(.snappy, value: debts.net)
                }
                HStack(spacing: 10) {
                    chip(title: "On te doit", amount: debts.totalOwedToMe, color: .green, icon: "arrow.down.left.circle.fill")
                    chip(title: "Tu dois", amount: debts.totalIOwe, color: Theme.systemRed, icon: "arrow.up.right.circle.fill")
                }
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

            // Per-player rows (toutes, ce sont pour la plupart 2-4 lignes)
            ForEach(debts.perPlayer) { agg in
                NavigationLink(value: SessionRoute.playerDebt(agg.otherUserId)) {
                    perPlayerRow(agg)
                }
            }
        } header: {
            Text("Outstanding debts")
        } footer: {
            Text("Tap a row to see per-game detail and mark as paid.")
        }
    }

    private func chip(title: LocalizedStringKey, amount: Double, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            .foregroundStyle(color)
            Text(format(amount))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(amount >= 0.005 ? color : .secondary)
                .contentTransition(.numericText(value: amount))
                .animation(.snappy, value: amount)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func perPlayerRow(_ agg: DebtAggregate) -> some View {
        HStack(spacing: 12) {
            ProfileAvatar(name: agg.displayName, avatarUrl: agg.avatarUrl, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(agg.displayName)
                    .font(.system(size: 16, weight: .semibold))
                let n = agg.contributingGameIds.count
                Text((agg.direction == .iOwe ? String(localized: "You owe them") : String(localized: "Owes you"))
                     + " · " + (n > 1 ? String(localized: "%lld games", defaultValue: "\(n) games") : String(localized: "1 game")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(format(agg.absAmount))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(agg.direction == .iOwe ? Theme.systemRed : .green)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sessions section

    @ViewBuilder
    private var sessionsSection: some View {
        Section {
            if unifiedRows.isEmpty {
                emptySessions
            } else {
                ForEach(unifiedRows) { row in
                    sessionRowLink(row)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = row
                            } label: {
                                Label(swipeLabel(row), systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text("My games")
        } footer: {
            if unifiedRows.isEmpty {
                EmptyView()
            } else {
                Text("Swipe left on a row to remove it. Local counters and games you host are deleted for everyone. Games shared by someone else are only removed from your view.")
            }
        }
    }

    @ViewBuilder
    private func sessionRowLink(_ row: UnifiedSessionRow) -> some View {
        switch row {
        case .local(let c):
            NavigationLink(value: SessionRoute.localCounter(c.id)) {
                CounterRow(counter: c)
            }
        case .cloud(let s):
            NavigationLink(value: SessionRoute.cloudSession(s.gameId)) {
                CloudSessionRow(session: s, currency: currency)
            }
        }
    }

    /// Label du bouton swipe selon le type de row.
    private func swipeLabel(_ row: UnifiedSessionRow) -> String {
        switch row {
        case .local: return "Delete"
        case .cloud: return "Remove"
        }
    }

    private var emptySessions: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No games yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Create a counter or join one from the Play tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: - Delete / leave flow

    private func performPendingDelete() {
        guard let row = pendingDelete else { return }
        pendingDelete = nil
        switch row {
        case .local(let counter):
            modelContext.delete(counter)
            try? modelContext.save()
        case .cloud(let session):
            Task {
                do {
                    // Toujours leave_game maintenant — le revert ne touche
                    // que mes soldes, les autres gardent leur historique +
                    // leurs balances entre eux. Si j'étais owner, la partie
                    // devient orpheline (plus d'édition possible).
                    try await CloudGameActions.leaveGame(gameId: session.gameId)
                    if let uid = auth.userId {
                        await sessionsService.load(myUserId: uid)
                        await debts.load(myUserId: uid)
                    }
                } catch {
                    deleteError = error.localizedDescription
                }
            }
        }
    }

    private func confirmTitle(for row: UnifiedSessionRow) -> String {
        switch row {
        case .local: return "Delete this counter?"
        case .cloud: return "Remove from your history?"
        }
    }

    private func confirmMessage(for row: UnifiedSessionRow) -> String {
        switch row {
        case .local:
            return "All rounds and balances will be removed from this device. This cannot be undone."
        case .cloud:
            return "Your balance contributions in this game will be reverted, and the game will disappear from your history. Other players keep their balances unchanged. This cannot be undone."
        }
    }

    private func confirmActionTitle(for row: UnifiedSessionRow) -> String {
        switch row {
        case .local: return "Delete"
        case .cloud: return "Remove"
        }
    }

    // MARK: - Helpers

    private var netColor: Color {
        if abs(debts.net) < 0.005 { return .secondary }
        return debts.net > 0 ? .green : Theme.systemRed
    }

    private func format(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private func signedAmount(_ amount: Double) -> String {
        let base = format(abs(amount))
        if abs(amount) < 0.005 { return base }
        return amount > 0 ? "+\(base)" : "−\(base)"
    }
}

// MARK: - Local counter row

struct CounterRow: View {
    @EnvironmentObject private var debts: DebtsService
    let counter: Counter

    /// Grisé si la partie cloud associée est entièrement réglée de mon côté.
    /// Les compteurs purement locaux (pas de cloudGameId) ne sont jamais grisés.
    private var isPaid: Bool {
        guard let gid = counter.cloudGameId else { return false }
        return debts.settledGameIds.contains(gid)
    }

    /// Score du host sur ce compteur (somme cumulée de ses deltas). nil si
    /// hostSeatIndex n'est pas défini (compteurs legacy).
    private var hostScore: Double? {
        guard let seat = counter.hostSeatIndex,
              let player = counter.players.first(where: { $0.seat == seat })
        else { return nil }
        return player.score
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(counter.initial)
                .font(.headline)
                .foregroundStyle(Theme.brandRed)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.brandRed.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(counter.name)
                        .font(.subheadline.weight(.semibold))
                    if isPaid {
                        Text("Paid")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(counter.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let score = hostScore {
                Text(formatMoney(score))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(balanceColor(score))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
        .opacity(isPaid ? 0.55 : 1.0)
    }

    private func formatMoney(_ v: Double) -> String {
        let magnitude = Swift.abs(v)
        let formatted = String(format: "%.2f", magnitude) + " \(counter.currency)"
        if magnitude < 0.005 { return formatted }
        return v > 0 ? "+\(formatted)" : "−\(formatted)"
    }

    private func balanceColor(_ v: Double) -> Color {
        if Swift.abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : Theme.systemRed
    }
}

// MARK: - Cloud session row

struct CloudSessionRow: View {
    @EnvironmentObject private var debts: DebtsService
    let session: CloudSession
    let currency: String

    private var isPaid: Bool { debts.settledGameIds.contains(session.gameId) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.mode == "online" ? "gamecontroller.fill" : "list.bullet.clipboard.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.brandRed)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(titleLabel)
                        .font(.subheadline.weight(.semibold))
                    if isPaid {
                        Text("Paid")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatMoney(session.myBalance))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(balanceColor)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .opacity(isPaid ? 0.55 : 1.0)
    }

    private var titleLabel: String {
        if session.mode == "online" { return String(localized: "Partie online") }
        return session.ownerDisplay.map { String(localized: "Compteur · \($0)") } ?? String(localized: "Compteur partagé")
    }

    private var subtitleLabel: String {
        var parts: [String] = []
        parts.append(session.numParticipants > 1
                     ? String(localized: "\(session.numParticipants) joueurs")
                     : String(localized: "1 joueur"))
        if session.numManches > 0 {
            parts.append(session.numManches > 1
                         ? String(localized: "\(session.numManches) manches")
                         : String(localized: "1 manche"))
        }
        parts.append(session.lastActivity.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var balanceColor: Color {
        if abs(session.myBalance) < 0.005 { return .secondary }
        return session.myBalance > 0 ? .green : Theme.systemRed
    }

    private func formatMoney(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        let magnitude = Swift.abs(v)
        let formatted = f.string(from: NSNumber(value: magnitude)) ?? "\(v)"
        if magnitude < 0.005 { return formatted }
        return v > 0 ? "+\(formatted)" : "−\(formatted)"
    }
}

// MARK: - Create sheet

/// Brouillon de joueur dans le formulaire de création. id stable nécessaire
/// pour le drag-to-reorder de SwiftUI (sinon les rows se mélangent).
struct PlayerDraft: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Score initial — utilisé quand on importe un état via collage. 0 sinon.
    var initialScore: Double

    init(id: UUID = UUID(), name: String = "", initialScore: Double = 0) {
        self.id = id
        self.name = name
        self.initialScore = initialScore
    }
}

struct CreateCounterSheet: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Callback appelé avec l'id du Counter nouvellement créé. Le parent
    /// (PlayRootView) s'en sert pour push CounterDetailView après dismiss.
    var onCreated: (UUID) -> Void = { _ in }

    @State private var name = ""
    @State private var linePriceText = "2,5"
    /// Actifs : toujours au moins 1 ligne vide en fin (auto-reveal).
    @State private var actives: [PlayerDraft] = [PlayerDraft()]
    /// PlayerDraft.id du joueur "C'est moi" — bind à mon auth.userId.
    /// Les autres joueurs valides deviennent des placeholders à la création.
    @State private var hostDraftId: UUID? = nil
    @State private var isCommitting = false
    @State private var commitError: String? = nil
    @FocusState private var focusedField: Field?
    @FocusState private var priceFieldFocused: Bool

    enum Field: Hashable {
        case name, player(UUID)
    }

    // Prix : bornes et pas, alignés sur le lobby online.
    private static let minPrice: Double = 0.5
    private static let maxPrice: Double = 50
    private static let priceStep: Double = 0.5

    var body: some View {
        NavigationStack {
            List {
                Section{
                    TextField("Counter name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)

                    HStack {
                        Text("Line price")
                        Spacer()
                        HStack(spacing: 6) {
                            TextField("2,5", text: $linePriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 17, weight: .semibold))
                                .focused($priceFieldFocused)
                                .frame(width: 64)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .onChange(of: linePriceText) { _, new in
                                    sanitizePriceText(new)
                                }
                                .onChange(of: priceFieldFocused) { _, focused in
                                    if !focused { syncPriceTextFromParsed() }
                                }
                            Text("€")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach($actives) { $p in
                        HStack(spacing: 8) {
                            Text("\(playerIndex(p) + 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                                .monospacedDigit()
                            TextField("First name", text: $p.name)
                                .focused($focusedField, equals: .player(p.id))
                                .submitLabel(.next)
                                .onSubmit { focusNext(after: p.id) }
                                .onChange(of: p.name) { _, _ in
                                    ensureTrailingEmpty()
                                    if let hid = hostDraftId,
                                       !validDrafts.contains(where: { $0.id == hid }) {
                                        hostDraftId = nil
                                    }
                                }
                            // Pill "C'est moi" / "Moi" — n'apparait que sur les
                            // rows non-vides. Tap = sélection unique du host.
                            if !p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                                hostPill(draftId: p.id)
                            }
                        }
                    }
                    .onMove(perform: moveActives)
                    .onDelete(perform: deleteActive)
                } header: {
                    Text("Players")
                } footer: {
                    Text("Drag to reorder. Tap “That's me” on your seat. The others become placeholder accounts.")
                }

                if let commitError {
                    Section {
                        Text(commitError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("New counter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await commitAsync() }
                    } label: {
                        HStack(spacing: 6) {
                            if isCommitting { ProgressView().scaleEffect(0.8) }
                            Text(isCommitting ? "Creating..." : "Create")
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCommit || isCommitting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if priceFieldFocused {
                    priceKeyboardBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: priceFieldFocused)
            .onAppear { focusedField = .name }
        }
    }

    // MARK: - Price keyboard bar (style lobby online)

    @ViewBuilder
    private var priceKeyboardBar: some View {
        let cur = parsedLinePrice ?? 2.5
        let canDec = cur > Self.minPrice
        let canInc = cur < Self.maxPrice
        HStack(spacing: 8) {
            Button {
                let new = min(Self.maxPrice, cur + Self.priceStep)
                linePriceText = formatPriceForField(new)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(canInc ? .primary : .secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canInc)

            Button {
                let new = max(Self.minPrice, cur - Self.priceStep)
                linePriceText = formatPriceForField(new)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(canDec ? .primary : .secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canDec)

            Spacer()

            Button {
                syncPriceTextFromParsed()
                priceFieldFocused = false
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.brandRed)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(LiquidGlassPill())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func sanitizePriceText(_ raw: String) {
        var seenSep = false
        var filtered = ""
        for c in raw {
            if c.isNumber {
                filtered.append(c)
            } else if (c == "," || c == ".") && !seenSep {
                seenSep = true
                filtered.append(",")
            }
        }
        if filtered != raw { linePriceText = filtered }
    }

    private func syncPriceTextFromParsed() {
        if let v = parsedLinePrice {
            linePriceText = formatPriceForField(v)
        } else {
            linePriceText = "2,5"
        }
    }

    private func formatPriceForField(_ p: Double) -> String {
        if p.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", p)
        }
        return String(format: "%.1f", p).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Players list management

    private func playerIndex(_ p: PlayerDraft) -> Int {
        actives.firstIndex(where: { $0.id == p.id }) ?? 0
    }

    private func ensureTrailingEmpty() {
        while actives.count > 1,
              actives[actives.count - 1].name.trimmingCharacters(in: .whitespaces).isEmpty,
              actives[actives.count - 2].name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.removeLast()
        }
        if actives.isEmpty || !actives.last!.name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.append(PlayerDraft())
        }
    }

    private func moveActives(from source: IndexSet, to destination: Int) {
        actives.move(fromOffsets: source, toOffset: destination)
        ensureTrailingEmpty()
    }

    private func deleteActive(at offsets: IndexSet) {
        actives.remove(atOffsets: offsets)
        ensureTrailingEmpty()
    }

    private func focusNext(after id: UUID) {
        guard let idx = actives.firstIndex(where: { $0.id == id }) else { return }
        if idx < actives.count - 1 {
            focusedField = .player(actives[idx + 1].id)
        } else {
            ensureTrailingEmpty()
            if let last = actives.last {
                focusedField = .player(last.id)
            }
        }
    }

    // MARK: - Commit

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        validDrafts.count >= 2 &&
        parsedLinePrice != nil &&
        hostDraftId != nil &&
        validDrafts.contains(where: { $0.id == hostDraftId })
    }

    /// Drafts dont le nom n'est PAS vide, dans l'ordre actuel d'actives.
    /// Sert au picker "C'est moi" et au mapping seat = index dans cleanActives.
    private var validDrafts: [PlayerDraft] {
        actives.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var validNamesCount: Int { validDrafts.count }

    private var parsedLinePrice: Double? {
        let normalized = linePriceText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    /// Pill inline "C'est moi" / "Moi" sur une row de joueur. Sélection
    /// unique : tap sur une autre row transfère le host.
    @ViewBuilder
    private func hostPill(draftId: UUID) -> some View {
        let isMe = hostDraftId == draftId
        Button {
            hostDraftId = draftId
        } label: {
            Text(isMe ? "Me" : "That's me")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMe ? .white : Theme.brandRed)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isMe ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    Capsule().stroke(isMe ? Color.clear : Theme.brandRed.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Crée le compteur + les placeholders en cloud pour chaque joueur
    /// non-host. Bloquant jusqu'à fin des RPC pour éviter une création partielle.
    private func commitAsync() async {
        guard canCommit, let price = parsedLinePrice, let hostId = hostDraftId else { return }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanActives = validDrafts
        guard let hostSeat = cleanActives.firstIndex(where: { $0.id == hostId }) else { return }

        isCommitting = true
        commitError = nil
        defer { isCommitting = false }

        // 1) Crée un placeholder côté Supabase pour chaque joueur non-host.
        var placeholders: [Int: UUID] = [:]
        do {
            for (i, p) in cleanActives.enumerated() where i != hostSeat {
                let displayName = p.name.trimmingCharacters(in: .whitespaces)
                let id = try await CounterShareService.createPlaceholder(displayName: displayName)
                placeholders[i] = id
            }
        } catch {
            commitError = "Could not create placeholders: \(error.localizedDescription)"
            return
        }

        // 2) Crée le compteur local avec hostSeatIndex + placeholders mappés.
        let counter = Counter(name: cleanName,
                              linePrice: price,
                              currency: "€",
                              dealerIdx: 0,
                              configured: true)
        counter.hostSeatIndex = hostSeat
        counter.placeholderIdsBySeat = placeholders
        modelContext.insert(counter)

        for (i, p) in cleanActives.enumerated() {
            let player = CounterPlayer(seat: i,
                                       name: p.name.trimmingCharacters(in: .whitespaces),
                                       score: 0,
                                       isActive: true)
            player.counter = counter
            modelContext.insert(player)
        }

        try? modelContext.save()
        // Notifie le parent AVANT dismiss : il pushera CounterDetailView une
        // fois la sheet refermée (via onDismiss côté présentation).
        onCreated(counter.id)
        dismiss()
    }
}
