//
//  CounterHistoryView.swift
//  Bakarat
//
//  Push destination depuis le menu "…" : "Solde & Historique". Même design
//  que la version online (BalanceHistorySheet) :
//    1. Soldes courants de tous les joueurs (inactifs greyed-out)
//    2. Manches passées avec deltas du joueur courant — touche une row pour
//       voir les deltas de tous les joueurs sur cette manche.
//  Le bouton Copier (toolbar leading) recopie l'état du compteur dans le
//  presse-papier.
//

import SwiftUI
import SwiftData
import UIKit

struct CounterHistoryView: View {
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext

    @State private var justCopied = false
    /// Mode édition des soldes : les rows deviennent des TextField, la barre
    /// liquid-glass +/- apparait avec le clavier, et le menu top-right devient
    /// un bouton "Done" qui commit les deltas + sort du mode édition.
    @State private var isEditingBalances = false
    @State private var balanceTexts: [UUID: String] = [:]
    @FocusState private var focusedPlayerId: UUID?

    private static let balanceStep: Double = 0.5

    var body: some View {
        List {
            balancesSection
            mancheHistorySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Solde & Historique")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditingBalances {
                    Button("Done") { commitBalances() }
                        .fontWeight(.semibold)
                        .tint(Theme.brandRed)
                } else {
                    Menu {
                        Button {
                            startEditingBalances()
                        } label: {
                            Label("Modifier les soldes", systemImage: "pencil")
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
        .safeAreaInset(edge: .bottom) {
            if isEditingBalances, focusedPlayerId != nil {
                balanceKeyboardBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focusedPlayerId)
    }

    // MARK: - Edit balances mode

    private func startEditingBalances() {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        var dict: [UUID: String] = [:]
        for p in counter.players {
            dict[p.id] = f.string(from: NSNumber(value: p.score)) ?? "\(p.score)"
        }
        balanceTexts = dict
        isEditingBalances = true
    }

    private func parsedBalance(_ id: UUID) -> Double? {
        guard let s = balanceTexts[id] else { return nil }
        let normalized = s
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Double(normalized)
    }

    /// Commit : calcule deltas, applique aux scores, insère un manche
    /// d'ajustement si quelque chose a bougé. Logique alignée sur
    /// EditBalancesSheet (qui devient inutile).
    private func commitBalances() {
        focusedPlayerId = nil
        var deltas: [Int: Double] = [:]
        for p in counter.players {
            guard let new = parsedBalance(p.id) else { continue }
            let delta = new - p.score
            if abs(delta) > 0.001 { deltas[p.seat] = delta }
            p.score = new
        }
        if !deltas.isEmpty {
            let adjustment = CounterManche(
                number: 0,
                dealerSeat: counter.dealerIdx,
                validatedAt: .now,
                isManualAdjustment: true
            )
            adjustment.perPlayerDeltas = deltas
            adjustment.counter = counter
            modelContext.insert(adjustment)
        }
        counter.lastUsedAt = .now
        try? modelContext.save()
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingBalances = false
        }
    }

    @ViewBuilder
    private var balanceKeyboardBar: some View {
        HStack(spacing: 8) {
            Button {
                bumpFocusedBalance(by: Self.balanceStep)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                bumpFocusedBalance(by: -Self.balanceStep)
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
                focusedPlayerId = nil
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

    private func bumpFocusedBalance(by delta: Double) {
        guard let id = focusedPlayerId else { return }
        let current = parsedBalance(id) ?? 0
        let next = current + delta
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        balanceTexts[id] = f.string(from: NSNumber(value: next)) ?? "\(next)"
    }

    // MARK: - Section 1 : soldes

    @ViewBuilder
    private var balancesSection: some View {
        Section {
            ForEach(allRows) { row in
                CounterPlayerRow(
                    name: row.player.name,
                    isDeemphasized: row.isInactive,
                    inlineBadge: { EmptyView() },
                    subtitle: {
                        if row.isInactive {
                            Text("Inactif")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    },
                    trailing: {
                        if isEditingBalances {
                            balanceEditField(for: row.player)
                        } else {
                            Text(formatMoney(row.player.score))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(row.isInactive
                                                 ? Color.secondary
                                                 : scoreColor(score: row.player.score))
                        }
                    }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            if isEditingBalances {
                balanceSumFooter
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        } header: {
            sectionHeader(icon: "creditcard.fill",
                          title: "Solde courant",
                          color: Theme.brandRed)
        } footer: {
            if isEditingBalances {
                Text("Touche un montant pour l'éditer. La barre +/- ajuste le solde focus.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func balanceEditField(for player: CounterPlayer) -> some View {
        HStack(spacing: 4) {
            TextField("0",
                      text: Binding(
                          get: { balanceTexts[player.id] ?? "" },
                          set: { balanceTexts[player.id] = $0 }
                      ))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .focused($focusedPlayerId, equals: player.id)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(maxWidth: 100)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            Text(counter.currency)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var balanceSumFooter: some View {
        let sum = counter.players.reduce(0.0) { $0 + (parsedBalance($1.id) ?? $1.score) }
        let balanced = abs(sum) < 0.005
        HStack {
            Text("Somme")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatMoney(sum))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(balanced ? Color.secondary : Color.orange)
        }
        .padding(.horizontal, 12)
    }

    private struct PlayerRow: Identifiable {
        let player: CounterPlayer
        let isInactive: Bool
        var id: UUID { player.id }
    }

    private var allRows: [PlayerRow] {
        counter.players
            .sorted { $0.score > $1.score }
            .map { PlayerRow(player: $0, isInactive: !$0.isActive) }
    }

    // MARK: - Section 2 : historique des manches

    @ViewBuilder
    private var mancheHistorySection: some View {
        Section {
            if counter.manches.isEmpty {
                Text("Aucune manche validée.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(counter.manchesOrdered) { m in
                    NavigationLink {
                        CounterMancheDetailView(manche: m, counter: counter)
                    } label: {
                        mancheRow(m)
                    }
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteManche(m)
                        } label: {
                            Label("Annuler", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        } header: {
            sectionHeader(icon: "clock.arrow.circlepath",
                          title: "Manches passées",
                          color: .secondary)
        } footer: {
            if !counter.manches.isEmpty {
                Text("Touche une manche pour voir les gains/pertes de tous les joueurs. Glisse à gauche pour annuler.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func mancheRow(_ m: CounterManche) -> some View {
        if m.isManualAdjustment {
            adjustmentRow(m)
        } else {
            let boards = m.boardResults.sorted { $0.board < $1.board }
            let isFullBoard = boards.contains(where: { $0.isFullBoard })
            HStack(spacing: 8) {
                winnersSummary(boards: boards, isFullBoard: isFullBoard)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isFullBoard {
                    Text("Full Board")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.25)))
                        .foregroundStyle(Self.goldDeep)
                }
                Spacer()
                Text("Manche \(m.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func adjustmentRow(_ m: CounterManche) -> some View {
        let deltas = m.perPlayerDeltas
        let nonZero = deltas.filter { abs($0.value) > 0.001 }
        HStack(spacing: 8) {
            adjustmentNames(deltas: nonZero)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Text("Ajustement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func adjustmentNames(deltas: [Int: Double]) -> Text {
        let sorted = deltas.sorted { abs($0.value) > abs($1.value) }
        var combined = Text("")
        for (idx, (seat, _)) in sorted.enumerated() {
            if idx > 0 {
                combined = combined + Text(", ").foregroundColor(.secondary)
            }
            let name = counter.players.first(where: { $0.seat == seat })?.name ?? "?"
            combined = combined + Text(name).foregroundColor(.primary)
        }
        return combined.font(.subheadline.weight(.semibold))
    }

    /// "Hannah×8, Antho, Hannah" — un seul Text concaténé (la virgule colle
    /// au caractère précédent, pas d'espace avant).
    private func winnersSummary(boards: [CounterBoardResult], isFullBoard: Bool) -> Text {
        let multiColor: Color = isFullBoard ? Self.goldDeep : Theme.brandRed
        var combined = Text("")
        for (idx, b) in boards.enumerated() {
            if idx > 0 {
                combined = combined + Text(", ").foregroundColor(.secondary)
            }
            if let seat = b.winnerSeat,
               let name = counter.players.first(where: { $0.seat == seat })?.name {
                combined = combined + Text(name).foregroundColor(.primary)
                if b.multi > 1 {
                    combined = combined + Text(" ×\(b.multi)").foregroundColor(multiColor)
                }
            } else {
                combined = combined + Text("—").foregroundColor(.secondary)
            }
        }
        return combined
            .font(.subheadline.weight(.semibold))
    }

    // MARK: - Section header

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

    // MARK: - Actions

    private func deleteManche(_ m: CounterManche) {
        let deltas = m.perPlayerDeltas
        for p in counter.players {
            if let d = deltas[p.seat] {
                p.score -= d
            }
        }
        modelContext.delete(m)
        counter.lastUsedAt = .now
        try? modelContext.save()
    }

    private func copyState() {
        let text = CounterStateExporter.export(counter: counter)
        UIPasteboard.general.string = text
        withAnimation { justCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    // MARK: - Format

    private func formatMoney(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        if abs(v) < 0.001 { return "0 \(counter.currency)" }
        return v > 0 ? "+\(n) \(counter.currency)" : "−\(n) \(counter.currency)"
    }

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
}

// MARK: - Detail d'une manche (deltas de tous les joueurs)

struct CounterMancheDetailView: View {
    @Bindable var manche: CounterManche
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext

    /// État éditable des 3 boards + cascades de splits. Reflété sur l'écran
    /// SOUS la section gains/pertes. Initialisé à l'apparition depuis
    /// manche.boardResults, puis modifié par l'utilisateur.
    @State private var mainBoards: [MainBoardState] = (0..<3).map { MainBoardState(id: $0) }
    /// Snapshot à l'ouverture (pour détecter isDirty).
    @State private var initialBoards: [MainBoardState] = []

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
    fileprivate static let goldLight = Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.12)

    private var isDirty: Bool { mainBoards != initialBoards }
    private var canCommit: Bool {
        guard isDirty else { return false }
        for mb in mainBoards {
            if mb.winners.isEmpty { continue }
            if mb.winners.count == 1 { continue }
            guard let last = mb.splits.last else { return false }
            if last.winners.count != 1 { return false }
        }
        return true
    }

    var body: some View {
        List {
            deltasSection
            if !manche.isManualAdjustment {
                boardsEditSection
                if hasSplits {
                    splitsEditSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(manche.isManualAdjustment ? "Ajustement" : "Manche \(manche.number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !manche.isManualAdjustment {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .tint(Theme.brandRed)
                        .disabled(!canCommit)
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Boards edit section (inline below gains/pertes)

    private var hasSplits: Bool {
        mainBoards.contains(where: { !$0.splits.isEmpty })
    }

    @ViewBuilder
    private var boardsEditSection: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(Array($mainBoards.enumerated()), id: \.element.id) { idx, $b in
                    if idx > 0 {
                        Divider().padding(.vertical, 12)
                    }
                    boardBlock(label: "Board \($b.wrappedValue.id + 1)",
                               winners: $b.winners,
                               multi: $b.multi,
                               allowedSeats: nil,
                               onChange: { syncSplits(forBoardIdx: $b.wrappedValue.id) })
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        } header: {
            Text("Boards")
        } footer: {
            Text("Touche un joueur pour le marquer gagnant. Si tu en sélectionnes plusieurs, un split apparaît.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var splitsEditSection: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(Array(allSplits.enumerated()), id: \.element.id) { idx, ref in
                    if idx > 0 {
                        Divider().padding(.vertical, 14)
                    }
                    splitBlock(globalIndex: idx + 1, ref: ref)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        } header: {
            Text("Splits")
        }
    }

    @ViewBuilder
    private func boardBlock(label: LocalizedStringKey,
                            winners: Binding<Set<Int>>,
                            multi: Binding<CounterMulti>,
                            allowedSeats: Set<Int>?,
                            onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            let candidates = candidatePlayers(allowedSeats: allowedSeats)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(name: p.name,
                               isSelected: winners.wrappedValue.contains(p.seat)) {
                        if winners.wrappedValue.contains(p.seat) {
                            winners.wrappedValue.remove(p.seat)
                        } else {
                            winners.wrappedValue.insert(p.seat)
                        }
                        onChange()
                    }
                }
            }

            multiPicker(multi)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func splitBlock(globalIndex: Int, ref: SplitRef) -> some View {
        let mainIdx = ref.mainBoardIdx
        let splitIdx = ref.splitIdx
        let allowed = allowedSeatsForSplit(mainIdx: mainIdx, splitIdx: splitIdx)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.goldDeep)
                Text("Split \(globalIndex)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.goldDeep)
                Text("· Board \(mainIdx + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            let candidates = participatingPlayers().filter { allowed.contains($0.seat) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(name: p.name,
                               isSelected: mainBoards[mainIdx].splits[splitIdx].winners.contains(p.seat)) {
                        toggleSplitWinner(mainIdx: mainIdx, splitIdx: splitIdx, seat: p.seat)
                    }
                }
            }

            multiPicker(
                Binding(
                    get: { mainBoards[mainIdx].splits[splitIdx].multi },
                    set: { mainBoards[mainIdx].splits[splitIdx].multi = $0 }
                )
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.goldLight)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Self.goldDeep.opacity(0.55), lineWidth: 1.2)
        )
    }

    // MARK: - Cells & multi picker

    @ViewBuilder
    private func playerCell(name: String,
                            isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                if isSelected {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.trailing, 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.brandRed : Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Theme.brandRed : Color(.systemGray4),
                            lineWidth: isSelected ? 0 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiPicker(_ multi: Binding<CounterMulti>) -> some View {
        HStack(spacing: 4) {
            ForEach(CounterMulti.allCases) { m in
                Button {
                    multi.wrappedValue = m
                } label: {
                    let selected = multi.wrappedValue == m
                    VStack(spacing: 0) {
                        Text(m.displayLabel)
                            .font(.caption.weight(.bold))
                        Text(m.categoriesLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(selected ? Theme.brandRed.opacity(0.85) : Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected
                                  ? Theme.brandRed.opacity(0.14)
                                  : Color(.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selected ? Theme.brandRed : Color(.systemGray4),
                                    lineWidth: selected ? 1.5 : 1)
                    )
                    .foregroundStyle(selected ? Theme.brandRed : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Splits state helpers (port de EditMancheSheet)

    fileprivate struct SplitRef: Identifiable, Equatable {
        let id: UUID
        let mainBoardIdx: Int
        let splitIdx: Int
    }

    private var allSplits: [SplitRef] {
        var out: [SplitRef] = []
        for mb in mainBoards {
            for (si, sl) in mb.splits.enumerated() {
                out.append(SplitRef(id: sl.id, mainBoardIdx: mb.id, splitIdx: si))
            }
        }
        return out
    }

    private func allowedSeatsForSplit(mainIdx: Int, splitIdx: Int) -> Set<Int> {
        let mb = mainBoards[mainIdx]
        if splitIdx == 0 { return mb.winners }
        return mb.splits[splitIdx - 1].winners
    }

    private func toggleSplitWinner(mainIdx: Int, splitIdx: Int, seat: Int) {
        if mainBoards[mainIdx].splits[splitIdx].winners.contains(seat) {
            mainBoards[mainIdx].splits[splitIdx].winners.remove(seat)
        } else {
            mainBoards[mainIdx].splits[splitIdx].winners.insert(seat)
        }
        syncSplits(forBoardIdx: mainIdx)
    }

    private func syncSplits(forBoardIdx mainIdx: Int) {
        var mb = mainBoards[mainIdx]
        if mb.winners.count < 2 {
            mb.splits = []
            mainBoards[mainIdx] = mb
            return
        }
        if mb.splits.isEmpty {
            mb.splits = [SplitLevel()]
        }
        var allowedParent = mb.winners
        var i = 0
        while i < mb.splits.count {
            let clamped = mb.splits[i].winners.intersection(allowedParent)
            if clamped != mb.splits[i].winners {
                mb.splits[i].winners = clamped
            }
            let count = mb.splits[i].winners.count
            if count < 2 {
                if mb.splits.count > i + 1 {
                    mb.splits = Array(mb.splits.prefix(i + 1))
                }
                break
            }
            if i + 1 >= mb.splits.count {
                mb.splits.append(SplitLevel())
            }
            allowedParent = mb.splits[i].winners
            i += 1
        }
        mainBoards[mainIdx] = mb
    }

    // MARK: - Players for this manche (sourced from manche.perPlayerDeltas)

    private func participatingSeats() -> Set<Int> {
        Set(manche.perPlayerDeltas.keys)
    }

    private func participatingPlayers() -> [CounterPlayer] {
        let seats = participatingSeats()
        return counter.players
            .filter { seats.contains($0.seat) }
            .sorted { $0.seat < $1.seat }
    }

    private func candidatePlayers(allowedSeats: Set<Int>?) -> [CounterPlayer] {
        if let allowed = allowedSeats {
            return participatingPlayers().filter { allowed.contains($0.seat) }
        }
        return participatingPlayers()
    }

    // MARK: - Load / Save

    private func load() {
        var rebuilt: [MainBoardState] = (0..<3).map { MainBoardState(id: $0) }
        for b in manche.boardResults {
            guard b.board >= 0 && b.board < 3 else { continue }
            var mb = rebuilt[b.board]
            let splitters = b.splitterSeats ?? []
            let finalWinner = b.winnerSeat
            let multi = CounterMulti(rawValue: b.multi) ?? .x1
            if splitters.isEmpty {
                if let w = finalWinner { mb.winners = [w] }
                mb.multi = multi
            } else {
                mb.winners = Set(splitters)
                mb.multi = .x1
                var split = SplitLevel()
                if let w = finalWinner { split.winners = [w] }
                split.multi = multi
                mb.splits = [split]
            }
            rebuilt[b.board] = mb
        }
        mainBoards = rebuilt
        initialBoards = rebuilt
    }

    private func commit() {
        // 1) Reverse old deltas
        let oldDeltas = manche.perPlayerDeltas
        for p in counter.players {
            if let d = oldDeltas[p.seat] { p.score -= d }
        }
        // 2) Compute new deltas + new board records
        let newDeltas = computeNewDeltas()
        for p in counter.players {
            if let d = newDeltas[p.seat] { p.score += d }
        }
        var newResults: [CounterBoardResult] = []
        for mb in mainBoards {
            let r = resolveBoard(mb)
            newResults.append(CounterBoardResult(
                board: mb.id,
                winnerSeat: r.winner,
                multi: r.multi,
                isFullBoard: false,
                splitterSeats: r.splitters.isEmpty ? nil : r.splitters
            ))
        }
        let winners = newResults.map { $0.winnerSeat }
        if winners.count == 3, let w0 = winners[0], w0 == winners[1], w0 == winners[2] {
            for i in newResults.indices { newResults[i].isFullBoard = true }
        }
        manche.boardResults = newResults
        manche.perPlayerDeltas = newDeltas
        manche.validatedAt = .now
        counter.lastUsedAt = .now
        try? modelContext.save()
        initialBoards = mainBoards  // reset dirty
    }

    private func resolveBoard(_ mb: MainBoardState) -> (winner: Int?, multi: Int, splitters: [Int]) {
        if mb.winners.isEmpty { return (nil, mb.multi.rawValue, []) }
        if mb.winners.count == 1 { return (mb.winners.first, mb.multi.rawValue, []) }
        let splitters = Array(mb.winners).sorted()
        if let last = mb.splits.last, last.winners.count == 1 {
            return (last.winners.first, last.multi.rawValue, splitters)
        }
        return (nil, mb.multi.rawValue, splitters)
    }

    private func computeNewDeltas() -> [Int: Double] {
        let seats = participatingSeats()
        var deltas: [Int: Double] = [:]
        for s in seats { deltas[s] = 0 }
        let n = seats.count
        guard n >= 2 else { return deltas }
        let price = counter.linePrice

        var finalWinners: [Int?] = []
        for mb in mainBoards {
            let r = resolveBoard(mb)
            finalWinners.append(r.winner)
            guard let winner = r.winner else { continue }
            if r.splitters.isEmpty {
                let payment = price * Double(r.multi)
                for s in seats {
                    if s == winner {
                        deltas[s, default: 0] += payment * Double(n - 1)
                    } else {
                        deltas[s, default: 0] -= payment
                    }
                }
            } else {
                let splitterSet = Set(r.splitters)
                let multiPayment = price * Double(r.multi)
                let basePayment = price
                var winnerGains: Double = 0
                for s in seats where s != winner {
                    if splitterSet.contains(s) {
                        deltas[s, default: 0] -= multiPayment
                        winnerGains += multiPayment
                    } else {
                        deltas[s, default: 0] -= basePayment
                        winnerGains += basePayment
                    }
                }
                deltas[winner, default: 0] += winnerGains
            }
        }
        let allEqual = finalWinners.compactMap { $0 }.count == 3 &&
                       finalWinners[0] == finalWinners[1] &&
                       finalWinners[1] == finalWinners[2]
        if allEqual, let fb = finalWinners[0] {
            for s in seats {
                if s == fb { deltas[s, default: 0] += price * Double(n - 1) }
                else        { deltas[s, default: 0] -= price }
            }
        }
        return deltas
    }

    // MARK: - Gains / pertes

    @ViewBuilder
    private var deltasSection: some View {
        Section {
            ForEach(rankedRows) { row in
                deltaRow(row)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        } header: {
            Text("Gains / pertes")
        } footer: {
            if !manche.isManualAdjustment {
                Text("Donneur : \(nameFor(seat: manche.dealerSeat) ?? "Seat \(manche.dealerSeat)")")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func deltaRow(_ row: DeltaRow) -> some View {
        CounterPlayerRow(
            name: row.name,
            inlineBadge: {
                if !row.boardsWon.isEmpty {
                    boardsPill(row: row)
                }
            },
            subtitle: {
                if !row.splitBoardsWon.isEmpty {
                    Text(splitSubtitle(row: row))
                        .font(.caption2)
                        .foregroundStyle(CounterHistoryView.goldDeep)
                }
            },
            trailing: {
                Text(formatMoney(row.delta))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(scoreColor(score: row.delta))
            }
        )
    }

    @ViewBuilder
    private func boardsPill(row: DeltaRow) -> some View {
        let label = row.boardsWon.map { idx -> String in
            let m = row.boardMultis[idx] ?? 1
            return m > 1 ? "B\(idx + 1)×\(m)" : "B\(idx + 1)"
        }.joined(separator: " ")
        let textColor: Color = row.isFullBoardWinner ? CounterHistoryView.goldDeep : Theme.brandRed
        let bgColor: Color = row.isFullBoardWinner
            ? Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.35)
            : Theme.brandRed.opacity(0.12)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(bgColor))
    }

    private struct DeltaRow: Identifiable {
        let seat: Int
        let name: String
        let delta: Double
        let boardsWon: [Int]
        let boardMultis: [Int: Int]
        let isFullBoardWinner: Bool
        /// Boards où ce joueur a gagné après un tie-break (split).
        let splitBoardsWon: [Int]
        /// Pour chaque split board gagné : noms des autres splitters.
        let splitPartnersByBoard: [Int: [String]]
        var id: Int { seat }
    }

    private var rankedRows: [DeltaRow] {
        let deltas = manche.perPlayerDeltas
        let results = manche.boardResults

        var wonBy: [Int: [Int]] = [:]
        var splitWonBy: [Int: [Int]] = [:]
        var splitPartnersByBoardPerSeat: [Int: [Int: [String]]] = [:]
        var multiBy: [Int: Int] = [:]
        for b in results {
            if let s = b.winnerSeat {
                wonBy[s, default: []].append(b.board)
                multiBy[b.board] = b.multi
                if let splitters = b.splitterSeats, !splitters.isEmpty {
                    splitWonBy[s, default: []].append(b.board)
                    let partnerNames = splitters
                        .filter { $0 != s }
                        .compactMap { nameFor(seat: $0) }
                    splitPartnersByBoardPerSeat[s, default: [:]][b.board] = partnerNames
                }
            }
        }
        var fbWinner: Int? = nil
        if results.contains(where: { $0.isFullBoard }) {
            fbWinner = results.first?.winnerSeat
        }

        let allSeats = Set(deltas.keys).union(counter.players.map { $0.seat })
        return allSeats
            .compactMap { seat -> DeltaRow? in
                guard let name = nameFor(seat: seat) else { return nil }
                return DeltaRow(
                    seat: seat,
                    name: name,
                    delta: deltas[seat] ?? 0,
                    boardsWon: wonBy[seat]?.sorted() ?? [],
                    boardMultis: multiBy,
                    isFullBoardWinner: fbWinner == seat,
                    splitBoardsWon: splitWonBy[seat]?.sorted() ?? [],
                    splitPartnersByBoard: splitPartnersByBoardPerSeat[seat] ?? [:]
                )
            }
            .sorted { $0.delta > $1.delta }
    }

    private func nameFor(seat: Int) -> String? {
        counter.players.first(where: { $0.seat == seat })?.name
    }

    /// Construit la ligne "Split sur B1 avec Hugo · B3 avec Lola, Antho".
    /// Une seule ligne, segments séparés par " · " si plusieurs boards.
    private func splitSubtitle(row: DeltaRow) -> String {
        row.splitBoardsWon.map { boardIdx -> String in
            let partners = row.splitPartnersByBoard[boardIdx] ?? []
            if partners.isEmpty {
                return "Split sur B\(boardIdx + 1)"
            }
            return "Split sur B\(boardIdx + 1) avec \(partners.joined(separator: ", "))"
        }.joined(separator: " · ")
    }

    private func formatMoney(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        if abs(v) < 0.001 { return "0 \(counter.currency)" }
        return v > 0 ? "+\(n) \(counter.currency)" : "−\(n) \(counter.currency)"
    }

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }
}
