//
//  OnlineLobbyView.swift
//  Bakarat
//
//  Vue Lobby — List groupée à la iOS Settings :
//    1. Code de la partie (centré, bouton copier en dessous, row sans inset)
//    2. Réglages (Prix, Timer, Mode Flash)
//    3. Joueurs connectés
//    4. Action (Démarrer la partie pour le host, sans inset)
//

import SwiftUI

struct OnlineLobbyView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService

    @Environment(\.dismiss) private var dismiss
    @State private var pendingStart = false
    /// Confirmation avant de quitter une partie en cours.
    @State private var showingLeaveConfirm = false
    /// Buffer texte pour le TextField du prix de la ligne (sync bi-directionnelle
    /// avec service.room.linePrice — édité par l'host, lu par les guests).
    @State private var linePriceText: String = ""
    @FocusState private var priceFieldFocused: Bool

    var body: some View {
        // Router : si la partie a démarré → on bascule sur OnlineGameView.
        // ⚠️ Plus AUCUN `.onDisappear { leave() }` ici (T03b) : changer d'onglet
        // ne doit jamais faire quitter la partie. On ne part que sur un geste
        // explicite (bouton « Quitter »).
        Group {
            if service.room?.status == .playing {
                OnlineGameView(service: service)
            } else {
                lobbyContent
            }
        }
        .roomLifecycle(service)
        .onChange(of: service.phase) { _, newPhase in
            // « Quitter » (ici ou depuis les réglages mi-partie) → on pop le
            // lobby du nav stack pour revenir à l'accueil.
            if newPhase == .left {
                dismiss()
            }
        }
    }

    // MARK: - Bannière de connexion / d'hôte

    @ViewBuilder
    private var connectionBanner: some View {
        if service.connectionState != .connected || service.isReconnecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(service.connectionState == .offline
                     ? "Hors ligne — reconnexion…"
                     : "Reconnexion…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - List body

    private var lobbyContent: some View {
        List {
            if let room = service.room {
                codeSection(room.code)
                if service.connectionState != .connected || service.isReconnecting {
                    Section { connectionBanner }
                }
                settingsSection(room)
                playersSection(room.participants)

                if let err = service.lastError {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            } else if let err = service.lastError {
                // Erreur de connexion : on n'a jamais reçu de snapshot
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        if let status = service.channelStatusLabel {
                            Text("Channel: \(status)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            dismiss()
                        } label: {
                            Text("Retour")
                                .modifier(PrimaryButtonStyle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 16)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    VStack(spacing: 10) {
                        ProgressView()
                        if let code = service.pendingChannelCode, service.role == .guest {
                            Text("Recherche du salon")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .tracking(4)
                                .foregroundStyle(.primary)
                        } else {
                            Text(connectingLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let status = service.channelStatusLabel {
                            Text("Channel: \(status)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .accessibilityIdentifier("lobby.root")
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle(service.role == .host ? "Ma partie" : "Salon")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { leaveToolbarItem }
        .toolbar { startToolbarItem }
        .confirmationDialog("Quitter la partie ?",
                            isPresented: $showingLeaveConfirm,
                            titleVisibility: .visible) {
            Button("Quitter", role: .destructive) { performLeave() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vous serez retiré de la manche en cours. Vous pourrez revenir avec le code.")
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
        .onChange(of: service.room?.participants.count) { _, count in
            // Hook QA `-autoStartAt N` : l'hôte lance la partie dès N joueurs.
            #if DEBUG
            if let n = QALaunchOptions.autoStartAt, service.role == .host,
               let c = count, c >= n, !pendingStart, service.room?.status == .lobby {
                startGame()
            }
            #endif
        }
        .onChange(of: service.room?.linePrice) { _, newValue in
            // Mise à jour push du host → reflète dans le champ si on n'est pas en train de taper
            if !priceFieldFocused, let v = newValue {
                linePriceText = formatPriceForField(v)
            }
        }
        // Note : pas de .onDisappear ici — le leave est géré au niveau du
        // Group dans `body` pour ne fire qu'au pop réel du nav stack.
    }

    // MARK: - Toolbar : Quitter (geste explicite, T03b)

    @ToolbarContentBuilder
    private var leaveToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if service.room?.status == .playing {
                    showingLeaveConfirm = true
                } else {
                    performLeave()
                }
            } label: {
                Text("Quitter")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Theme.brandRed)
            .accessibilityIdentifier("lobby.leave")
        }
    }

    // MARK: - Toolbar : Démarrer (host only, opacité faible quand indispo)

    @ToolbarContentBuilder
    private var startToolbarItem: some ToolbarContent {
        if service.role == .host, let room = service.room {
            let canStart = room.participants.count >= 2 && !pendingStart
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startGame) {
                    if pendingStart {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Start")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .tint(Theme.brandRed)
                .accessibilityIdentifier("lobby.start")
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.35)
            }
        }
    }

    // MARK: - Section : code (badge noir/blanc, compact)

    @ViewBuilder
    private func codeSection(_ code: String) -> some View {
        Section {
            VStack(spacing: 6) {
                Text("Code de la partie")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(Color(.systemBackground).opacity(0.55))

                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(Color(.systemBackground)) // blanc en light, noir en dark
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("lobby.code")

                Button {
                    UIPasteboard.general.string = code
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                        Text("Copier")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color(.systemBackground).opacity(0.15))
                            .overlay(
                                Capsule()
                                    .stroke(Color(.systemBackground).opacity(0.18), lineWidth: 1)
                            )
                    )
                    .foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lobby.copyCode")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary) // noir en light, blanc en dark
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Section : settings

    @ViewBuilder
    private func settingsSection(_ room: OnlineRoom) -> some View {
        let isHost = (service.role == .host)

        Section {
            if isHost {
                hostSettingsRows(room: room)
            } else {
                guestSettingsRows(room: room)
            }
        } header: {
            Text("Réglages")
        }
    }

    @ViewBuilder
    private func hostSettingsRows(room: OnlineRoom) -> some View {
        // Prix de la ligne — pattern Zmeo : TextField + barre clavier custom
        linePriceRow(room: room, isHost: true)

        // Timer par annonce — Picker compact (menu)
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

        // Mode Flash
        Toggle("Mode Flash", isOn: flashBinding)
            .tint(Theme.brandRed)
    }

    @ViewBuilder
    private func guestSettingsRows(room: OnlineRoom) -> some View {
        readOnlyRow(label: "Prix de la ligne", value: formatPrice(room.linePrice))
        readOnlyRow(label: "Timer par annonce",
                    value: room.announceTimerSeconds == 0
                        ? "Désactivé"
                        : "\(room.announceTimerSeconds) s")
        readOnlyRow(label: "Mode Flash", value: room.flashMode ? "Activé" : "Désactivé")
    }

    @ViewBuilder
    private func readOnlyRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formatPrice(_ p: Double) -> String {
        if p.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f €", p)
        }
        return String(format: "%.1f €", p).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Section : joueurs

    @ViewBuilder
    private func playersSection(_ players: [OnlineParticipant]) -> some View {
        Section {
            ForEach(players) { p in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(String(p.displayName.prefix(1)).uppercased())
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white)
                        )
                    Text(p.displayName)
                        .font(.subheadline)
                    if p.isHost {
                        Text("HOST")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.brandRed.opacity(0.1)))
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Joueurs")
                Spacer()
                Text("\(players.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lobby.playerCount")
            }
        }
    }

    // MARK: - Prix de la ligne (Zmeo-style row)

    private static let minPrice: Double = 0.5
    private static let maxPrice: Double = 50
    private static let priceStep: Double = 0.5

    @ViewBuilder
    private func linePriceRow(room: OnlineRoom, isHost: Bool) -> some View {
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
                        if !focused { syncPriceTextFromService() }
                    }

                Text("€")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Barre clavier custom en pilule liquid glass (iOS 26+) avec fallback material.
    /// Layout : [−] [+]  …  [✓]
    @ViewBuilder
    private var keyboardAccessoryBar: some View {
        let cur = service.room?.linePrice ?? 2.5
        let canDec = cur > Self.minPrice
        let canInc = cur < Self.maxPrice

        HStack(spacing: 8) {
            // Plus
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

            // Minus
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

            // Validation
            Button {
                syncPriceTextFromService()
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

    private func handlePriceTextChange(_ raw: String) {
        // Garde uniquement les chiffres + 1 séparateur (. ou ,), normalisé en ","
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
            // Commit live tant que la valeur est valide
            Task { await service.updateSettings(linePrice: v) }
        }
    }

    /// Force le texte à refléter la valeur autoritaire du service (utile au blur
    /// si l'utilisateur a tapé un truc invalide, ou si la valeur a été modifiée
    /// par un autre client).
    private func syncPriceTextFromService() {
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

    private func commitPrice(_ value: Double) {
        linePriceText = formatPriceForField(value)
        Task { await service.updateSettings(linePrice: value) }
    }

    // MARK: - Settings bindings

    private static let timerOptions: [Int] = [20, 30, 40, 50, 60, 90]

    private var flashBinding: Binding<Bool> {
        Binding(
            get: { service.room?.flashMode ?? false },
            set: { v in Task { await service.updateSettings(flashMode: v) } }
        )
    }

    private var linePriceBinding: Binding<Double> {
        Binding(
            get: { service.room?.linePrice ?? 2.5 },
            set: { v in Task { await service.updateSettings(linePrice: v) } }
        )
    }

    private var timerBinding: Binding<Int> {
        Binding(
            get: { service.room?.announceTimerSeconds ?? 0 },
            set: { v in Task { await service.updateSettings(announceTimerSeconds: v) } }
        )
    }

    private var connectingLabel: String {
        switch service.phase {
        case .connecting: return "Connexion…"
        case .lobby:      return "Préparation du salon…"
        default:          return ""
        }
    }

    // MARK: - Actions

    private func startGame() {
        Task {
            pendingStart = true
            await service.startGame()
            pendingStart = false
        }
    }

    /// Départ explicite — le seul chemin qui appelle `service.leave()`.
    private func performLeave() {
        Task { await service.leave() }
    }
}

/// Pilule liquid glass : utilise `.glassEffect` sur iOS 26+, fallback matériau
/// `.ultraThinMaterial` sur les versions antérieures.
