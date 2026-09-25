//
//  OnlineGameView.swift
//  Bakarat
//
//  Layout per-board :
//    1. Phase banner (3 dos de cartes brûlés au lieu de flammes)
//    2. 3 sections de board, chacune : 5 cartes + statut des joueurs en dessous
//       (soumis/attente pendant l'annonce, gagnant + bouton "Autres mains" après
//       reveal)
//    3. Ma main (drag-and-drop + tap-to-select pendant l'annonce)
//    4. Panel d'annonce (sans la sélection des cartes — faite dans la main)
//
//  Sizing : largeur des cartes calculée dynamiquement via GeometryReader.
//    - board : (width - paddings) / 5
//    - main  : (width - paddings) / 6
//
//  Swipe-back navigation désactivé une fois la partie lancée.
//

import SwiftUI

struct OnlineGameView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService

    // Paddings utilisés pour le sizing dynamique
    private let outerHPadding: CGFloat = 14
    private let boardInnerHPadding: CGFloat = 24 // 12pt * 2 (background padding)
    private let boardCardGap: CGFloat = 5
    private let handCardGap: CGFloat = 3
    // Layout de la bulle "ma main" pinnée en safeAreaInset(.bottom)
    private let handBubbleOuterMargin: CGFloat = 12   // marge écran → bulle
    private let handBubbleInnerPadding: CGFloat = 14  // bulle → cartes
    private let handBubbleCornerRadius: CGFloat = 26

    /// Ordre local des cartes en main pour drag-and-drop + tri d'affichage.
    @State private var handOrder: [Card] = []
    /// Catégorie d'annonce choisie (sélection live).
    @State private var selectedCategory: HandCategory? = nil
    /// Cartes sélectionnées pour l'annonce (depuis la main au-dessus).
    @State private var selectedCards: [Card] = []
    /// Cible du sheet "Autres mains" — board régulier ou tie-break. nil = fermé.
    @State private var sheetTarget: AllHandsTarget? = nil
    /// Flash mode : cartes face-down peek-révélées localement (jamais broadcast).
    /// Reset à chaque nouvelle manche.
    @State private var localFlippedCards: Set<Card> = []
    /// Flash mode : les 2 dernières cartes distribuées (donc visibles publiquement
    /// dans la teaser section ET dans ma main). Capturé au moment de la
    /// distribution puisque c'est fixé par l'ordre du deal, pas par mon tri.
    @State private var publicCards: Set<Card> = []
    /// Affiche le sheet Solde & historique (toolbar trailing).
    @State private var showingBalanceSheet = false
    /// Affiche le sheet Réglages mi-partie (toolbar leading).
    @State private var showingSettingsSheet = false
    /// Affiche le popover de la liste des spectateurs (toolbar trailing).
    @State private var showingSpectatorsPopover = false
    /// Incrémenté quand l'utilisateur tape Confirmer sans avoir sélectionné de
    /// carte requise → déclenche l'animation shake des cartes.
    @State private var shakeNonce: Int = 0
    /// Flag transient : cadran rouge sur les cartes pendant ~1.5s après un
    /// confirm raté (catégorie sélectionnée mais 0 carte). Auto-clear.
    @State private var promptCardSelection: Bool = false
    /// Message transitoire « X anime maintenant la partie » (relève d'hôte).
    @State private var hostChangeMessage: String? = nil
    /// Jeton d'annulation de la bannière précédente.
    @State private var hostBannerNonce: Int = 0

    var body: some View {
        GeometryReader { geo in
            let availableW = geo.size.width
            let availableH = geo.size.height
            let isLandscape = availableW > availableH
            Group {
                if isLandscape {
                    landscapeBody(availableW: availableW, availableH: availableH)
                } else {
                    portraitBody(availableW: availableW, availableH: availableH)
                }
            }
        }
        .accessibilityIdentifier("game.root")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true) // pas de retour accidentel en partie
        .toolbar(.hidden, for: .tabBar)      // masque la tabbar pendant la partie
        .toolbar {
            ToolbarItem(placement: .principal) {
                navTitleView
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .tint(Theme.brandRed)
                .accessibilityIdentifier("game.settings")
            }
            // Spectator count : visible UNIQUEMENT s'il y a au moins 1 spectateur
            // ou joueur en attente pour la prochaine manche. Chiffre AVANT l'œil.
            if spectatorCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSpectatorsPopover = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(spectatorCount)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Image(systemName: "eye")
                        }
                    }
                    .tint(Theme.brandRed)
                    .popover(isPresented: $showingSpectatorsPopover) {
                        spectatorsPopover
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingBalanceSheet = true
                } label: {
                    Image(systemName: "eurosign.circle")
                }
                .tint(Theme.brandRed)
                .accessibilityIdentifier("game.balance")
            }
        }
        .sheet(isPresented: $showingBalanceSheet) {
            if let room = service.room {
                BalanceHistorySheet(
                    room: room,
                    isHost: service.role == .host,
                    onKick: { seat in
                        Task { await service.kickPlayer(seat: seat) }
                    }
                )
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            MidGameSettingsSheet(service: service)
        }
        .task(id: service.room?.gameState?.hands[mySeat() ?? -1]) {
            let h = service.room?.gameState?.hands[mySeat() ?? -1] ?? []
            // Les 2 dernières cartes du deal sont publiques en Flash mode.
            publicCards = Set(h.suffix(2))
            await dealHandAnimated(target: h)
        }
        .onChange(of: service.room?.gameState?.currentBoard) {
            // Reset la sélection à chaque changement de board (ou phase non-announce).
            selectedCategory = nil
            selectedCards = []
        }
        .onChange(of: service.room?.gameState?.phase) { _, newPhase in
            if newPhase != .announcing && newPhase != .tiebreakAnnouncing {
                selectedCategory = nil
                selectedCards = []
            }
        }
        .onChange(of: service.room?.gameState?.mancheNumber) {
            // Nouvelle manche → reset les cartes flippées localement (Flash mode).
            localFlippedCards = []
        }
        .sheet(item: $sheetTarget) { target in
            if let gs = service.room?.gameState {
                AllHandsSheet(gs: gs, target: target)
            }
        }
        // Bannière de relève d'hôte + reconnexion (T22/T20).
        .overlay(alignment: .top) { statusBanner }
        .onChange(of: service.hostDisplayName) { oldName, newName in
            guard oldName != nil, let newName, !newName.isEmpty else { return }
            hostChangeMessage = "\(newName) anime maintenant la partie"
            hostBannerNonce += 1
            let nonce = hostBannerNonce
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if hostBannerNonce == nonce { hostChangeMessage = nil }
            }
        }
    }

    // MARK: - Bannière d'état (reconnexion / relève d'hôte)

    @ViewBuilder
    private var statusBanner: some View {
        if let message = bannerMessage {
            HStack(spacing: 8) {
                if service.connectionState != .connected {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .accessibilityIdentifier("game.banner")
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: message)
        }
    }

    private var bannerMessage: String? {
        if service.connectionState == .offline { return "Hors ligne — reconnexion…" }
        if service.connectionState == .reconnecting || service.isReconnecting { return "Reconnexion…" }
        return hostChangeMessage
    }

    // MARK: - Sizing helpers

    /// Largeur d'une carte board (5 cartes par row). Calcul width-based pur :
    /// en landscape le body split contraint déjà la largeur de la colonne, pas
    /// besoin de cap par hauteur.
    private func boardCardW(_ availableW: CGFloat, _ availableH: CGFloat) -> CGFloat {
        let usable = availableW - 2 * outerHPadding - boardInnerHPadding
        let gaps = boardCardGap * 4
        let widthBased = floor((usable - gaps) / 5)
        return max(20, widthBased)
    }

    /// Largeur d'une carte de la main (6 par row).
    private func handCardW(_ availableW: CGFloat, _ availableH: CGFloat) -> CGFloat {
        let usable = availableW - 2 * (handBubbleOuterMargin + handBubbleInnerPadding)
        let gaps = handCardGap * 5
        let widthBased = floor((usable - gaps) / 6)
        return max(20, widthBased)
    }

    // MARK: - Phase banner

    /// Section Flash mode : 2 cartes publiques de chaque joueur en jeu,
    /// affichée au-dessus du Board 1 jusqu'à la fin de ce board.
    @ViewBuilder
    private func flashTeaserSection(_ gs: OnlineGameState) -> some View {
        // Exclut le current user — il voit déjà sa main complète en bas.
        let myUid = auth.userId
        let active = gs.players.filter {
            $0.inManche &&
            (gs.hands[$0.seat]?.count ?? 0) >= 2 &&
            $0.userId != myUid
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Theme.brandRed)
                Text("Cartes ouvertes")
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(active) { p in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text(String(p.displayName.prefix(1)).uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            )
                        Text(p.displayName)
                            .font(.subheadline)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array((gs.hands[p.seat] ?? []).suffix(2)), id: \.self) { c in
                                CardImageView(card: c, width: 30)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Chip "Brûlées" affichée en haut du scroll. Les 3 cartes apparaissent
    /// PROGRESSIVEMENT (1 avant le flop, 1 avant le turn, 1 avant le river)
    /// via gs.burnsRevealed. À mancheEnd, elles flippent face up.
    @ViewBuilder
    private func burnsChip(_ gs: OnlineGameState) -> some View {
        let revealedFaceUp = (gs.phase == .mancheEnd)
        let burnW: CGFloat = 32
        let burnH: CGFloat = burnW * 7 / 5
        HStack(spacing: 8) {
            Text("Brûlées")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Group {
                        if i < gs.burnsRevealed {
                            if revealedFaceUp && i < gs.burns.count {
                                CardImageView(card: gs.burns[i], width: burnW)
                            } else {
                                CardImageView(card: nil, faceDown: true, width: burnW)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color(.tertiaryLabel),
                                              style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                                .frame(width: burnW, height: burnH)
                        }
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: gs.burnsRevealed)
            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: revealedFaceUp)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Board section

    @ViewBuilder
    private func boardSection(_ gs: OnlineGameState, idx: Int,
                              availableW: CGFloat, availableH: CGFloat) -> some View {
        let cards = gs.communityCards[idx]
        let result = gs.boardResults[idx]
        let isActive = (gs.phase == .announcing || gs.phase == .boardReveal)
                       && gs.currentBoard == idx
        let cardW = boardCardW(availableW, availableH)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Board \(idx + 1)")
                    .accessibilityIdentifier("game.board\(idx + 1).title")
                    .accessibilityValue("\(cards.count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isActive ? Theme.brandRed : .primary)
                if isActive && gs.phase == .announcing {
                    Text("· annonces en cours")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: boardCardGap) {
                ForEach(0..<5, id: \.self) { k in
                    Group {
                        if k < cards.count {
                            CardImageView(card: cards[k], width: cardW)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.3).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        } else {
                            CardImageView(card: nil, width: cardW)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.7),
                               value: cards.count)
                }
            }

            statusFooter(gs: gs, boardIdx: idx, result: result, isActive: isActive)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.brandRed.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func statusFooter(gs: OnlineGameState,
                              boardIdx: Int,
                              result: BoardResult?,
                              isActive: Bool) -> some View {
        if let result {
            revealedFooter(gs: gs, boardIdx: boardIdx, result: result)
        } else if isActive && gs.phase == .announcing {
            submissionRow(gs)
        } else {
            playerNamesRow(gs: gs, dimmed: true)
        }
    }

    @ViewBuilder
    private func submissionRow(_ gs: OnlineGameState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(gs.players) { p in
                    statusChip(name: p.displayName,
                               iconName: gs.submissions[p.seat] != nil ? "checkmark.circle.fill" : "hourglass",
                               iconColor: gs.submissions[p.seat] != nil ? .green : .orange)
                }
            }
        }
    }

    @ViewBuilder
    private func playerNamesRow(gs: OnlineGameState, dimmed: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(gs.players) { p in
                Text(p.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(dimmed ? .tertiary : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(.tertiarySystemBackground).opacity(dimmed ? 0.5 : 1))
                    )
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func revealedFooter(gs: OnlineGameState,
                                boardIdx: Int,
                                result: BoardResult) -> some View {
        if result.abandoned {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.gray)
                Text("Board abandonné")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                autresMainsButton(target: .board(idx: boardIdx))
            }
        } else if result.isSplit && result.winnerSeat == nil {
            // Le board est en cours de résolution via tie-break. On affiche
            // un état "Split" clair en attendant que le tiebreak résolve.
            HStack(spacing: 10) {
                Text("⚡").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.brandRed)
                    Text("Tie-break en cours…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                autresMainsButton(target: .board(idx: boardIdx))
            }
        } else if let winnerSeat = result.winnerSeat,
                  let winner = gs.players.first(where: { $0.seat == winnerSeat }),
                  let catId = result.winningCategoryId,
                  let cat = HandCategory.from(id: catId) {
            // On affiche UNIQUEMENT les cartes que le gagnant a annoncées, pas
            // toute sa main. Si annonce auto (Hauteur, cards vides) → autoPick.
            let winnerRow = result.perPlayer.first(where: { $0.seat == winnerSeat })
            let displayedCards: [Card] = {
                if let row = winnerRow, !row.cards.isEmpty { return row.cards }
                // Main du gagnant inconnue (état expurgé côté guest — T14) :
                // on se rabat sur les cartes qu'il a soumises.
                if let hole = gs.hands[winnerSeat], !hole.isEmpty {
                    return HandEvaluator.autoPickCards(announced: cat,
                                                       hole: hole,
                                                       board: gs.communityCards[boardIdx]) ?? []
                }
                return winnerRow?.cards ?? []
            }()
            HStack(spacing: 10) {
                Text(result.isSplit ? "⚡" : "🏆")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(winner.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(cat.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brandRed)
                            .lineLimit(1)
                        if cat.multi > 1 {
                            Text("×\(cat.multi)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.brandRed)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.brandRed.opacity(0.15)))
                        }
                    }
                }
                HStack(spacing: 3) {
                    ForEach(displayedCards, id: \.self) { c in
                        CardImageView(card: c, width: 28)
                    }
                }
                Spacer()
                autresMainsButton(target: .board(idx: boardIdx))
            }
        }
    }

    @ViewBuilder
    private func autresMainsButton(target: AllHandsTarget) -> some View {
        Button {
            sheetTarget = target
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption2)
                Text("More")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemBackground)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusChip(name: String, iconName: String, iconColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color(.tertiarySystemBackground)))
    }

    // MARK: - Hand bubble (drag-drop + tap-to-select + announce intégré)

    /// Contenu de la bulle : main au-dessus, annonce (grille 3×3 + Confirmer)
    /// en dessous. Identique en portrait et en landscape — en landscape la
    /// bulle vit dans la colonne droite (~40% de l'écran), assez large pour
    /// la grille 3×3.
    @ViewBuilder
    private func handBubble(_ gs: OnlineGameState, seat: Int,
                            availableW: CGFloat, availableH: CGFloat) -> some View {
        let showAnnounce = (gs.phase == .announcing || gs.phase == .tiebreakAnnouncing)
        VStack(alignment: .leading, spacing: 12) {
            handCardsRow(gs, seat: seat, availableW: availableW, availableH: availableH)
            if showAnnounce {
                announceContent(gs, seat: seat, isLandscape: false)
            }
        }
    }

    /// La rangée de cartes de la main (sans header — le score et le badge
    /// donneur ne sont plus dans la bulle, ils sont visibles via le bouton
    /// solde en haut à droite et au mancheEnd).
    @ViewBuilder
    private func handCardsRow(_ gs: OnlineGameState, seat: Int,
                              availableW: CGFloat, availableH: CGFloat) -> some View {
        let cardW = handCardW(availableW, availableH)
        let canSelect: Bool = {
            if gs.phase == .announcing && gs.submissions[seat] == nil { return true }
            if gs.phase == .tiebreakAnnouncing,
               let tb = gs.tiebreakBoards.last,
               tb.eligibleSeats.contains(seat),
               tb.submissions[seat] == nil { return true }
            return false
        }()
        let flashMode = service.room?.flashMode ?? false
        // Le cadran rouge n'apparaît qu'après un confirm raté (catégorie ≠
        // Hauteur + 0 carte). Auto-clear via `promptCardSelection`. Pas de
        // signal continu — on laisse le joueur libre tant qu'il n'a pas tenté
        // de confirmer.
        let needsCards = canSelect && promptCardSelection
        HStack(spacing: handCardGap) {
            ForEach(Array(handOrder.enumerated()), id: \.element) { idx, c in
                let isFaceDown = flashMode
                                 && !publicCards.contains(c)
                                 && !localFlippedCards.contains(c)
                handCardView(c, width: cardW, idx: idx,
                             canSelect: canSelect, faceDown: isFaceDown,
                             needsAction: needsCards)
            }
        }
        // Padding top pour que la levée -10pt des cartes sélectionnées ne
        // dépasse pas le bord supérieur de la bulle liquid-glass.
        .padding(.top, 12)
        .modifier(ShakeEffect(animatableData: CGFloat(shakeNonce)))
    }

    @ViewBuilder
    private func handCardView(_ c: Card, width: CGFloat, idx: Int,
                              canSelect: Bool, faceDown: Bool,
                              needsAction: Bool = false) -> some View {
        let isSelected = selectedCards.contains(c)
        let borderColor: Color = {
            if isSelected { return Theme.brandRed }
            if needsAction { return Color.red.opacity(0.65) }
            return .clear
        }()
        let borderWidth: CGFloat = isSelected ? 2.5 : (needsAction ? 2 : 0)
        CardImageView(card: c, faceDown: faceDown, width: width)
            .overlay(
                RoundedRectangle(cornerRadius: max(4, width * 0.075), style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .offset(y: isSelected ? -10 : 0)
            // XCUITest : une Image SwiftUI décorative n'est pas un élément
            // d'accessibilité — sans `accessibilityElement()` l'identifiant
            // « game.hand.cardN » n'est jamais exposé au tour.
            .accessibilityElement()
            .accessibilityLabel(Text(faceDown ? "Carte face cachée" : c.description))
            .accessibilityIdentifier("game.hand.card\(idx)")
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .onTapGesture {
                if faceDown {
                    // Flash mode peek : flippe localement (persisté pour la manche)
                    localFlippedCards.insert(c)
                } else if canSelect {
                    toggleSelection(c)
                }
            }
            .draggable(c)
            .dropDestination(for: Card.self) { droppedCards, _ in
                handleDrop(droppedCards, atIndex: idx)
            }
            .transition(.scale(scale: 0.3).combined(with: .opacity))
            .animation(.spring(response: 0.5, dampingFraction: 0.7),
                       value: handOrder.count)
    }

    // MARK: - Announce panel

    @ViewBuilder
    private func announceContent(_ gs: OnlineGameState, seat: Int,
                                 isLandscape: Bool) -> some View {
        let isTiebreak = gs.phase == .tiebreakAnnouncing
        let lockedCat: HandCategory? = isTiebreak ? tiebreakLockedCategory(gs) : nil
        let activeTb = gs.tiebreakBoards.last
        let alreadySubmitted: Bool = isTiebreak
            ? (activeTb?.submissions[seat] != nil)
            : (gs.submissions[seat] != nil)
        let isEligible: Bool = isTiebreak
            ? (activeTb?.eligibleSeats.contains(seat) ?? false)
            : true

        Group {
            if isTiebreak && !isEligible {
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(.secondary)
                    Text("Tu n'es pas concerné par ce tie-break.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                let boardCardsForAnnounce = isTiebreak
                    ? (activeTb?.cards ?? [])
                    : gs.communityCards[gs.currentBoard]
                AnnouncePanel(
                    alreadySubmitted: alreadySubmitted,
                    lockedCategory: lockedCat,
                    boardCards: boardCardsForAnnounce,
                    myHole: gs.hands[seat] ?? [],
                    allCommunityCards: gs.communityCards,
                    selectedCategory: $selectedCategory,
                    selectedCards: selectedCards,
                    onConfirm: {
                        let cat = lockedCat ?? selectedCategory ?? .highcard
                        // RULES.md § « Auto-pick vs sélection manuelle » :
                        // « Hauteur : auto-pick par défaut — l'app choisit les
                        // 2 meilleures cartes du joueur. Pas besoin de
                        // sélectionner. » → Hauteur sans sélection (y compris
                        // tie-break verrouillé sur Hauteur) = auto-pick.
                        if cat == .highcard && selectedCards.isEmpty,
                           let auto = HandEvaluator.autoPickCards(
                               announced: .highcard,
                               hole: gs.hands[seat] ?? [],
                               board: boardCardsForAnnounce) {
                            let submission = BoardSubmission(categoryId: cat.id, cards: auto)
                            Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                            return
                        }
                        // Les autres catégories exigent au moins 1 carte
                        // sélectionnée pour éviter les taps accidentels.
                        // 0 carte → shake les cartes + cadran rouge transient.
                        if selectedCards.isEmpty {
                            withAnimation(.linear(duration: 0.4)) {
                                shakeNonce += 1
                            }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                promptCardSelection = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                await MainActor.run {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        promptCardSelection = false
                                    }
                                }
                            }
                            return
                        }
                        let cards: [Card] = {
                            let hole = gs.hands[seat] ?? []
                            // 1 seule carte (Hauteur ou autre) → kicker = plus
                            // haute carte restante de la main.
                            if selectedCards.count == 1 {
                                let remaining = hole.filter { !selectedCards.contains($0) }
                                if let kicker = remaining.max(by: { $0.rank.value < $1.rank.value }) {
                                    return selectedCards + [kicker]
                                }
                            }
                            return selectedCards
                        }()
                        let submission = BoardSubmission(categoryId: cat.id, cards: cards)
                        Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                    },
                    onSkip: {
                        let submission = BoardSubmission(categoryId: "skip", cards: [])
                        Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                    },
                    showSkip: false,
                    isLandscape: isLandscape
                )
            }
        }
    }

    private func tiebreakLockedCategory(_ gs: OnlineGameState) -> HandCategory? {
        guard let tb = gs.tiebreakBoards.last,
              let parent = gs.boardResults[tb.parentBoardIdx],
              let catId = parent.winningCategoryId else { return nil }
        return HandCategory.from(id: catId)
    }

    // MARK: - Tie-break board section

    @ViewBuilder
    private func tiebreakBoardSection(_ gs: OnlineGameState, tb: TiebreakBoard,
                                      availableW: CGFloat, availableH: CGFloat) -> some View {
        let cardW = boardCardW(availableW, availableH)
        let isActive = (gs.phase == .tiebreakAnnouncing || gs.phase == .tiebreakReveal)
                       && gs.tiebreakBoards.last?.id == tb.id

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.brandRed)
                    .font(.caption)
                Text("Tie-break Board \(tb.parentBoardIdx + 1)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isActive ? Theme.brandRed : .primary)
                Text("round \(tb.round + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 5) {
                ForEach(Array(tb.cards.enumerated()), id: \.offset) { _, c in
                    CardImageView(card: c, width: cardW)
                }
            }

            if let result = tb.result {
                tiebreakResultFooter(gs: gs, tb: tb, result: result)
            } else if isActive && gs.phase == .tiebreakAnnouncing {
                tiebreakSubmissionRow(gs: gs, tb: tb)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.brandRed.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func tiebreakSubmissionRow(gs: OnlineGameState, tb: TiebreakBoard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tb.eligibleSeats, id: \.self) { seat in
                    if let p = gs.players.first(where: { $0.seat == seat }) {
                        statusChip(name: p.displayName,
                                   iconName: tb.submissions[seat] != nil ? "checkmark.circle.fill" : "hourglass",
                                   iconColor: tb.submissions[seat] != nil ? .green : .orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tiebreakResultFooter(gs: OnlineGameState,
                                      tb: TiebreakBoard,
                                      result: BoardResult) -> some View {
        let target: AllHandsTarget = .tiebreak(parent: tb.parentBoardIdx, round: tb.round)
        if result.isSplit {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Re-split")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    Text("Nouveau round nécessaire")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                autresMainsButton(target: target)
            }
        } else if let winnerSeat = result.winnerSeat,
                  let winner = gs.players.first(where: { $0.seat == winnerSeat }),
                  let catId = result.winningCategoryId,
                  let cat = HandCategory.from(id: catId) {
            // Mêmes éléments que pour un board régulier : trophée + nom +
            // catégorie + multi + cartes annoncées du winner + bouton More.
            let winnerRow = result.perPlayer.first(where: { $0.seat == winnerSeat })
            let displayedCards: [Card] = {
                if let row = winnerRow, !row.cards.isEmpty { return row.cards }
                // Idem tie-break : à défaut de main, les cartes soumises.
                if let hole = gs.hands[winnerSeat], !hole.isEmpty {
                    return HandEvaluator.autoPickCards(announced: cat,
                                                       hole: hole,
                                                       board: tb.cards) ?? []
                }
                return winnerRow?.cards ?? []
            }()
            HStack(spacing: 10) {
                Text("🏆").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(winner.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(cat.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brandRed)
                            .lineLimit(1)
                        if cat.multi > 1 {
                            Text("×\(cat.multi)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.brandRed)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.brandRed.opacity(0.15)))
                        }
                    }
                }
                HStack(spacing: 3) {
                    ForEach(displayedCards, id: \.self) { c in
                        CardImageView(card: c, width: 28)
                    }
                }
                Spacer()
                autresMainsButton(target: target)
            }
        }
    }

    // MARK: - Manche end

    @ViewBuilder
    private func mancheEndPanel(_ gs: OnlineGameState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Manche \(gs.mancheNumber) terminée")
                    .accessibilityIdentifier("game.mancheEnd")
                    .font(.subheadline.weight(.bold))
                Spacer()
            }

            if let fbSeat = gs.fullBoardWinnerSeat,
               let fbWinner = gs.players.first(where: { $0.seat == fbSeat }) {
                HStack(spacing: 8) {
                    Text("🌟")
                    Text("Full board pour \(fbWinner.displayName) !")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brandRed)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.brandRed.opacity(0.10))
                )
            }


            // Scores — delta de la manche + cumul total entre parenthèses.
            VStack(spacing: 6) {
                ForEach(gs.players.sorted { $0.score > $1.score }) { p in
                    let initial = gs.initialScores[p.seat] ?? p.score
                    let delta = p.score - initial
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Text(String(p.displayName.prefix(1)).uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            )
                        Text(p.displayName).font(.subheadline)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(formatSignedDelta(delta))
                                .font(.subheadline.monospacedDigit().weight(.bold))
                                .foregroundStyle(deltaColor(delta))
                            Text("(Total \(formatScore(p.score)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                }
            }

            if service.role == .host {
                Button {
                    Task { await service.startNextManche() }
                } label: {
                    Text("Manche suivante")
                        .modifier(PrimaryButtonStyle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("game.nextManche")
            } else {
                Label("En attente que l'hôte démarre la suivante…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Selection helpers

    private func toggleSelection(_ card: Card) {
        if let i = selectedCards.firstIndex(of: card) {
            selectedCards.remove(at: i)
        } else if selectedCards.count < 2 {
            selectedCards.append(card)
        } else {
            selectedCards.removeFirst()
            selectedCards.append(card)
        }
    }

    // MARK: - Drag & drop helpers

    @discardableResult
    private func handleDrop(_ droppedCards: [Card], atIndex targetIdx: Int) -> Bool {
        guard let dropped = droppedCards.first,
              let fromIdx = handOrder.firstIndex(of: dropped),
              fromIdx != targetIdx else { return false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            handOrder.remove(at: fromIdx)
            handOrder.insert(dropped, at: min(targetIdx, handOrder.count))
        }
        return true
    }

    /// Distribue la main visible 2 cartes à la fois avec un petit suspense
    /// entre chaque paire. Garde l'ordre utilisateur pour les cartes déjà en
    /// main (drag-drop préservé).
    ///
    /// IMPORTANT (mode Flash) : les 2 dernières cartes DU DEAL doivent toujours
    /// apparaître aux 2 dernières positions de la main (les seules face-up).
    /// On trie les premières cartes par rang desc, mais on garde les 2
    /// dernières du deal en place à la fin.
    @MainActor
    private func dealHandAnimated(target: [Card]) async {
        let targetSet = Set(target)
        let kept = handOrder.filter { targetSet.contains($0) }
        let keptSet = Set(kept)
        // Nouvelles cartes (en ordre du deal préservé)
        let added = target.filter { !keptSet.contains($0) }

        if added.isEmpty {
            if kept != handOrder { handOrder = kept }
            return
        }
        handOrder = kept

        // Découpe : les 2 dernières du deal (= les publiques en Flash) restent
        // à la fin, les autres sont triées par rang desc.
        let tailCount = min(2, added.count)
        let dealLast = Array(added.suffix(tailCount))
        let dealFirst = Array(added.dropLast(tailCount))
            .sorted { sortKey($0) > sortKey($1) }
        let orderedAdded = dealFirst + dealLast

        var remaining = orderedAdded
        while !remaining.isEmpty {
            let take = min(2, remaining.count)
            let pair = Array(remaining.prefix(take))
            remaining.removeFirst(take)
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                handOrder.append(contentsOf: pair)
            }
        }
    }

    private func sortKey(_ card: Card) -> Int {
        // Rang en priorité (descendant), couleur en tiebreak.
        card.rank.value * 10 + suitOrder(card.suit)
    }

    private func suitOrder(_ suit: Suit) -> Int {
        switch suit {
        case .spades:   4
        case .hearts:   3
        case .diamonds: 2
        case .clubs:    1
        }
    }

    // MARK: - Body layouts

    /// Portrait : scroll vertical avec boards, bulle bottom en safeAreaInset.
    @ViewBuilder
    private func portraitBody(availableW: CGFloat, availableH: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    scrollContent(availableW: availableW, availableH: availableH)
                }
                .padding(.horizontal, outerHPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .modifier(BoardAutoScrollModifier(
                currentBoard: service.room?.gameState?.currentBoard,
                mancheNumber: service.room?.gameState?.mancheNumber,
                tiebreakRound: service.room?.gameState?.tiebreakBoards.last.map { "tb-\($0.parentBoardIdx)-\($0.round)" },
                anchor: .top,
                proxy: proxy
            ))
        }
        .safeAreaInset(edge: .bottom) {
            if let gs = service.room?.gameState,
               let seat = mySeat(in: gs),
               gs.hands[seat]?.isEmpty == false,
               gs.players.first(where: { $0.seat == seat })?.inManche == true {
                handBubble(gs, seat: seat,
                           availableW: availableW, availableH: availableH)
                    .padding(.horizontal, handBubbleInnerPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .modifier(HandBubbleLiquidGlass(cornerRadius: handBubbleCornerRadius))
                    .padding(.horizontal, handBubbleOuterMargin)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Landscape (Option A) : split vertical 50/50 — boards scrollables à
    /// gauche, panneau info + bulle main/annonce à droite. Quand on n'est
    /// PAS en phase d'annonce, un panneau "scores en cours" remplit la moitié
    /// haute du right column, en dehors de la bulle liquid-glass.
    @ViewBuilder
    private func landscapeBody(availableW: CGFloat, availableH: CGFloat) -> some View {
        let halfWidth = availableW / 2
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        scrollContent(availableW: halfWidth, availableH: availableH)
                    }
                    .padding(.horizontal, outerHPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .modifier(BoardAutoScrollModifier(
                    currentBoard: service.room?.gameState?.currentBoard,
                    mancheNumber: service.room?.gameState?.mancheNumber,
                    tiebreakRound: service.room?.gameState?.tiebreakBoards.last.map { "tb-\($0.parentBoardIdx)-\($0.round)" },
                    anchor: .center,
                    proxy: proxy
                ))
            }
            .frame(width: halfWidth)

            landscapeRightColumn(availableW: halfWidth, availableH: availableH)
                .frame(width: halfWidth)
        }
    }

    /// Colonne droite en landscape : info panel (top) + bulle hand/annonce (bottom).
    @ViewBuilder
    private func landscapeRightColumn(availableW: CGFloat, availableH: CGFloat) -> some View {
        let isAnnouncing = service.room?.gameState?.phase == .announcing
                           || service.room?.gameState?.phase == .tiebreakAnnouncing
        VStack(spacing: 8) {
            if !isAnnouncing, let gs = service.room?.gameState {
                landscapeInfoPanel(gs)
                    .padding(.horizontal, handBubbleOuterMargin)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
            if let gs = service.room?.gameState,
               let seat = mySeat(in: gs),
               gs.hands[seat]?.isEmpty == false,
               gs.players.first(where: { $0.seat == seat })?.inManche == true {
                handBubble(gs, seat: seat,
                           availableW: availableW, availableH: availableH)
                    .padding(.horizontal, handBubbleInnerPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .modifier(HandBubbleLiquidGlass(cornerRadius: handBubbleCornerRadius))
                    .padding(.horizontal, handBubbleOuterMargin)
                    .padding(.bottom, 18)
            }
        }
    }

    /// Panneau info à droite (hors bulle) : manche en cours + scores des joueurs.
    /// Affiché uniquement en landscape, et uniquement quand on n'est PAS en
    /// phase d'annonce (la bulle prend toute la place sinon).
    @ViewBuilder
    private func landscapeInfoPanel(_ gs: OnlineGameState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
                Text("Manche \(gs.mancheNumber) · Scores")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: 4) {
                ForEach(gs.players.sorted { $0.score > $1.score }) { p in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(p.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .opacity((!p.inManche || !p.connected) ? 0.4 : 1)
                        Text(p.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle((!p.inManche || !p.connected) ? .secondary : .primary)
                            .lineLimit(1)
                        if !p.connected {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        } else if !p.inManche {
                            Text("Spec")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatScore(p.score))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle((!p.inManche || !p.connected)
                                             ? Color.secondary
                                             : (p.score >= 0 ? Color.green : Color.red))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Contenu commun aux deux body layouts : brûlées + flash teaser + boards
    /// + tiebreaks + mancheEnd panel.
    @ViewBuilder
    private func scrollContent(availableW: CGFloat, availableH: CGFloat) -> some View {
        if let gs = service.room?.gameState {
            burnsChip(gs)
            if (service.room?.flashMode == true) && gs.currentBoard == 0 {
                flashTeaserSection(gs)
            }
            ForEach(0..<3, id: \.self) { idx in
                boardSection(gs, idx: idx, availableW: availableW, availableH: availableH)
                    .id("board-\(idx)")
            }
            ForEach(gs.tiebreakBoards) { tb in
                tiebreakBoardSection(gs, tb: tb, availableW: availableW, availableH: availableH)
                    .id("tb-\(tb.parentBoardIdx)-\(tb.round)")
            }
            if gs.phase == .mancheEnd {
                mancheEndPanel(gs)
            }
        } else {
            ProgressView().padding(.top, 60)
        }
    }

    // MARK: - Nav title dynamique (rythme de la partie)

    /// La nav title donne le rythme : "Distribution" / "Annonces · 27s" /
    /// "Reveal" / "Fin de manche". Le timer y est intégré directement —
    /// plus besoin de barre flottante au-dessus du scroll.
    @ViewBuilder
    private var navTitleView: some View {
        if let gs = service.room?.gameState {
            if (gs.phase == .announcing || gs.phase == .tiebreakAnnouncing),
               let deadline = gs.announceDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let now = ctx.date.timeIntervalSince1970
                    let remaining = max(0, Int(ceil(deadline - now)))
                    let label = navLabelForActiveBoard(gs)
                    let bg: Color = remaining <= 5 ? .red : .orange
                    Text("\(label) · \(remaining)s")
                        .accessibilityIdentifier("game.phaseLabel")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(bg))
                }
            } else {
                Text(phaseLabel(gs.phase))
                    .accessibilityIdentifier("game.phaseLabel")
                    .font(.subheadline.weight(.bold))
            }
        }
    }

    /// Label de la phase active dans la nav title : "B1"/"B2"/"B3" pour les
    /// annonces régulières, "Split"/"Split 2"/… pour les rounds de tie-break.
    private func navLabelForActiveBoard(_ gs: OnlineGameState) -> String {
        if gs.phase == .tiebreakAnnouncing {
            let round = gs.tiebreakBoards.last?.round ?? 0
            return round == 0 ? "Split" : "Split \(round + 1)"
        }
        return "B\(gs.currentBoard + 1)"
    }

    // MARK: - Spectator popover

    /// Tous ceux qui ne jouent PAS sur la manche courante : soit déjà dans
    /// gs.players avec inManche=false (spectateurs explicites ou déconnectés),
    /// soit des participants qui ont rejoint en cours de partie et qui n'ont
    /// donc pas encore de seat.
    private struct SpectatorEntry: Identifiable {
        let userId: UUID
        let displayName: String
        let connected: Bool
        let isMidGameJoiner: Bool
        var id: UUID { userId }
    }

    private var spectatorEntries: [SpectatorEntry] {
        guard let room = service.room else { return [] }
        let gs = room.gameState
        let activeIds = Set(gs?.players.filter { $0.inManche }.map { $0.userId } ?? [])

        return room.participants.compactMap { p -> SpectatorEntry? in
            if activeIds.contains(p.userId) { return nil }
            // S'il est dans gs.players, on sait si connecté ; sinon c'est un
            // mid-game joiner (toujours connecté par construction puisqu'il vient
            // d'envoyer hello).
            if let inState = gs?.players.first(where: { $0.userId == p.userId }) {
                return SpectatorEntry(
                    userId: p.userId,
                    displayName: p.displayName,
                    connected: inState.connected,
                    isMidGameJoiner: false
                )
            }
            return SpectatorEntry(
                userId: p.userId,
                displayName: p.displayName,
                connected: true,
                isMidGameJoiner: true
            )
        }
    }

    private var spectatorCount: Int { spectatorEntries.count }

    @ViewBuilder
    private var spectatorsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spectateurs")
                .font(.subheadline.weight(.bold))
            if spectatorEntries.isEmpty {
                Text("Aucun spectateur pour l'instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spectatorEntries) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(entry.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Text(entry.displayName)
                            .font(.subheadline)
                            .foregroundStyle(entry.connected ? .primary : .secondary)
                        if !entry.connected {
                            Image(systemName: "wifi.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if entry.isMidGameJoiner {
                            Text("Nouveau")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        }
                        Spacer()
                    }
                }
            }
            if isCurrentUserSpectator {
                Divider()
                Button {
                    showingSpectatorsPopover = false
                    Task { await service.setSelfSpectator(false) }
                } label: {
                    Label("Rejoindre la partie", systemImage: "arrow.uturn.left.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
                        .foregroundStyle(Theme.brandRed)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(minWidth: 240)
    }

    private var isCurrentUserSpectator: Bool {
        guard let uid = auth.userId else { return false }
        // Soit pas encore dans gs.players (mid-game joiner), soit présent mais inManche=false
        if let gs = service.room?.gameState {
            if let me = gs.players.first(where: { $0.userId == uid }) {
                return !me.inManche
            }
            // Pas dans gs.players → mid-game joiner = spectateur de fait
            return service.room?.participants.contains(where: { $0.userId == uid }) ?? false
        }
        return false
    }

    // MARK: - Helpers

    private var navigationTitle: String {
        guard let gs = service.room?.gameState else { return "Partie en cours" }
        return "Manche \(gs.mancheNumber)"
    }

    private func mySeat(in gs: OnlineGameState) -> Int? {
        guard let uid = auth.userId else { return nil }
        return gs.players.first(where: { $0.userId == uid })?.seat
    }

    private func mySeat() -> Int? {
        guard let gs = service.room?.gameState else { return nil }
        return mySeat(in: gs)
    }

    private func formatScore(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))€"
    }

    /// Delta signé "+X,XX€" / "−X,XX€" / "0€" — pour la fluctuation d'une manche.
    private func formatSignedDelta(_ v: Double) -> String {
        if abs(v) < 0.005 { return "0€" }
        let sign = v > 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.2f", abs(v)))€"
    }

    /// Couleur : vert si gain, rouge si perte, gris si nul.
    private func deltaColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : .red
    }

    private func phaseLabel(_ p: GamePhase) -> String {
        switch p {
        case .dealing:             return "Distribution…"
        case .flop:                return "Brûle + Flop"
        case .turn:                return "Brûle + Turn"
        case .river:               return "Brûle + River"
        case .announcing:          return "Annonces"
        case .boardReveal:         return "Reveal"
        case .tiebreakAnnouncing:  return "Tie-break — annonces"
        case .tiebreakReveal:      return "Tie-break — reveal"
        case .mancheEnd:           return "Fin de manche"
        }
    }

    private func phaseIcon(_ p: GamePhase) -> String {
        switch p {
        case .dealing:             return "rectangle.portrait.on.rectangle.portrait.angled"
        case .flop:                return "square.stack.3d.down.right"
        case .turn:                return "arrow.turn.right.up"
        case .river:               return "water.waves"
        case .announcing:          return "hand.raised"
        case .boardReveal:         return "eye"
        case .tiebreakAnnouncing:  return "bolt"
        case .tiebreakReveal:      return "bolt.fill"
        case .mancheEnd:           return "checkmark.circle"
        }
    }
}

/// GeometryEffect qui translate horizontalement en sinusoïdale — utilisé pour
/// secouer les cartes quand l'utilisateur tape Confirmer sans avoir sélectionné
/// les cartes requises.
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 9
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// Bulle flottante en rounded rect avec liquid glass (iOS 26+) ou
/// `.ultraThinMaterial` en fallback. Légère shadow pour le détacher du fond.
private struct HandBubbleLiquidGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(shape.fill(.ultraThinMaterial))
                    .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
    }
}

// MARK: - Auto-scroll modifier

/// Scroll automatique vers le board actif à chaque changement de phase :
/// - Changement de manche → scroll vers Board 1
/// - Changement de currentBoard → scroll vers ce board (1, puis 2, puis 3)
/// - Nouveau tiebreak → scroll vers ce tiebreak
///
/// L'anchor diffère selon l'orientation : `.top` en portrait (le board est
/// au-dessus de la sélection de cartes), `.center` en landscape (le board
/// reste au milieu de la colonne gauche). On délaie le scroll de quelques
/// dizaines de ms pour que SwiftUI ait d'abord rendu le nouveau contenu
/// (sinon scrollTo cible une ancienne géométrie).
private struct BoardAutoScrollModifier: ViewModifier {
    let currentBoard: Int?
    let mancheNumber: Int?
    let tiebreakRound: String?
    let anchor: UnitPoint
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onChange(of: mancheNumber) { _, _ in
                scrollTo("board-0")
            }
            .onChange(of: currentBoard) { _, new in
                guard let new else { return }
                scrollTo("board-\(new)")
            }
            .onChange(of: tiebreakRound) { _, new in
                guard let new else { return }
                scrollTo(new)
            }
    }

    private func scrollTo(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms : laisse le layout se faire
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }
}
