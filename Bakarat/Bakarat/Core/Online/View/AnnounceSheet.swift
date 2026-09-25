//
//  AnnouncePanel.swift (anciennement AnnounceSheet)
//  Bakarat
//
//  Panel d'annonce affiché en bas de l'OnlineGameView pendant la phase
//  `.announcing`. Présente la grille de catégories et le bouton de confirmation.
//  La sélection des cartes se fait dans la main (above this panel) — pas ici,
//  pour éviter d'afficher la main 2 fois.
//

import SwiftUI

struct AnnouncePanel: View {
    let alreadySubmitted: Bool
    /// Si non-nil, la catégorie est verrouillée (cas tie-break) — on cache la
    /// grille et on utilise cette catégorie pour la confirm.
    var lockedCategory: HandCategory? = nil
    /// Cartes du board (regular ou tie-break) pour la validation live.
    var boardCards: [Card] = []
    /// Main complète du joueur (pour computeNuts).
    var myHole: [Card] = []
    /// Toutes les cartes communautaires de la manche (pour exclure les cartes
    /// déjà-utilisées du compute nuts).
    var allCommunityCards: [[Card]] = []
    /// La catégorie choisie par le user (binding parent). Ignoré si lockedCategory.
    @Binding var selectedCategory: HandCategory?
    /// Les cartes sélectionnées dans la main au-dessus (read-only).
    let selectedCards: [Card]
    /// Confirme avec la submission construite à partir de category + cards.
    let onConfirm: () -> Void
    /// Skip ce board.
    let onSkip: () -> Void
    /// Affiche le bouton Skip (true par défaut pour compat). Quand le panel
    /// est embarqué dans la bulle, on cache Skip (le user peut valider sans
    /// sélection → Hauteur auto).
    var showSkip: Bool = true
    /// Mode landscape : grille 2×5 avec le bouton Confirmer en 10ème cellule.
    /// En portrait (false), la grille reste en 3×3 + bouton Confirmer séparé en dessous.
    var isLandscape: Bool = false

    /// Catégorie effective : lockedCategory en priorité, sinon selectedCategory.
    private var effectiveCategory: HandCategory? {
        lockedCategory ?? selectedCategory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if alreadySubmitted {
                submittedView
            } else {
                if let locked = lockedCategory {
                    lockedHeader(locked)
                }
                categoriesGrid
                hintLine
                // En landscape le bouton Confirmer est intégré au grid 2×5 →
                // pas d'actions séparées. En portrait on garde les actions.
                if !isLandscape {
                    actions
                }
            }
        }
        // XCUITest : un conteneur SwiftUI (VStack) n'est PAS un élément
        // d'accessibilité — sans `children: .contain` l'identifiant
        // « announce.panel » n'existe pas pour le tour. `.contain` laisse les
        // enfants (catégories, Confirmer) exposés tels quels.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("announce.panel")
    }

    @ViewBuilder
    private func lockedHeader(_ cat: HandCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.brandRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tie-break — annonce verrouillée")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(cat.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
            }
            Spacer()
            if cat.multi > 1 {
                Text("×\(cat.multi)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
            }
        }
    }

    // MARK: - Submitted state

    @ViewBuilder
    private var submittedView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Annonce envoyée — en attente des autres joueurs.")
                .accessibilityIdentifier("announce.submitted")
                .font(.subheadline)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: - Categories grid

    @ViewBuilder
    private var categoriesGrid: some View {
        let categories = HandCategory.allCases.filter { $0 != .highcard }
        // 3 cols × 3 rows en portrait, 5 cols × 2 rows en landscape (avec
        // bouton Confirmer en 10ème cellule).
        let colCount = isLandscape ? 5 : 3
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6),
                         count: colCount)
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(categories, id: \.self) { cat in
                categoryButton(cat)
            }
            if isLandscape {
                inlineConfirmCell
            }
        }
    }

    @ViewBuilder
    private func categoryButton(_ cat: HandCategory) -> some View {
        Button {
            // Toggle : re-tap sur la catégorie sélectionnée la désélectionne
            // → retour au mode Hauteur auto par défaut.
            if selectedCategory == cat {
                selectedCategory = nil
            } else {
                selectedCategory = cat
            }
        } label: {
            HStack(spacing: 4) {
                Text(shortLabel(cat))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if cat.multi > 1 {
                    Text("×\(cat.multi)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.brandRed)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedCategory == cat
                          ? Theme.brandRed.opacity(0.14)
                          : Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selectedCategory == cat
                            ? Theme.brandRed
                            : Color(.systemGray3),
                        lineWidth: selectedCategory == cat ? 1.5 : 1
                    )
            )
            // Toute la pilule est tappable, pas juste le label texte.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("announce.cat.\(cat.id)")
        .foregroundStyle(.primary)
    }

    /// Bouton Confirmer placé en 10ème cellule de la grille 2×5 (landscape).
    @ViewBuilder
    private var inlineConfirmCell: some View {
        Button(action: onConfirm) {
            VStack(spacing: 2) {
                Text("Confirmer")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(canConfirm ? Theme.brandRed : Theme.brandRed.opacity(0.35))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("announce.confirm")
        .disabled(!canConfirm)
    }

    /// Labels compacts pour la grille (les labels normaux passent en label de
    /// résultat dans les autres écrans).
    private func shortLabel(_ cat: HandCategory) -> String {
        switch cat {
        case .highcard:  return "Hauteur"
        case .pair:      return "Paire"
        case .twopair:   return "2 Paires"
        case .trips:     return "Brelan"
        case .straight:  return "Suite"
        case .flush:     return "Couleur"
        case .fullhouse: return "Full"
        case .quads:     return "Carré"
        case .sflush:    return "Q. Flush"
        case .royal:     return "Royale"
        }
    }

    // MARK: - Hint + actions

    /// Plus de hint sur les cartes — un shake des cartes (orchestré côté
    /// OnlineGameView via cardShakeNudge) + un cadran rouge transient
    /// indiqueront qu'il faut sélectionner.
    @ViewBuilder
    private var hintLine: some View { EmptyView() }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onConfirm) {
                Text(confirmLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.brandRed)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("announce.confirm")

            if showSkip {
                Button(action: onSkip) {
                    Text("Skip ce board")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("announce.skip")
            }
        }
        .padding(.top, 4)
    }

    /// Toujours `true` — le bouton Confirmer reste cliquable même quand la
    /// catégorie nécessite des cartes ; le parent (OnlineGameView) déclenche
    /// un shake animation sur la main pour signaler l'action manquante.
    private var canConfirm: Bool { true }

    private var confirmLabel: String {
        let label = effectiveCategory?.label ?? "Hauteur"
        let n = selectedCards.count
        if n == 0 { return "Confirmer : \(label)" }
        return "Confirmer : \(label) (\(n) carte\(n > 1 ? "s" : ""))"
    }
}
