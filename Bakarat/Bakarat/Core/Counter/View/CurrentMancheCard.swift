//
//  CurrentMancheCard.swift
//  Bakarat
//
//  Card "Manche en cours" embarquée dans CounterDetailView.
//
//  Chaque board présente une grille 2-colonnes de joueurs (multi-sélection)
//  + un picker compact ×1 / ×8 / ×16 / ×20. Si 2+ joueurs sont sélectionnés
//  sur un board, un slot "Split N" apparaît automatiquement sous les 3
//  boards principaux : l'user y indique le gagnant final (ou re-split).
//

import SwiftUI
import SwiftData

// MARK: - Multi catalog (mode compteur)

enum CounterMulti: Int, CaseIterable, Identifiable {
    case x1 = 1
    case x8 = 8
    case x16 = 16
    case x20 = 20

    var id: Int { rawValue }

    var categoriesLabel: String {
        switch self {
        case .x1:  return "Normal"
        case .x8:  return "Carré"
        case .x16: return "Q. flush"
        case .x20: return "Royale"
        }
    }

    var displayLabel: String { "×\(rawValue)" }
}

// MARK: - State (3 main boards + chain de splits par board)

struct SplitLevel: Identifiable, Equatable {
    let id: UUID
    var winners: Set<Int> = []
    var multi: CounterMulti = .x1

    init(id: UUID = UUID()) { self.id = id }
}

struct MainBoardState: Identifiable, Equatable {
    let id: Int  // 0, 1, 2
    var winners: Set<Int> = []
    var multi: CounterMulti = .x1
    var splits: [SplitLevel] = []
}

// MARK: - Card

struct CurrentMancheCard: View {
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext

    /// Closure appelée après chaque validation pour que le parent (CounterDetailView)
    /// puisse remonter la ScrollView en haut + déclencher la sync cloud.
    var onValidated: ((CounterManche) -> Void)? = nil

    @State private var mainBoards: [MainBoardState] = (0..<3).map { MainBoardState(id: $0) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array($mainBoards.enumerated()), id: \.element.id) { idx, $b in
                if idx > 0 {
                    Divider()
                        .padding(.vertical, 12)
                }
                boardBlock(label: "Board \($b.wrappedValue.id + 1)",
                           winners: $b.winners,
                           multi: $b.multi,
                           allowedSeats: nil,
                           onWinnersChange: { syncSplits(forBoardIdx: $b.wrappedValue.id) })
            }

            // Splits — global numbering (Split 1, 2, 3, …) avec contour doré.
            ForEach(Array(allSplits.enumerated()), id: \.element.id) { idx, ref in
                Divider()
                    .padding(.vertical, 18)
                splitBlock(globalIndex: idx + 1, ref: ref)
            }

            // Full Board banner : apparait quand le même joueur est sélectionné
            // comme gagnant final des 3 boards. Le scoring l'applique automatiquement
            // à la validation ; ce bandeau sert juste de confirmation visuelle.
            if let fbSeat = currentFullBoardSeat,
               let player = counter.players.first(where: { $0.seat == fbSeat }) {
                fullBoardBanner(player: player)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .scale))
            }

            validateButton
                .padding(.top, 16)
        }
        .animation(.snappy, value: currentFullBoardSeat)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .onChange(of: counter.players.count) { _, _ in
            sanitizeAll()
        }
    }

    // MARK: - Boards

    @ViewBuilder
    private func boardBlock(label: LocalizedStringKey,
                            winners: Binding<Set<Int>>,
                            multi: Binding<CounterMulti>,
                            allowedSeats: Set<Int>?,
                            onWinnersChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 10)

            let candidates = candidatePlayers(allowedSeats: allowedSeats)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(player: p,
                               isSelected: winners.wrappedValue.contains(p.seat)) {
                        if winners.wrappedValue.contains(p.seat) {
                            winners.wrappedValue.remove(p.seat)
                        } else {
                            winners.wrappedValue.insert(p.seat)
                        }
                        onWinnersChange()
                    }
                }
            }

            multiPicker(multi)
        }
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

            let candidates = counter.activePlayersOrdered.filter { allowed.contains($0.seat) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(player: p,
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

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
    fileprivate static let goldLight = Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.12)

    // MARK: - Player cell (2-col rounded rectangle)

    @ViewBuilder
    private func playerCell(player: CounterPlayer,
                            isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // Texte centré
                Text(player.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                // Checkmark en surimpression à droite quand sélectionné
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
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.brandRed : Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Theme.brandRed : Color(.systemGray4),
                            lineWidth: isSelected ? 0 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Multi picker (compact)

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

    // MARK: - Validate button

    @ViewBuilder
    private var validateButton: some View {
        Button(action: validate) {
            Text(validateLabel)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canValidate ? Theme.brandRed : Theme.brandRed.opacity(0.35))
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canValidate)
    }

    // MARK: - Full Board detection (UI indicator avant validation)

    /// Gagnant final d'un board en l'état courant de la sélection.
    /// Renvoie nil si abandonné ou tant que la chaîne de splits n'a pas
    /// résolu à un seul winner.
    private func finalWinner(for mb: MainBoardState) -> Int? {
        if mb.winners.count == 1 { return mb.winners.first }
        if mb.winners.count >= 2, let last = mb.splits.last, last.winners.count == 1 {
            return last.winners.first
        }
        return nil
    }

    /// Seat qui remporte les 3 boards (Full Board) en l'état actuel, ou nil.
    private var currentFullBoardSeat: Int? {
        let winners = mainBoards.map { finalWinner(for: $0) }
        guard let w0 = winners[0], let w1 = winners[1], let w2 = winners[2] else { return nil }
        return (w0 == w1 && w1 == w2) ? w0 : nil
    }

    @ViewBuilder
    private func fullBoardBanner(player: CounterPlayer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(Self.goldDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Board")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Self.goldDeep)
                Text("\(player.name) wins all 3 boards. Bonus applied on validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.goldDeep.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Self.goldDeep.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers (candidates / split allowed seats)

    private func candidatePlayers(allowedSeats: Set<Int>?) -> [CounterPlayer] {
        let active = counter.activePlayersOrdered
        guard let allowedSeats else { return active }
        return active.filter { allowedSeats.contains($0.seat) }
    }

    private func allowedSeatsForSplit(mainIdx: Int, splitIdx: Int) -> Set<Int> {
        // splitIdx=0 → parent = mainBoards[mainIdx].winners
        // splitIdx>0 → parent = mainBoards[mainIdx].splits[splitIdx-1].winners
        let mb = mainBoards[mainIdx]
        if splitIdx == 0 { return mb.winners }
        return mb.splits[splitIdx - 1].winners
    }

    // MARK: - Split chain maintenance

    /// Représente une référence stable vers un slot de split pour ForEach.
    private struct SplitRef: Identifiable, Equatable {
        let id: UUID
        let mainBoardIdx: Int
        let splitIdx: Int
    }

    /// Toutes les splits actuelles dans l'ordre d'affichage : Board 1 puis 2
    /// puis 3, et au sein de chacun par profondeur croissante.
    private var allSplits: [SplitRef] {
        var out: [SplitRef] = []
        for mb in mainBoards {
            for (si, sl) in mb.splits.enumerated() {
                out.append(SplitRef(id: sl.id, mainBoardIdx: mb.id, splitIdx: si))
            }
        }
        return out
    }

    /// Toggle un seat dans les winners d'un split + re-sync la chaîne en aval.
    private func toggleSplitWinner(mainIdx: Int, splitIdx: Int, seat: Int) {
        if mainBoards[mainIdx].splits[splitIdx].winners.contains(seat) {
            mainBoards[mainIdx].splits[splitIdx].winners.remove(seat)
        } else {
            mainBoards[mainIdx].splits[splitIdx].winners.insert(seat)
        }
        syncSplits(forBoardIdx: mainIdx)
    }

    /// Met à jour la chaîne de splits du board principal mainIdx en fonction
    /// des winners actuels à chaque niveau. Règle :
    ///  - Si le niveau N a 0 ou 1 winner → tronque tout après N.
    ///  - Si le niveau N a 2+ winners → garantit que N+1 existe ; clamp ses
    ///    winners pour rester inclus dans ceux de N.
    private func syncSplits(forBoardIdx mainIdx: Int) {
        var mb = mainBoards[mainIdx]

        // Niveau 0 = main board lui-même
        if mb.winners.count < 2 {
            mb.splits = []
            mainBoards[mainIdx] = mb
            return
        }

        // mainBoard a 2+ → splits.first doit exister
        if mb.splits.isEmpty {
            mb.splits = [SplitLevel()]
        }

        // Clamp et propage en cascade
        var allowedParent: Set<Int> = mb.winners
        var i = 0
        while i < mb.splits.count {
            // Clamp les winners au parent
            let clamped = mb.splits[i].winners.intersection(allowedParent)
            if clamped != mb.splits[i].winners {
                mb.splits[i].winners = clamped
            }
            let count = mb.splits[i].winners.count
            if count < 2 {
                // Tronque le reste
                if mb.splits.count > i + 1 {
                    mb.splits = Array(mb.splits.prefix(i + 1))
                }
                break
            }
            // 2+ → besoin d'un niveau suivant
            if i + 1 >= mb.splits.count {
                mb.splits.append(SplitLevel())
            }
            allowedParent = mb.splits[i].winners
            i += 1
        }

        mainBoards[mainIdx] = mb
    }

    /// Nettoie les seats invalides (joueur retiré ou désactivé) à tous les
    /// niveaux. Appelé sur change de la liste des joueurs.
    private func sanitizeAll() {
        let validSeats = Set(counter.activePlayersOrdered.map { $0.seat })
        for mi in mainBoards.indices {
            mainBoards[mi].winners.formIntersection(validSeats)
            for si in mainBoards[mi].splits.indices {
                mainBoards[mi].splits[si].winners.formIntersection(validSeats)
            }
            syncSplits(forBoardIdx: mi)
        }
    }

    // MARK: - Validation (canValidate + label)

    private var canValidate: Bool {
        // Chaque main board doit être soit abandonné (winners vides + pas de
        // splits), soit avoir une chaîne complète qui se termine à 1 winner.
        guard counter.activePlayersOrdered.count >= 2 else { return false }
        for mb in mainBoards {
            if mb.winners.isEmpty {
                // Abandonné OK (mais doit pas avoir de splits parasites — by construction)
                continue
            }
            if mb.winners.count == 1 {
                // Normal, OK
                continue
            }
            // Split chain doit terminer à 1 winner.
            guard let last = mb.splits.last else { return false }
            if last.winners.count != 1 { return false }
            // Tous les intermédiaires ont 2+ par construction.
        }
        return true
    }

    private var validateLabel: String {
        if counter.activePlayersOrdered.count < 2 { return "Pas assez de joueurs actifs" }
        return canValidate ? "Valider la manche" : "Renseigne tous les boards"
    }

    // MARK: - Scoring + commit

    /// Pour chaque main board, renvoie (finalWinner?, finalMulti, splitterSeats).
    /// finalWinner = nil → abandonné.
    private func resolveBoard(_ mb: MainBoardState) -> (winner: Int?, multi: Int, splitters: [Int]) {
        if mb.winners.isEmpty {
            return (nil, mb.multi.rawValue, [])
        }
        if mb.winners.count == 1 {
            return (mb.winners.first, mb.multi.rawValue, [])
        }
        // Avec split : le finalWinner est le winner de la dernière split slot
        let splitters = Array(mb.winners).sorted()
        if let last = mb.splits.last, last.winners.count == 1 {
            return (last.winners.first, last.multi.rawValue, splitters)
        }
        return (nil, mb.multi.rawValue, splitters)  // pas censé arriver si canValidate
    }

    private func computeDeltas() -> [Int: Double] {
        var deltas: [Int: Double] = [:]
        let active = counter.activePlayersOrdered
        for p in active { deltas[p.seat] = 0 }
        let n = active.count
        guard n >= 2 else { return deltas }
        let price = counter.linePrice

        var finalWinners: [Int?] = []

        for mb in mainBoards {
            let r = resolveBoard(mb)
            finalWinners.append(r.winner)

            guard let winner = r.winner else { continue }

            if r.splitters.isEmpty {
                // Normal board
                let payment = price * Double(r.multi)
                for p in active {
                    if p.seat == winner {
                        deltas[p.seat, default: 0] += payment * Double(n - 1)
                    } else {
                        deltas[p.seat, default: 0] -= payment
                    }
                }
            } else {
                // Split : splitters paient au multi final, non-splitters au ×1
                let splitterSet = Set(r.splitters)
                let multiPayment = price * Double(r.multi)
                let basePayment = price
                var winnerGains: Double = 0
                for p in active where p.seat != winner {
                    if splitterSet.contains(p.seat) {
                        deltas[p.seat, default: 0] -= multiPayment
                        winnerGains += multiPayment
                    } else {
                        deltas[p.seat, default: 0] -= basePayment
                        winnerGains += basePayment
                    }
                }
                deltas[winner, default: 0] += winnerGains
            }
        }

        // Full Board bonus : si même finalWinner aux 3 boards
        let allEqual = finalWinners.compactMap { $0 }.count == 3 &&
                       finalWinners[0] == finalWinners[1] &&
                       finalWinners[1] == finalWinners[2]
        if allEqual, let fb = finalWinners[0] {
            let bonus = price
            for p in active {
                if p.seat == fb {
                    deltas[p.seat, default: 0] += bonus * Double(n - 1)
                } else {
                    deltas[p.seat, default: 0] -= bonus
                }
            }
        }

        return deltas
    }

    private func validate() {
        guard canValidate else { return }
        let deltas = computeDeltas()

        // Sérialise les boards.
        var results: [CounterBoardResult] = []
        for mb in mainBoards {
            let r = resolveBoard(mb)
            results.append(CounterBoardResult(
                board: mb.id,
                winnerSeat: r.winner,
                multi: r.multi,
                isFullBoard: false,  // patché ci-dessous
                splitterSeats: r.splitters.isEmpty ? nil : r.splitters
            ))
        }
        // Patch full board flag : tous les 3 winners égaux et non-nil.
        let winners = results.map { $0.winnerSeat }
        if let w0 = winners[0], w0 == winners[1], w0 == winners[2] {
            for i in results.indices { results[i].isFullBoard = true }
        }

        let manche = CounterManche(number: counter.nextMancheNumber,
                                   dealerSeat: counter.dealerIdx)
        manche.boardResults = results
        manche.perPlayerDeltas = deltas
        manche.counter = counter
        modelContext.insert(manche)

        for p in counter.players {
            if let d = deltas[p.seat] {
                p.score += d
            }
        }

        // Dealer tourne — uniquement parmi les actifs.
        let activeSeats = counter.activePlayersOrdered.map { $0.seat }
        if !activeSeats.isEmpty {
            if let idx = activeSeats.firstIndex(of: counter.dealerIdx) {
                counter.dealerIdx = activeSeats[(idx + 1) % activeSeats.count]
            } else {
                counter.dealerIdx = activeSeats[0]
            }
        }

        counter.lastUsedAt = .now
        try? modelContext.save()

        // Reset des boards pour la prochaine manche.
        mainBoards = (0..<3).map { MainBoardState(id: $0) }

        // Le parent gère scroll-to-top + sync cloud.
        onValidated?(manche)
    }

    // MARK: - Format

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }
}
