//
//  CloudSessionDetailView.swift
//  Bakarat
//
//  Détail d'une session cloud sans équivalent SwiftData local : parties
//  online que j'ai jouées (host ou guest), ou compteurs partagés par un
//  autre host. Post-game, c'est l'équivalent de BalanceHistorySheet :
//    1. Header card (bilan perso)
//    2. Solde courant par joueur (online uniquement)
//    3. Manches passées (online uniquement, tap → détail avec édition)
//    4. Dettes (settlements)
//    5. Share info
//
//  Toolbar trailing : menu hamburger avec "Modifier les soldes" (host
//  only) + "Copier les comptes". L'édition de soldes est inline (pas de
//  sheet), bar liquid-glass +/- apparaît avec le clavier.
//

import SwiftUI

struct CloudSessionDetailView: View {
    @EnvironmentObject private var debts: DebtsService
    let session: CloudSession

    @State private var actionError: String?
    @StateObject private var editService = OnlineGameEditService()

    // Inline balance edit
    @State private var isEditingBalances = false
    @State private var balanceTexts: [Int: String] = [:]
    @FocusState private var focusedSeat: Int?
    @State private var isSavingBalances = false
    @State private var saveError: String?

    @State private var justCopied = false

    private static let balanceStep: Double = 0.5

    private var gameDebt: GameDebt? {
        debts.perGame.first(where: { $0.gameId == session.gameId })
    }

    private var currency: String { session.currency }

    /// "Modifier les soldes" est dispo pour tout participant à une online game
    /// (côté serveur record_online_adjustment exige juste que les transferts
    /// m'impliquent — backward compat avec les vieux comptes orphelinés).
    /// L'édition de manche (changement de gagnants/multi) reste strictement
    /// owner-only — c'est plus invasif côté game integrity.
    private var canEditBalances: Bool {
        session.mode == "online"
    }
    private var canEditManches: Bool {
        session.mode == "online" && session.iAmOwner
    }

    private var showHistory: Bool {
        session.mode == "online"
    }

    /// Combien de manches max afficher avant le bouton "See all".
    private static let manchesPreviewLimit = 4
    @State private var showAllManches = false

    var body: some View {
        List {
            headerSection

            if let gd = gameDebt, !gd.payments.isEmpty {
                debtsSection(gd)
            }

            if showHistory {
                balancesSection
                manchesSection
            }

            shareInfoSection
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showHistory {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditingBalances {
                        Button(action: commitBalances) {
                            if isSavingBalances { ProgressView() }
                            else { Text("Done").fontWeight(.semibold) }
                        }
                        .tint(Theme.brandRed)
                        .disabled(isSavingBalances)
                    } else {
                        Menu {
                            if canEditBalances {
                                Button {
                                    startEditingBalances()
                                } label: {
                                    Label("Modifier les soldes", systemImage: "pencil")
                                }
                            }
                            Button {
                                copyState()
                            } label: {
                                Label(justCopied ? "Copié !" : "Copier les comptes",
                                      systemImage: justCopied
                                      ? "checkmark.circle.fill"
                                      : "doc.on.clipboard")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(Color.primary)
                        }
                        .tint(.primary)
                        .accessibilityLabel("Options")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditingBalances, focusedSeat != nil {
                balanceKeyboardBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focusedSeat)
        .alert("Action unavailable", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task {
            if showHistory { await editService.load(gameId: session.gameId) }
        }
    }

    private var title: String {
        if session.mode == "online" { return "Online game" }
        if session.iAmOwner { return "Counter" }
        return session.ownerDisplay.map { "\($0)'s counter" } ?? "Shared counter"
    }

    // MARK: - Header section

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: session.mode == "online" ? "gamecontroller.fill" : "list.bullet.clipboard.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.brandRed)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.mode == "online" ? "Online game" : "Counter")
                            .font(.subheadline.weight(.semibold))
                        if !session.iAmOwner, let owner = session.ownerDisplay {
                            Text("Host: \(owner)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if debts.settledGameIds.contains(session.gameId) {
                        Text("Paid")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(spacing: 4) {
                    Text("My balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(formatMoney(session.myBalance))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(balanceColor(session.myBalance))
                        .monospacedDigit()
                    HStack(spacing: 8) {
                        Text("\(session.numManches) round\(session.numManches > 1 ? "s" : "")")
                        Text("·")
                        Text("\(session.numParticipants) player\(session.numParticipants > 1 ? "s" : "")")
                        Text("·")
                        Text(formatPrice(session.linePrice) + "/line")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Balances section (online only)

    @ViewBuilder
    private var balancesSection: some View {
        Section {
            if editService.participants.isEmpty {
                HStack {
                    if editService.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Chargement…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Pas de participants chargés.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(rankedParticipants) { p in
                    balanceRow(p)
                }
            }
        } header: {
            sectionHeader(icon: "creditcard.fill",
                          title: "Solde courant",
                          color: Theme.brandRed)
        } footer: {
            if isEditingBalances {
                Text("Touche un solde pour l'éditer. La barre +/- ajuste le solde focus, Done sauvegarde.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func balanceRow(_ p: OnlineGameParticipant) -> some View {
        let bal = currentBalance(seat: p.seat)
        HStack(spacing: 12) {
            ProfileAvatar(name: p.displayName, avatarUrl: p.avatarUrl, size: 30)
            Text(p.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if isEditingBalances, p.userId != nil {
                balanceEditField(seat: p.seat)
            } else {
                Text(formatMoney(bal))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(balanceColor(bal))
            }
        }
    }

    @ViewBuilder
    private func balanceEditField(seat: Int) -> some View {
        HStack(spacing: 4) {
            TextField("0",
                      text: Binding(
                        get: { balanceTexts[seat] ?? "" },
                        set: { balanceTexts[seat] = $0 }
                      ))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .focused($focusedSeat, equals: seat)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(maxWidth: 100)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            Text("€")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var balanceKeyboardBar: some View {
        HStack(spacing: 8) {
            Button { bumpFocused(by: Self.balanceStep) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }.buttonStyle(.plain)
            Button { bumpFocused(by: -Self.balanceStep) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }.buttonStyle(.plain)
            Spacer()
            Button { focusedSeat = nil } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.brandRed)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(LiquidGlassPill())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func bumpFocused(by delta: Double) {
        guard let seat = focusedSeat else { return }
        let current = parsedBalance(seat: seat) ?? 0
        let next = current + delta
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        balanceTexts[seat] = f.string(from: NSNumber(value: next)) ?? "\(next)"
    }

    // MARK: - Manches section (online only)

    @ViewBuilder
    private var manchesSection: some View {
        Section {
            if editService.manches.isEmpty {
                if editService.isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Chargement…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Aucune manche enregistrée.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                let reversed = Array(editService.manches.reversed())
                let limit = showAllManches ? reversed.count : Self.manchesPreviewLimit
                ForEach(Array(reversed.prefix(limit))) { m in
                    NavigationLink {
                        CloudMancheDetailView(
                            mancheRow: m,
                            editService: editService,
                            isHost: canEditManches,
                            gameId: session.gameId,
                            currency: currency
                        )
                    } label: {
                        mancheRow(m)
                    }
                }
                if !showAllManches, reversed.count > Self.manchesPreviewLimit {
                    Button {
                        withAnimation { showAllManches = true }
                    } label: {
                        HStack {
                            Text("See all (\(reversed.count))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.brandRed)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.brandRed)
                        }
                    }
                }
            }
        } header: {
            sectionHeader(icon: "clock.arrow.circlepath",
                          title: "Manches passées",
                          color: .secondary)
        } footer: {
            if canEditManches, !editService.manches.isEmpty {
                Text("Touche une manche pour voir le détail et modifier les gagnants si besoin.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func mancheRow(_ m: OnlineMancheRow) -> some View {
        let myDelta = session.mySeatIndex.flatMap { m.perSeatDeltas[$0] } ?? 0
        HStack(spacing: 12) {
            Image(systemName: m.isAdjustment ? "slider.horizontal.3" : "rectangle.stack.fill")
                .foregroundStyle(m.isAdjustment ? Color.orange : Theme.brandRed)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.isAdjustment ? "Ajustement" : "Manche \(m.mancheNumber)")
                    .font(.subheadline.weight(.semibold))
                Text(m.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatMoney(myDelta))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(balanceColor(myDelta))
                .monospacedDigit()
        }
    }

    // MARK: - Debts section

    @ViewBuilder
    private func debtsSection(_ gd: GameDebt) -> some View {
        Section {
            ForEach(gd.payments) { p in
                paymentRow(p)
            }
        } header: {
            HStack {
                sectionHeader(icon: "person.2.fill",
                              title: "Dettes",
                              color: .secondary)
                Spacer()
                let unpaid = gd.payments.filter { !$0.isSettled }.count
                if unpaid > 0 {
                    Text("\(unpaid) à régler")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.systemRed.opacity(0.15)))
                        .foregroundStyle(Theme.systemRed)
                } else {
                    Text("Tout réglé")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private func paymentRow(_ p: GamePayment) -> some View {
        let prof = debts.profilesById[p.otherUserId]
        HStack(spacing: 12) {
            ProfileAvatar(name: prof?.display_name ?? "Player", avatarUrl: prof?.avatar_url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(prof?.display_name ?? "Player")
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(p.isSettled, color: .secondary)
                Text(p.direction == .iOwe ? "Tu lui dois" : "Te doit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(format(p.amount))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(p.isSettled ? .secondary : (p.direction == .iOwe ? Theme.systemRed : .green))
                .monospacedDigit()
                .strikethrough(p.isSettled, color: .secondary)
            Button {
                Task { await togglePaid(p) }
            } label: {
                Image(systemName: p.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(p.isSettled ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(p.isSettled ? "Annuler le règlement" : "Marquer comme réglé")
        }
    }

    private func togglePaid(_ p: GamePayment) async {
        do {
            if p.isSettled {
                try await debts.markUnpaid(gameId: p.gameId, otherUserId: p.otherUserId)
            } else {
                try await debts.markPaid(gameId: p.gameId, otherUserId: p.otherUserId)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Share info section

    @ViewBuilder
    private var shareInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(infoTitle).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                Text(infoBody).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var infoTitle: String {
        session.iAmOwner ? "You're the host" : "You're playing"
    }

    private var infoBody: String {
        if session.iAmOwner {
            if session.mode == "online" {
                return "This game is yours. Edit balances or rounds anytime ; the changes recompute the debts."
            }
            return "This counter is yours. Manage it from the Play tab."
        }
        return "This game was shared by \(session.ownerDisplay ?? "the host"). You can settle your debts here."
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(icon: String, title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .foregroundStyle(color)
    }

    // MARK: - Balance edit helpers

    private var rankedParticipants: [OnlineGameParticipant] {
        editService.participants
            .sorted { currentBalance(seat: $0.seat) > currentBalance(seat: $1.seat) }
    }

    private func currentBalance(seat: Int) -> Double {
        editService.manches.reduce(0) { $0 + ($1.perSeatDeltas[seat] ?? 0) }
    }

    private func startEditingBalances() {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        var dict: [Int: String] = [:]
        for p in editService.participants where p.userId != nil {
            let bal = currentBalance(seat: p.seat)
            dict[p.seat] = f.string(from: NSNumber(value: bal)) ?? "\(bal)"
        }
        balanceTexts = dict
        saveError = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingBalances = true
        }
    }

    private func parsedBalance(seat: Int) -> Double? {
        guard let s = balanceTexts[seat] else { return nil }
        let normalized = s
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Double(normalized)
    }

    private func commitBalances() {
        guard !isSavingBalances else { return }
        focusedSeat = nil
        var deltas: [Int: Double] = [:]
        for p in editService.participants where p.userId != nil {
            let old = currentBalance(seat: p.seat)
            let new = parsedBalance(seat: p.seat) ?? old
            let d = new - old
            if abs(d) > 0.001 { deltas[p.seat] = d }
        }
        if deltas.isEmpty {
            withAnimation { isEditingBalances = false }
            return
        }
        isSavingBalances = true
        Task {
            do {
                let transfers = OnlineAdjustmentSheet.pairwiseTransfers(deltas: deltas)
                _ = try await editService.recordAdjustment(
                    gameId: session.gameId,
                    transfers: transfers,
                    perSeatDeltas: deltas
                )
                await editService.load(gameId: session.gameId)
                await MainActor.run {
                    isSavingBalances = false
                    withAnimation { isEditingBalances = false }
                }
            } catch {
                await MainActor.run {
                    isSavingBalances = false
                    saveError = error.localizedDescription
                    actionError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Copy

    private func copyState() {
        var lines: [String] = []
        lines.append("Bakarat · \(session.mode == "online" ? "Online game" : "Counter")")
        lines.append("\(editService.manches.filter { !$0.isAdjustment }.count) manche(s)")
        lines.append("")
        let maxNameLen = editService.participants.map { $0.displayName.count }.max() ?? 0
        for p in rankedParticipants {
            let name = p.displayName.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            lines.append("\(name)   \(formatMoney(currentBalance(seat: p.seat)))")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        withAnimation { justCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    // MARK: - Format helpers

    private func format(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private func formatMoney(_ v: Double) -> String {
        if abs(v) < 0.005 { return format(0) }
        let sign = v > 0 ? "+" : "−"
        return "\(sign)\(format(abs(v)))"
    }

    private func formatPrice(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func balanceColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : Theme.systemRed
    }
}

// MARK: - Cloud manche detail (post-game)
//
// Pendant cloud-only de MancheDetailView : reçoit l'OnlineMancheRow
// directement (pas besoin d'OnlineRoom live). Section gains/pertes
// read-only en haut, section Boards éditable en bas si je suis host.

struct CloudMancheDetailView: View {
    let mancheRow: OnlineMancheRow
    @ObservedObject var editService: OnlineGameEditService
    let isHost: Bool
    let gameId: UUID
    let currency: String

    @State private var editBoards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
    @State private var initialBoards: [OnlineBoardEdit] = []
    @State private var isSaving = false
    @State private var saveError: String?

    private var isDirty: Bool { editBoards != initialBoards }
    private var canSave: Bool { isHost && isDirty && !isSaving }

    var body: some View {
        List {
            gainsPertesSection
            if isHost, !mancheRow.isAdjustment {
                boardsEditSection
            }
            if let err = saveError {
                Section { Text(err).foregroundStyle(.red).font(.footnote) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(mancheRow.isAdjustment ? "Ajustement" : "Manche \(mancheRow.mancheNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isHost, !mancheRow.isAdjustment {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: commit) {
                        if isSaving { ProgressView() }
                        else { Text("Save").fontWeight(.semibold) }
                    }
                    .tint(Theme.brandRed)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Gains / pertes (read-only)

    @ViewBuilder
    private var gainsPertesSection: some View {
        Section {
            ForEach(rankedRows) { row in
                HStack(spacing: 10) {
                    ProfileAvatar(name: row.name, avatarUrl: row.avatarUrl, size: 28)
                    Text(row.name).font(.subheadline.weight(.semibold))
                    if !row.boardsWon.isEmpty {
                        boardsPill(row: row)
                    }
                    Spacer()
                    Text(formatMoney(row.delta))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(row.delta >= 0 ? Color.green : Color.red)
                }
            }
        } header: {
            Text("Gains/pertes")
        }
    }

    @ViewBuilder
    private func boardsPill(row: DeltaRow) -> some View {
        let label = row.boardsWon.map { idx in
            let m = row.boardMultis[idx] ?? 1
            return m > 1 ? "B\(idx + 1)×\(m)" : "B\(idx + 1)"
        }.joined(separator: " ")
        let textColor: Color = row.isFullBoardWinner ? Self.goldDeep : Theme.brandRed
        let bgColor: Color = row.isFullBoardWinner ? Self.goldLight : Theme.brandRed.opacity(0.12)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(bgColor))
    }

    private struct DeltaRow: Identifiable {
        let seat: Int
        let name: String
        let avatarUrl: String?
        let delta: Double
        let boardsWon: [Int]
        let boardMultis: [Int: Int]
        let isFullBoardWinner: Bool
        var id: Int { seat }
    }

    private var rankedRows: [DeltaRow] {
        var wonBy: [Int: [Int]] = [:]
        var multiBy: [Int: Int] = [:]
        for b in mancheRow.boardResults {
            if let w = b.final_winner_seat {
                let boardIdx = b.board_num >= 1 ? b.board_num - 1 : b.board_num
                wonBy[w, default: []].append(boardIdx)
                multiBy[boardIdx] = b.final_multi
            }
        }
        let allWinners = wonBy.keys
        let allBoards = Set(mancheRow.boardResults.compactMap { $0.final_winner_seat })
        let fb: Int? = (allWinners.count == 1 && allBoards.count == 1) ? allWinners.first : nil
        let participants = editService.participants
        var rows: [DeltaRow] = []
        for p in participants {
            let delta = mancheRow.perSeatDeltas[p.seat] ?? 0
            rows.append(DeltaRow(
                seat: p.seat,
                name: p.displayName,
                avatarUrl: p.avatarUrl,
                delta: delta,
                boardsWon: wonBy[p.seat]?.sorted() ?? [],
                boardMultis: multiBy,
                isFullBoardWinner: fb == p.seat
            ))
        }
        return rows.sorted { $0.delta > $1.delta }
    }

    // MARK: - Boards editor

    @ViewBuilder
    private var boardsEditSection: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(Array($editBoards.enumerated()), id: \.element.id) { idx, $b in
                    if idx > 0 { Divider().padding(.vertical, 12) }
                    boardBlock(label: "Board \(idx + 1)", board: $b)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        } header: {
            Text("Boards")
        } footer: {
            Text("Modifie le gagnant et le multi pour recalculer les soldes.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func boardBlock(label: LocalizedStringKey, board: Binding<OnlineBoardEdit>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(editService.participants) { p in
                    cellButton(name: p.displayName,
                               isSelected: board.wrappedValue.winnerSeat == p.seat) {
                        board.wrappedValue.winnerSeat =
                            (board.wrappedValue.winnerSeat == p.seat) ? nil : p.seat
                    }
                }
                cellButton(name: "Abandonné",
                           isSelected: board.wrappedValue.winnerSeat == nil,
                           italic: true) {
                    board.wrappedValue.winnerSeat = nil
                }
            }
            multiPicker(board.multi)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func cellButton(name: String,
                            isSelected: Bool,
                            italic: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .italic(italic)
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Theme.brandRed : Color(.tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.systemGray4).opacity(isSelected ? 0 : 1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiPicker(_ multi: Binding<OnlineMulti>) -> some View {
        HStack(spacing: 6) {
            ForEach(OnlineMulti.allCases) { m in
                Button {
                    multi.wrappedValue = m
                } label: {
                    Text(m.displayLabel)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(multi.wrappedValue == m ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(multi.wrappedValue == m ? Theme.brandRed : Color(.tertiarySystemBackground))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Load / commit

    private func load() {
        var newBoards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
        for br in mancheRow.boardResults {
            let raw = br.board_num
            let idx: Int = (1...3).contains(raw) ? raw - 1 : raw
            guard (0...2).contains(idx) else { continue }
            newBoards[idx].winnerSeat = br.final_winner_seat
            newBoards[idx].multi = OnlineMulti.from(br.final_multi)
        }
        editBoards = newBoards
        initialBoards = newBoards
        saveError = nil
    }

    private func commit() {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                let raws: [BoardResultRaw] = editBoards.map { b in
                    BoardResultRaw(
                        board_num: b.id + 1,
                        winner_seat: b.winnerSeat,
                        final_winner_seat: b.winnerSeat,
                        multi: b.multi.rawValue,
                        final_multi: b.multi.rawValue,
                        is_split: false,
                        splitter_seats: []
                    )
                }
                let fb = detectedFullBoardSeat()
                let activeSeats = editService.participants.map { $0.seat }
                let deltas = EditOnlineMancheSheet.computeDeltas(
                    boards: editBoards,
                    activeSeats: activeSeats,
                    linePrice: editService.linePrice,
                    fullBoardSeat: fb
                )
                try await editService.updateManche(
                    mancheId: mancheRow.id,
                    boardResults: raws,
                    fullBoardSeat: fb,
                    perSeatDeltas: deltas
                )
                await editService.load(gameId: gameId)
                await MainActor.run {
                    isSaving = false
                    initialBoards = editBoards
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Erreur : \(error.localizedDescription)"
                }
            }
        }
    }

    private func detectedFullBoardSeat() -> Int? {
        let winners = editBoards.compactMap { $0.winnerSeat }
        guard winners.count == 3 else { return nil }
        return Set(winners).count == 1 ? winners.first : nil
    }

    // MARK: - Format

    private func formatMoney(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        let str = f.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        if abs(v) < 0.001 { return str }
        return v > 0 ? "+\(str)" : "−\(str)"
    }

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
    fileprivate static let goldLight = Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.35)
}
