//
//  MidGameSettingsSheet.swift
//  Bakarat
//
//  Sheet présenté depuis la toolbar leading de l'écran de jeu.
//  Permet à l'hôte de modifier les réglages en cours de partie. Les
//  modifications s'appliquent à la MANCHE SUIVANTE (la manche courante
//  utilise les valeurs stockées dans son gameState au moment du build).
//
//  Guest = lecture seule.
//

import SwiftUI

struct MidGameSettingsSheet: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService
    @Environment(\.dismiss) private var dismiss

    @State private var linePriceText: String = ""
    @FocusState private var priceFieldFocused: Bool
    /// Feedback visuel temporaire après copie du code (icône check verte 1.5s).
    @State private var justCopiedCode: Bool = false

    private static let minPrice: Double = 0.5
    private static let maxPrice: Double = 50
    private static let priceStep: Double = 0.5
    private static let timerOptions: [Int] = [20, 30, 40, 50, 60, 90]

    private var isHost: Bool { service.role == .host }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        copyCode()
                    } label: {
                        HStack {
                            Image(systemName: justCopiedCode
                                  ? "checkmark.circle.fill"
                                  : "doc.on.clipboard")
                                .foregroundStyle(justCopiedCode ? Color.green : Color.primary)
                                .animation(.easeOut(duration: 0.2), value: justCopiedCode)
                            Text("Copier code")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let code = service.room?.code {
                                Text(code)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .tracking(2.5)
                                    .foregroundStyle(Color(.systemBackground))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isHost {
                    Section {
                        priceRow
                        timerToggle
                        flashToggle
                    } header: {
                        Text("Pour la manche suivante")
                    }
                } else if let hostName = hostDisplayName {
                    Section {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(Theme.brandRed)
                            Text("L'hôte est ")
                                .foregroundStyle(.secondary)
                            + Text(hostName)
                                .fontWeight(.semibold)
                        }
                    } footer: {
                        Text("Seul l'hôte peut modifier les paramètres de la partie.")
                            .font(.caption)
                    }
                }

                Section {
                    Toggle("Spectateur", isOn: spectatorBinding)
                        .tint(Theme.brandRed)
                } header: {
                    Text("Mon statut")
                }

                Section {
                    Button(role: .destructive) {
                        leaveGame()
                    } label: {
                        Label("Quitter la partie", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(Theme.brandRed)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if priceFieldFocused {
                    keyboardAccessoryBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: priceFieldFocused)
            .onAppear {
                if linePriceText.isEmpty {
                    linePriceText = formatPriceForField(service.room?.linePrice ?? 2.5)
                }
            }
            .onChange(of: service.room?.linePrice) { _, new in
                if !priceFieldFocused, let v = new {
                    linePriceText = formatPriceForField(v)
                }
            }
        }
    }

    @ViewBuilder
    private var keyboardAccessoryBar: some View {
        let cur = service.room?.linePrice ?? 2.5
        let canDec = isHost && cur > Self.minPrice
        let canInc = isHost && cur < Self.maxPrice
        HStack(spacing: 8) {
            Button {
                let new = min(Self.maxPrice, cur + Self.priceStep)
                commitPrice(new)
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
                commitPrice(new)
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
                syncPriceFromService()
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

    // MARK: - Rows

    @ViewBuilder
    private var priceRow: some View {
        HStack {
            Text("Prix de la ligne")
            Spacer()
            HStack(spacing: 6) {
                TextField("2,5", text: $linePriceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($priceFieldFocused)
                    .disabled(!isHost)
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onChange(of: linePriceText) { _, new in handlePriceTextChange(new) }
                    .onChange(of: priceFieldFocused) { _, focused in
                        if !focused { syncPriceFromService() }
                    }
                Text("€")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var timerToggle: some View {
        Picker(selection: timerBinding) {
            Text("Désactivé").tag(0)
            ForEach(Self.timerOptions, id: \.self) { sec in
                Text("\(sec) s").tag(sec)
            }
        } label: {
            Text("Timer par annonce")
        }
        .pickerStyle(.menu)
        .tint(Theme.brandRed)
        .disabled(!isHost)
    }

    @ViewBuilder
    private var flashToggle: some View {
        Toggle("Mode Flash", isOn: flashBinding)
            .tint(Theme.brandRed)
            .disabled(!isHost)
    }

    // MARK: - Spectator + leave + host info

    private var mySpectatorWanted: Bool {
        guard let uid = auth.userId,
              let me = service.room?.gameState?.players.first(where: { $0.userId == uid }) else {
            return false
        }
        return me.wantsToSpectate
    }

    private var spectatorBinding: Binding<Bool> {
        Binding(
            get: { mySpectatorWanted },
            set: { v in Task { await service.setSelfSpectator(v) } }
        )
    }

    private var hostDisplayName: String? {
        guard let hostUid = service.room?.hostUserId else { return nil }
        return service.room?.participants.first(where: { $0.userId == hostUid })?.displayName
    }

    /// Départ explicite (geste utilisateur) — cf. T03b.
    private func leaveGame() {
        dismiss()
        Task { await service.leave() }
    }

    private func copyCode() {
        guard let code = service.room?.code else { return }
        UIPasteboard.general.string = code
        justCopiedCode = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopiedCode = false }
        }
    }

    // MARK: - Bindings & helpers

    private var flashBinding: Binding<Bool> {
        Binding(
            get: { service.room?.flashMode ?? false },
            set: { v in Task { await service.updateSettings(flashMode: v) } }
        )
    }

    private var timerBinding: Binding<Int> {
        Binding(
            get: { service.room?.announceTimerSeconds ?? 0 },
            set: { v in Task { await service.updateSettings(announceTimerSeconds: v) } }
        )
    }

    private func handlePriceTextChange(_ raw: String) {
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
        if let v = parsePrice(filtered), (Self.minPrice...Self.maxPrice).contains(v) {
            Task { await service.updateSettings(linePrice: v) }
        }
    }

    private func syncPriceFromService() {
        linePriceText = formatPriceForField(service.room?.linePrice ?? 2.5)
    }

    private func parsePrice(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    private func formatPriceForField(_ p: Double) -> String {
        if p.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", p)
        }
        return String(format: "%.1f", p).replacingOccurrences(of: ".", with: ",")
    }

    private func commitPrice(_ v: Double) {
        linePriceText = formatPriceForField(v)
        Task { await service.updateSettings(linePrice: v) }
    }
}
