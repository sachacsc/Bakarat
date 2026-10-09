//
//  EditOnlineMancheSheet.swift
//  Bakarat
//
//  Édition manuelle d'une manche cloud (online). Variante simplifiée
//  de EditMancheSheet du compteur :
//    - 3 boards, 1 gagnant par board (ou "abandonné")
//    - 1 multi par board (×1 / ×8 / ×16 / ×20)
//    - Toggle Full Board automatique si même gagnant sur les 3 boards
//    - Aperçu live du delta par joueur
//
//  Le scoring suit la même formule que applyBoardScoring du host :
//  winner = +prix × multi × (N-1), loser = -prix × multi.
//  Au commit, on appelle update_online_manche (revert + update + reapply).
//

import SwiftUI

struct EditOnlineMancheSheet: View {
    @ObservedObject var service: OnlineGameEditService
    let manche: OnlineMancheRow
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var boards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
    @State private var isSaving = false
    @State private var saveError: String?

    private static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Modifie le gagnant et le multi de chaque board. Les soldes sont recalculés à la sauvegarde.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    boardsCard
                    fullBoardCard
                    previewCard

                    if let err = saveError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button(action: commit) {
                        HStack {
                            if isSaving { ProgressView().tint(.white) }
                            Text(isSaving ? "Sauvegarde…" : "Sauvegarder")
                                .font(.subheadline.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(canCommit ? Theme.brandRed : Theme.brandRed.opacity(0.35))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit || isSaving)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Modifier manche \(manche.mancheNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Boards card

    private var boardsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array($boards.enumerated()), id: \.element.id) { idx, $b in
                if idx > 0 {
                    Divider().padding(.vertical, 14)
                }
                boardBlock(label: "Board \(idx + 1)", board: $b)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func boardBlock(label: LocalizedStringKey, board: Binding<OnlineBoardEdit>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(service.participants) { p in
                    playerCell(name: p.displayName,
                               isSelected: board.wrappedValue.winnerSeat == p.seat) {
                        if board.wrappedValue.winnerSeat == p.seat {
                            board.wrappedValue.winnerSeat = nil
                        } else {
                            board.wrappedValue.winnerSeat = p.seat
                        }
                    }
                }
                // Abandoned slot
                playerCell(name: "Abandonné",
                           isSelected: board.wrappedValue.winnerSeat == nil,
                           italic: true) {
                    board.wrappedValue.winnerSeat = nil
                }
            }

            multiPicker(board.multi)
        }
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
                        .stroke(Color(.systemGray4).opacity(isSelected ? 0 : 1),
                                lineWidth: 1)
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

    // MARK: - Full board card

    @ViewBuilder
    private var fullBoardCard: some View {
        if let fbSeat = detectedFullBoardSeat,
           let player = service.participants.first(where: { $0.seat == fbSeat }) {
            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .foregroundStyle(Self.goldDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Board")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Self.goldDeep)
                    Text("\(player.displayName) remporte les 3 boards (+prix × N-1 bonus).")
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
    }

    private var detectedFullBoardSeat: Int? {
        let winners = boards.compactMap { $0.winnerSeat }
        guard winners.count == 3 else { return nil }
        let s = Set(winners)
        return s.count == 1 ? winners.first : nil
    }

    // MARK: - Preview card

    private var previewCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Aperçu deltas")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                let total = previewDeltas.values.reduce(0, +)
                Text(formatSigned(total))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(abs(total) < 0.005 ? Color.secondary : Color.orange)
            }
            .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(service.participants) { p in
                    HStack {
                        Text(p.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(formatSigned(previewDeltas[p.seat] ?? 0))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(deltaColor(previewDeltas[p.seat] ?? 0))
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Compute deltas

    private var activeSeats: [Int] { service.participants.map { $0.seat } }

    private var previewDeltas: [Int: Double] {
        Self.computeDeltas(boards: boards,
                           activeSeats: activeSeats,
                           linePrice: service.linePrice,
                           fullBoardSeat: detectedFullBoardSeat)
    }

    static func computeDeltas(boards: [OnlineBoardEdit],
                              activeSeats: [Int],
                              linePrice: Double,
                              fullBoardSeat: Int?) -> [Int: Double] {
        var deltas: [Int: Double] = Dictionary(uniqueKeysWithValues: activeSeats.map { ($0, 0.0) })
        let n = activeSeats.count
        guard n >= 2 else { return deltas }
        for b in boards {
            guard let w = b.winnerSeat else { continue }
            let m = Double(b.multi.rawValue)
            for s in activeSeats {
                if s == w {
                    deltas[s, default: 0] += linePrice * m * Double(n - 1)
                } else {
                    deltas[s, default: 0] -= linePrice * m
                }
            }
        }
        if let fb = fullBoardSeat {
            for s in activeSeats {
                if s == fb {
                    deltas[s, default: 0] += linePrice * Double(n - 1)
                } else {
                    deltas[s, default: 0] -= linePrice
                }
            }
        }
        return deltas
    }

    // MARK: - Load / commit

    private var canCommit: Bool { service.participants.count >= 2 }

    private func load() {
        // Préfill depuis les boardResults existants : pour chaque board, on
        // prend final_winner_seat (ou winner_seat legacy) + final_multi.
        var newBoards: [OnlineBoardEdit] = (0..<3).map { OnlineBoardEdit(id: $0) }
        for br in manche.boardResults {
            let idx = br.board_num.clamped(0, 2)
            newBoards[idx].winnerSeat = br.final_winner_seat
            newBoards[idx].multi = OnlineMulti.from(br.final_multi)
        }
        self.boards = newBoards
    }

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                let raws: [BoardResultRaw] = boards.map { b in
                    BoardResultRaw(
                        board_num: b.id + 1,        // SQL convention : 1-indexed
                        winner_seat: b.winnerSeat,
                        final_winner_seat: b.winnerSeat,
                        multi: b.multi.rawValue,
                        final_multi: b.multi.rawValue,
                        is_split: false,
                        splitter_seats: []
                    )
                }
                let fbSeat = detectedFullBoardSeat
                try await service.updateManche(
                    mancheId: manche.id,
                    boardResults: raws,
                    fullBoardSeat: fbSeat,
                    perSeatDeltas: previewDeltas
                )
                await MainActor.run {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Erreur : \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Format helpers

    private func formatSigned(_ value: Double) -> String {
        if abs(value) < 0.005 { return format(0) }
        let sign = value > 0 ? "+" : "−"
        return "\(sign)\(format(abs(value)))"
    }

    private func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = service.currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func deltaColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : Theme.systemRed
    }
}

// MARK: - Helpers

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.max(low, Swift.min(high, self)) }
}
