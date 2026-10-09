//
//  BalanceHistorySheet.swift
//  Bakarat
//
//  Sheet présenté depuis la toolbar de l'écran de jeu (haut à droite).
//  Deux sections nettes :
//    1. Solde courant de TOUS les joueurs (actifs + inactifs greyed out)
//    2. Historique des gains/pertes du JOUEUR COURANT, une row par manche.
//       Chaque row est cliquable → MancheDetailView pour voir les deltas
//       de tous les joueurs sur cette manche.
//

import SwiftUI

struct BalanceHistorySheet: View {
    @EnvironmentObject private var auth: AuthService
    let room: OnlineRoom
    /// L'utilisateur courant est l'hôte → débloque "Modifier les soldes" dans
    /// le menu et "Modifier" sur le détail d'une manche, plus "Exclure" via
    /// long-press sur les rows.
    var isHost: Bool = false
    /// Callback déclenché par le context-menu "Exclure" (seat à kick).
    var onKick: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// Feedback temporaire après copie du solde dans le presse-papier.
    @State private var justCopiedBalance = false
    /// Confirmation d'exclusion (host) avant d'envoyer le kick.
    @State private var kickConfirm: (seat: Int, name: String)? = nil
    /// Service cloud chargé à l'ouverture pour permettre Modifier (soldes + manche).
    @StateObject private var editService = OnlineGameEditService()
    /// Mode édition inline des soldes (host only). Le bouton menu devient
    /// "Done" et chaque row de solde devient un TextField focusable.
    @State private var isEditingBalances = false
    @State private var balanceTexts: [Int: String] = [:]
    @FocusState private var focusedSeat: Int?
    @State private var isSavingBalances = false
    @State private var saveError: String?

    private static let balanceStep: Double = 0.5

    var body: some View {
        NavigationStack {
            List {
                balancesSection
                myHistorySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Solde & historique")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                        .tint(Theme.brandRed)
                        .disabled(isEditingBalances)
                }
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
                            if isHost, room.cloudGameId != nil {
                                Button {
                                    startEditingBalances()
                                } label: {
                                    Label("Modifier les soldes", systemImage: "pencil")
                                }
                            }
                            Button {
                                copyBalanceSummary()
                            } label: {
                                Label(justCopiedBalance ? "Copié !" : "Copier les comptes",
                                      systemImage: justCopiedBalance
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
            .task {
                if let gameId = room.cloudGameId {
                    await editService.load(gameId: gameId)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isEditingBalances, focusedSeat != nil {
                    balanceKeyboardBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focusedSeat)
            .alert("Exclure \(kickConfirm?.name ?? "") ?",
                   isPresented: Binding(
                    get: { kickConfirm != nil },
                    set: { if !$0 { kickConfirm = nil } }
                   )) {
                Button("Annuler", role: .cancel) {}
                Button("Exclure", role: .destructive) {
                    if let seat = kickConfirm?.seat {
                        onKick?(seat)
                    }
                    kickConfirm = nil
                }
            } message: {
                Text("Le joueur sera marqué comme déconnecté et exclu des manches suivantes. Son solde est conservé.")
            }
        }
    }

    // MARK: - Section 1 : solde courant de tous les joueurs

    @ViewBuilder
    private var balancesSection: some View {
        Section {
            ForEach(allRows) { row in
                balanceRow(row)
                    .contextMenu {
                        if canKick(row.player) {
                            Button(role: .destructive) {
                                kickConfirm = (row.player.seat, row.player.displayName)
                            } label: {
                                Label("Exclure de la partie",
                                      systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                    }
            }
        } header: {
            sectionHeader(icon: "creditcard.fill", title: "Solde courant", color: Theme.brandRed)
        } footer: {
            if isHost {
                Text("Appui long sur un joueur pour l'exclure si sa déconnexion n'a pas été détectée.")
                    .font(.caption)
            }
        }
    }

    private func canKick(_ p: GamePlayer) -> Bool {
        guard isHost else { return false }
        return p.userId != auth.userId
    }

    @ViewBuilder
    private func balanceRow(_ row: PlayerRow) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(row.player.displayName.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                )
                .opacity(row.isInactive ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.player.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.isInactive ? .secondary : .primary)
                if row.isInactive {
                    HStack(spacing: 4) {
                        Image(systemName: row.player.connected ? "pause.circle" : "wifi.slash")
                            .font(.system(size: 9))
                        Text(row.player.connected ? "Spectateur" : "Déconnecté")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isEditingBalances, row.player.userId != nil {
                balanceEditField(seat: row.player.seat)
            } else {
                Text(formatMoney(row.player.score))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(row.isInactive
                                     ? Color.secondary
                                     : (row.player.score >= 0 ? Color.green : Color.red))
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

    // MARK: - Edit balances helpers

    private func startEditingBalances() {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        var dict: [Int: String] = [:]
        if let gs = room.gameState {
            for p in gs.players where p.userId != nil {
                dict[p.seat] = f.string(from: NSNumber(value: p.score)) ?? "\(p.score)"
            }
        }
        balanceTexts = dict
        saveError = nil
        isEditingBalances = true
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
        guard let gameId = room.cloudGameId, let gs = room.gameState else {
            withAnimation { isEditingBalances = false }
            return
        }
        var deltas: [Int: Double] = [:]
        for p in gs.players where p.userId != nil {
            let new = parsedBalance(seat: p.seat) ?? p.score
            let delta = new - p.score
            if abs(delta) > 0.001 { deltas[p.seat] = delta }
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
                    gameId: gameId,
                    transfers: transfers,
                    perSeatDeltas: deltas
                )
                await editService.load(gameId: gameId)
                await MainActor.run {
                    isSavingBalances = false
                    withAnimation { isEditingBalances = false }
                }
            } catch {
                await MainActor.run {
                    isSavingBalances = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var balanceKeyboardBar: some View {
        HStack(spacing: 8) {
            Button {
                bumpFocused(by: Self.balanceStep)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                bumpFocused(by: -Self.balanceStep)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                focusedSeat = nil
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

    private struct PlayerRow: Identifiable {
        let player: GamePlayer
        let isInactive: Bool
        var id: Int { player.seat }
    }

    private var allRows: [PlayerRow] {
        guard let gs = room.gameState else { return [] }
        return gs.players
            .sorted { $0.score > $1.score }
            .map { PlayerRow(player: $0, isInactive: !$0.inManche || !$0.connected) }
    }

    // MARK: - Section 2 : mes deltas par manche

    @ViewBuilder
    private var myHistorySection: some View {
        Section {
            if room.pastManches.isEmpty {
                Text("Aucune manche terminée pour l'instant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(room.pastManches.reversed()) { archive in
                    NavigationLink {
                        MancheDetailView(room: room,
                                         archive: archive,
                                         isHost: isHost,
                                         editService: editService)
                    } label: {
                        myMancheRow(archive)
                    }
                }
            }
        } header: {
            sectionHeader(icon: "clock.arrow.circlepath",
                          title: "Tes manches",
                          color: .secondary)
        } footer: {
            if !room.pastManches.isEmpty {
                Text("Touche une manche pour voir les gains/pertes de tous les joueurs.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func myMancheRow(_ archive: MancheArchive) -> some View {
        let myDelta = mySeat.map { archive.perPlayerDelta[$0] ?? 0 } ?? 0
        let won = (mySeat.flatMap { archive.boardsWon[$0] } ?? []).sorted()
        let isFullBoard = (archive.fullBoardWinnerSeat == mySeat) && mySeat != nil
        HStack(spacing: 8) {
            Text("Manche \(archive.mancheNumber)")
                .font(.subheadline.weight(.semibold))

            if archive.numActive > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                    Text("\(archive.numActive)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }

            // Pilule unique avec tous les boards remportés. Doré si full board,
            // rouge sinon. Masquée si aucun board gagné.
            if !won.isEmpty {
                boardsPill(won: won, multis: archive.boardMultis, isFullBoard: isFullBoard)
            }

            Spacer()
            Text(formatMoney(myDelta))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(myDelta >= 0 ? Color.green : Color.red)
        }
    }

    /// Pilule unique listant les boards remportés (B1×8 B2 B3). Couleur
    /// dorée si tous les 3 boards (full board), sinon rouge brand.
    @ViewBuilder
    fileprivate static func boardsPill(won: [Int], multis: [Int: Int], isFullBoard: Bool) -> some View {
        let label = won.map { boardIdx -> String in
            let m = multis[boardIdx] ?? 1
            return m > 1 ? "B\(boardIdx + 1)×\(m)" : "B\(boardIdx + 1)"
        }.joined(separator: " ")
        let textColor: Color = isFullBoard ? Self.goldDeep : Theme.brandRed
        let bgColor: Color   = isFullBoard ? Self.goldLight : Theme.brandRed.opacity(0.12)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(bgColor))
    }

    /// Instance wrapper pour pouvoir l'utiliser depuis les rows non-static.
    @ViewBuilder
    private func boardsPill(won: [Int], multis: [Int: Int], isFullBoard: Bool) -> some View {
        Self.boardsPill(won: won, multis: multis, isFullBoard: isFullBoard)
    }

    /// Couleur dorée pour la pilule full-board.
    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
    fileprivate static let goldLight = Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.35)

    private var mySeat: Int? {
        guard let uid = auth.userId else { return nil }
        return room.gameState?.players.first(where: { $0.userId == uid })?.seat
    }

    /// Solde courant projeté par seat — utilisé pour préfiller le sheet
    /// d'édition des soldes (parité avec EditBalancesSheet du compteur).
    private var currentScoresBySeat: [Int: Double] {
        var out: [Int: Double] = [:]
        if let players = room.gameState?.players {
            for p in players { out[p.seat] = p.score }
        }
        return out
    }

    // MARK: - Section header style commun

    @ViewBuilder
    private func sectionHeader(icon: String, title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .foregroundStyle(color)
    }

    private func formatMoney(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v)) €"
    }

    // MARK: - Copier solde

    private func copyBalanceSummary() {
        guard let gs = room.gameState else { return }
        var lines: [String] = []
        lines.append("Baccarat · Manche \(gs.mancheNumber)")
        lines.append("Code partie : \(room.code)")
        lines.append("")
        // Largeur de nom pour padding gauche (alignement vertical des montants)
        let maxNameLen = gs.players.map { $0.displayName.count }.max() ?? 0
        for p in gs.players.sorted(by: { $0.score > $1.score }) {
            let suffix: String = {
                if !p.connected { return " (déconnecté)" }
                if !p.inManche  { return " (spectateur)" }
                return ""
            }()
            let nameField = p.displayName
                .padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            lines.append("\(nameField)\(suffix)   \(formatMoney(p.score))")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        justCopiedBalance = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopiedBalance = false }
        }
    }
}

// MARK: - Détail par manche (NavigationLink)

struct MancheDetailView: View {
    let room: OnlineRoom
    let archive: MancheArchive
    /// Host = peut éditer cette manche.
    var isHost: Bool = false
    /// Service cloud partagé avec BalanceHistorySheet (déjà chargé à ce
    /// stade en pratique). On l'utilise pour récupérer la ligne cloud
    /// correspondante au tap "Modifier".
    @ObservedObject var editService: OnlineGameEditService

    /// État éditable des 3 boards inline (sous la section gains/pertes).
    /// Initialisé à partir de la cloud row au load ; reset à chaque save.
    @State private var editBoards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
    @State private var initialBoards: [OnlineBoardEdit] = []
    @State private var isSaving = false
    @State private var saveError: String?

    /// Ligne cloud correspondant à `archive` (match par manche_number).
    /// Si pas encore chargée → on attend ; le bouton Modifier est désactivé.
    private var cloudManche: OnlineMancheRow? {
        editService.manches.first(where: { $0.mancheNumber == archive.mancheNumber })
    }

    private var isDirty: Bool { editBoards != initialBoards }
    private var canSave: Bool {
        isHost && cloudManche != nil && isDirty && !isSaving
    }

    var body: some View {
        List {
            Section {
                ForEach(rankedRows) { entry in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text(String(entry.name.prefix(1)).uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Text(entry.name)
                            .font(.subheadline.weight(.semibold))
                        if !entry.boardsWon.isEmpty {
                            BalanceHistorySheet.boardsPill(
                                won: entry.boardsWon,
                                multis: archive.boardMultis,
                                isFullBoard: entry.isFullBoardWinner
                            )
                        }
                        Spacer()
                        Text(formatMoney(entry.delta))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(entry.delta >= 0 ? Color.green : Color.red)
                    }
                }
            } header: {
                Text("Gains/pertes")
            } footer: {
                Text("Donneur : \(nameFor(seat: archive.dealerSeat) ?? "Seat \(archive.dealerSeat)")")
                    .font(.caption)
            }

            if isHost, cloudManche != nil {
                boardsEditSection
            }

            if let err = saveError {
                Section { Text(err).foregroundStyle(.red).font(.footnote) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Manche \(archive.mancheNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: commit) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .tint(Theme.brandRed)
                    .disabled(!canSave)
                }
            }
        }
        .onChange(of: cloudManche?.id) { _, _ in load() }
        .onAppear(perform: load)
    }

    // MARK: - Boards editor (inline)

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
            Text("Modifie le gagnant et le multi pour recalculer les soldes de cette manche.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func boardBlock(label: LocalizedStringKey, board: Binding<OnlineBoardEdit>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(editService.participants) { p in
                    playerCell(name: p.displayName,
                               isSelected: board.wrappedValue.winnerSeat == p.seat) {
                        board.wrappedValue.winnerSeat =
                            (board.wrappedValue.winnerSeat == p.seat) ? nil : p.seat
                    }
                }
                playerCell(name: "Abandonné",
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
    private func playerCell(name: String,
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
        guard let cm = cloudManche else { return }
        var newBoards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
        for br in cm.boardResults {
            // SQL convention : board_num est 1-indexé, et boards 1/2/3 → idx 0/1/2.
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
        guard let cm = cloudManche, isDirty, !isSaving else { return }
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
                    mancheId: cm.id,
                    boardResults: raws,
                    fullBoardSeat: fb,
                    perSeatDeltas: deltas
                )
                if let gameId = room.cloudGameId {
                    await editService.load(gameId: gameId)
                }
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

    private struct DeltaRow: Identifiable {
        let seat: Int
        let name: String
        let delta: Double
        let boardsWon: [Int]
        let isFullBoardWinner: Bool
        var id: Int { seat }
    }

    private var rankedRows: [DeltaRow] {
        archive.perPlayerDelta
            .map { (seat, delta) -> DeltaRow in
                DeltaRow(
                    seat: seat,
                    name: nameFor(seat: seat) ?? "Seat \(seat)",
                    delta: delta,
                    boardsWon: archive.boardsWon[seat] ?? [],
                    isFullBoardWinner: archive.fullBoardWinnerSeat == seat
                )
            }
            .sorted { $0.delta > $1.delta }
    }

    private func nameFor(seat: Int) -> String? {
        room.gameState?.players.first(where: { $0.seat == seat })?.displayName
    }

    private func formatMoney(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v)) €"
    }
}
