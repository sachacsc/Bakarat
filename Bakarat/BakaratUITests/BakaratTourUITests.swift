//
//  BakaratTourUITests.swift
//  BakaratUITests
//
//  T32 (docs/PLAN_ONLINE_V2.md — P3) : le Tour — la boucle d'usage
//  automatisée du mode Online, sur UN simulateur.
//
//  L'app est lancée déjà connectée (`-autoLoginEmail`), elle crée son salon
//  (`-autoCreateRoom -qaRoomCode`), deux bots in-app le rejoignent
//  (`-qaBots 2`, T33) et la partie démarre à 3 joueurs (`-autoStartAt 3`).
//  Le test ne fait que ce qu'un joueur ferait : regarder, annoncer, changer
//  d'onglet, verrouiller son téléphone, revenir, quitter.
//
//  Le tour PHOTOGRAPHIE (`tour-<mode>-NN-…`), il ne juge pas : la relecture
//  visuelle est `scripts/online-judge.py` (T36). Ses assertions sont des
//  assertions d'EXPÉRIENCE — « le lobby se remplit », « les 15 cartes
//  arrivent », « la partie survit au verrouillage ».
//  Un échec produit une capture `*-DIAG-*` **et** un dump de la hiérarchie
//  d'accessibilité (`*-hierarchie`), puis le tour CONTINUE
//  (`continueAfterFailure = true`) : on veut le film entier, pas le premier
//  pixel fautif — et de quoi corriger sans rejouer.
//
//  Tempo : le tour est PATIENT, pas rapide. Sur une machine chargée l'app
//  met parfois 90 s à peindre son premier écran, et la boucle d'hôte
//  (publish CAS + poll) avance au rythme du réseau. Les délais sont donc
//  généreux (`Wait`) — un `waitFor` rend la main dès que la condition est
//  vraie, un délai long ne coûte rien quand tout va bien.
//
//  Lancé par `scripts/online-loop.sh` deux fois (clair puis sombre) via
//  `TEST_RUNNER_TOUR_MODE`.
//

import XCTest

final class BakaratTourUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Les délais du tour, en un seul endroit.
    private enum Wait {
        /// Premier écran après `launch()` : connexion + `room_create` + peinture.
        static let lobby: TimeInterval = 180
        /// Les 2 bots rejoignent (et `-autoStartAt 3` démarre aussitôt).
        static let players: TimeInterval = 60
        /// La main du joueur (6 cartes).
        static let hand: TimeInterval = 60
        /// Les 15 cartes communautaires (flop/turn/river des 3 boards).
        static let boards: TimeInterval = 90
        /// Le panneau d'annonce du board courant.
        static let announce: TimeInterval = 60
        /// Reveal du board courant / passage au board suivant.
        static let reveal: TimeInterval = 60
        /// Récap de fin de manche.
        static let mancheEnd: TimeInterval = 120
    }

    /// Injecté par le runner — nomme les captures (`tour-light-…`).
    private var mode: String { ProcessInfo.processInfo.environment["TOUR_MODE"] ?? "light" }

    /// Mot de passe des comptes QA. Jamais en dur : le runner le passe en
    /// `TEST_RUNNER_BAKARAT_QA_PASSWORD`.
    private var qaPassword: String {
        ProcessInfo.processInfo.environment["BAKARAT_QA_PASSWORD"] ?? ""
    }

    /// Code du salon, tiré au lancement : deux tours simultanés ne se marchent
    /// pas dessus (et le duel utilise QATEST, jamais celui-ci).
    private lazy var roomCode: String = Self.randomCode()

    private static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    override func setUpWithError() throws {
        // Le tour doit aller au bout : un écran raté ne masque pas les suivants.
        continueAfterFailure = true
    }

    // MARK: - Outillage

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = [
            "-autoLoginEmail", "bakaratqa.host@bakarat.test",
            "-autoLoginPassword", qaPassword,
            "-qaRoomCode", roomCode,
            "-autoCreateRoom",
            "-qaBots", "2",
            "-qaPassword", qaPassword,
            "-autoStartAt", "3", "-autoStartDelay", "8",
        ]
        addUIInterruptionMonitor(withDescription: "alerte système") { alert in
            for label in ["Allow While Using App", "Allow", "OK", "Autoriser", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 60)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tour-\(mode)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Le dump de la hiérarchie d'accessibilité — tronqué à 20 000 caractères.
    /// C'est LUI qui permet de corriger un identifiant sans rejouer le tour
    /// (une capture montre l'écran, pas ce que XCUITest voit).
    private func attachHierarchy(_ name: String) {
        let dump = String(app.debugDescription.prefix(20_000))
        let attachment = XCTAttachment(string: dump)
        attachment.name = "tour-\(mode)-\(name)-hierarchie"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Capture + hiérarchie : le couple de diagnostic de tout échec d'attente.
    private func diag(_ name: String) {
        shot(name)
        attachHierarchy(name)
    }

    /// Les alertes système vivent dans SpringBoard, pas dans l'app : le
    /// moniteur d'interruption ne les voit qu'au prochain TAP, et une capture
    /// n'en est pas un. On y répond explicitement (leçon Zmeo U-0007).
    @discardableResult
    private func answerSystemAlerts() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var answered = false
        for _ in 0..<3 {
            var hit = false
            for label in ["Allow While Using App", "Allow", "OK", "Autoriser"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 1.5) {
                    button.tap(); hit = true; answered = true; break
                }
            }
            if !hit { break }
            settle(0.8)
        }
        return answered
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Repli par LABEL quand l'identifiant manque (un conteneur SwiftUI n'est
    /// pas toujours exposé) : le premier bouton dont le label commence par
    /// `prefix`.
    private func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// L'élément d'identifiant `identifier` s'il existe, sinon le bouton dont
    /// le label commence par `prefix`.
    private func resolve(_ identifier: String, orButtonStartingWith prefix: String) -> XCUIElement {
        let byIdentifier = element(identifier)
        if byIdentifier.exists { return byIdentifier }
        return button(startingWith: prefix)
    }

    /// Le code du salon : `lobby.code`, ou à défaut le premier `staticText`
    /// fait de 4 caractères majuscules/chiffres.
    private var roomCodeElement: XCUIElement {
        let byIdentifier = element("lobby.code")
        if byIdentifier.exists { return byIdentifier }
        return app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z0-9]{4}$"))
            .firstMatch
    }

    /// Le bouton « Confirmer : … » du panneau d'annonce.
    ///
    /// Run 2026-09-25-2010 : l'identifiant d'un enfant du bandeau de main peut
    /// être ÉCRASÉ par le `game.root` du conteneur (les cartes de la main y
    /// sortent en « Other · game.root · Js »). On cherche donc aussi par
    /// LABEL, sur tout type d'élément — pas seulement `buttons`.
    private var confirmButton: XCUIElement {
        let byIdentifier = element("announce.confirm")
        if byIdentifier.exists { return byIdentifier }
        let byButton = button(startingWith: "Confirmer")
        if byButton.exists { return byButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Confirmer"))
            .firstMatch
    }

    /// Une carte de la main : `game.hand.card0`, sinon un élément dont le
    /// label est une carte (« Js », « Td »…) — c'est ainsi qu'elles
    /// apparaissent quand `game.root` écrase leur identifiant.
    private var handCardVisible: Bool {
        if element("game.hand.card0").exists { return true }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label MATCHES %@",
                                  "game.root", "^[2-9TJQKA][shdc]$"))
            .firstMatch.exists
    }

    /// La main est « visible » si une carte est exposée OU si le panneau
    /// d'annonce / le bouton Confirmer l'est (la main vit dans ce panneau).
    private var handVisible: Bool {
        handCardVisible || element("announce.panel").exists || confirmButton.exists
    }

    /// Libellé de nav pendant les annonces du board N : « BN · 27s »
    /// (OnlineGameView.navLabelForActiveBoard).
    private func isAnnouncing(board: Int) -> Bool {
        phaseLabel.hasPrefix("B\(board) ")
    }

    /// Vrai quand la partie a dépassé le board N : annonces d'un board
    /// suivant, tie-break, ou fin de manche.
    private func isPast(board: Int) -> Bool {
        if element("game.mancheEnd").exists { return true }
        let label = phaseLabel
        if label.hasPrefix("Fin de manche") || label.hasPrefix("Split")
            || label.hasPrefix("Tie-break") { return true }
        if board < 3 {
            return ((board + 1)...3).contains { label.hasPrefix("B\($0) ") }
        }
        return false
    }

    /// Le bouton « Manche suivante » du récap.
    private var nextMancheButton: XCUIElement {
        resolve("game.nextManche", orButtonStartingWith: "Manche suivante")
    }

    /// Vrai dès que l'écran de jeu est à l'écran (le lobby a été traversé).
    private var inGame: Bool {
        element("game.root").exists || element("game.phaseLabel").exists
    }

    /// Attend un écran. En cas d'absence : `*-DIAG-*` + hiérarchie + échec,
    /// puis on continue — le tour doit filmer la suite.
    @discardableResult
    private func expectScreen(_ identifier: String,
                              timeout: TimeInterval,
                              shot name: String,
                              because reason: String) -> Bool {
        let started = Date()
        if element(identifier).waitForExistence(timeout: timeout) {
            let elapsed = Date().timeIntervalSince(started)
            XCTContext.runActivity(named: "\(identifier) en \(String(format: "%.1f", elapsed)) s") { _ in }
            return true
        }
        diag("\(name)-DIAG-\(identifier)")
        XCTFail("\(reason) — « \(identifier) » toujours absent après \(Int(timeout)) s")
        return false
    }

    @discardableResult
    private func tapIfExists(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        tap(element(identifier), timeout: timeout)
    }

    @discardableResult
    private func tap(_ el: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        if el.isHittable {
            el.tap()
        } else {
            // Un élément d'accessibilité composite peut n'être « hittable »
            // qu'en son centre — on tape la coordonnée plutôt que d'abandonner.
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        settle(0.6)
        return true
    }

    /// Attend qu'une condition sur l'UI devienne vraie (polling doux — les
    /// phases arrivent par le réseau, pas par un geste).
    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.5)
        }
        return condition()
    }

    /// Nombre de cartes visibles sur un board, lu dans la `value` du titre.
    private func boardCardCount(_ index: Int) -> Int {
        let title = element("game.board\(index).title")
        guard title.exists, let raw = title.value as? String else { return -1 }
        return Int(raw) ?? -1
    }

    private var phaseLabel: String {
        let el = element("game.phaseLabel")
        return el.exists ? el.label : ""
    }

    /// Vrai quand les 3 boards sont complets (15 cartes communautaires).
    private var allBoardsComplete: Bool {
        (1...3).allSatisfy { boardCardCount($0) == 5 }
    }

    // MARK: - Le tour

    func test00_tourOnlineComplet() {
        launch()
        answerSystemAlerts()

        // ── 01 · Le lobby ────────────────────────────────────────────────
        // L'app se connecte, crée le salon et pousse le lobby toute seule.
        // Mais le lobby peut déjà être TRAVERSÉ quand on regarde : les deux
        // bots rejoignent en ~3 s et `-autoStartAt 3` démarre la partie dès le
        // 3ème joueur. On accepte donc les deux rives — lobby OU partie — et
        // on reste patient côté peinture du premier écran.
        let opened = waitFor(Wait.lobby) {
            self.element("lobby.code").exists || self.inGame
        }
        if !opened {
            diag("01-DIAG-lobby")
            XCTFail("le salon doit s'ouvrir sans le moindre geste (-autoCreateRoom) — "
                    + "ni « lobby.code » ni l'écran de jeu après \(Int(Wait.lobby)) s")
        }
        settle(1)
        shot("01-lobby")

        let sawLobby = element("lobby.code").exists
        if sawLobby {
            // Lecture par VALEUR (staticTexts[roomCode]) : jamais de `.label` sur
            // un élément qui peut disparaître entre deux snapshots (le lobby ne
            // vit que quelques secondes avant -autoStartAt).
            if !inGame, !app.staticTexts[roomCode].exists {
                XCTFail("le code affiché doit être celui imposé par -qaRoomCode (\(roomCode))")
            }

            // Les deux bots rejoignent : trois joueurs dans le lobby. Si la
            // partie a déjà démarré, le compte a forcément été atteint.
            let filled = waitFor(Wait.players) {
                if self.inGame { return true }
                let counter = self.element("lobby.playerCount")
                return counter.exists && (Int(counter.label) ?? 0) >= 3
            }
            if !filled {
                diag("02-DIAG-lobby-incomplet")
                XCTFail("le lobby doit compter 3 joueurs en moins de \(Int(Wait.players)) s "
                        + "(2 bots + l'hôte)")
            }
        } else {
            XCTContext.runActivity(named: "lobby déjà traversé — la partie avait démarré "
                                   + "avant la première observation (-autoStartAt 3)") { _ in }
        }
        shot("02-lobby-rempli")

        // ── 03 · La distribution ─────────────────────────────────────────
        // `-autoStartAt 3` a lancé la partie : l'écran de jeu remplace le lobby.
        expectScreen("game.phaseLabel", timeout: Wait.hand, shot: "03",
                     because: "la partie doit démarrer dès le 3ème joueur")
        // La main : `game.hand.card0` OU une carte exposée par son label OU le
        // panneau d'annonce (la main vit dedans). L'identifiant seul n'est pas
        // fiable (run 2026-09-25-2010) — son absence est un DIAG, pas un échec.
        let handDealt = waitFor(Wait.hand) { self.handVisible || self.allBoardsComplete }
        settle(1)
        shot("03-distribution")
        if !handDealt || !element("game.hand.card0").exists {
            diag("03-DIAG-main-identifiant")
            XCTContext.runActivity(named: "main : « game.hand.card0 » non exposé (visible par "
                                   + "un autre signal : \(handDealt)) — non bloquant") { _ in }
        }

        // ── 04 · Flop, turn, river ───────────────────────────────────────
        let dealStart = Date()
        var lastSeen = -1
        let complete = waitFor(Wait.boards) {
            let total = (1...3).map { self.boardCardCount($0) }.filter { $0 > 0 }.reduce(0, +)
            if total != lastSeen {
                lastSeen = total
                if total == 9 { self.shot("04-flop") }
                if total == 12 { self.shot("05-turn") }
            }
            return self.allBoardsComplete
        }
        if !complete {
            diag("06-DIAG-board-incomplet")
            XCTFail("les 15 cartes communautaires doivent être posées en moins de "
                    + "\(Int(Wait.boards)) s (lu : \((1...3).map { boardCardCount($0) }))")
        } else {
            XCTContext.runActivity(named: "15 cartes en \(Int(Date().timeIntervalSince(dealStart))) s") { _ in }
        }
        shot("06-river")

        // ── 07 · Les trois boards : annoncer, révéler ────────────────────
        // L'hôte est le SEUL humain : sans ses 3 annonces (une par board) la
        // manche ne se termine jamais. On attend le panneau à CHAQUE board.
        for board in 1...3 {
            announceOnCurrentBoard(step: 6 + board, board: board)
        }

        // ── 10 · Fin de manche ───────────────────────────────────────────
        // Un board à égalité rouvre un panneau d'annonce (tie-break) : l'hôte
        // étant le seul humain, il doit y répondre — sinon la manche ne se
        // termine jamais et le récap n'arrive pas.
        // Détection par le LIBELLÉ DE PHASE (OnlineGameView.phaseLabel /
        // navLabelForActiveBoard) : « Split · Ns » / « Split 2 · Ns » avec
        // chrono, « Tie-break — annonces » sans. Plafond : 3 rounds.
        var ended = false
        var tiebreak = 0
        let maxTiebreaks = 3
        let mancheDeadline = Date().addingTimeInterval(Wait.mancheEnd)
        while Date() < mancheDeadline {
            if element("game.mancheEnd").exists { ended = true; break }
            let label = phaseLabel
            let inTiebreakAnnounce = label.hasPrefix("Split")
                || label.localizedCaseInsensitiveContains("Tie-break — annonces")
            if inTiebreakAnnounce, tiebreak < maxTiebreaks,
               !element("announce.submitted").exists, confirmButton.exists {
                tiebreak += 1
                XCTContext.runActivity(named: "tie-break \(tiebreak) (« \(label) ») — l'hôte réannonce") { _ in }
                shot("10-tiebreak-\(tiebreak)")
                tap(confirmButton, timeout: 5)
                // Laisser la soumission partir avant de réévaluer la phase.
                _ = waitFor(10) {
                    self.element("announce.submitted").exists || !self.confirmButton.exists
                        || self.element("game.mancheEnd").exists
                }
            }
            settle(0.5)
        }
        if !ended { ended = element("game.mancheEnd").exists }
        if !ended {
            diag("10-DIAG-pas-de-fin-de-manche")
            XCTFail("après les 3 boards, la manche doit se terminer (récap + « Manche suivante »)")
        }
        settle(1)
        shot("10-fin-de-manche")
        XCTAssertTrue(nextMancheButton.exists,
                      "l'hôte doit pouvoir enchaîner sur la manche suivante")

        // ── 11 · Le sheet « Solde & historique » ─────────────────────────
        if tapIfExists("game.balance", timeout: 8) {
            settle(1.2)
            shot("11-solde-historique")
            let sheetOpened = app.navigationBars["Solde & historique"].waitForExistence(timeout: 6)
            if !sheetOpened {
                diag("11-DIAG-solde-absent")
                XCTFail("le bouton € doit ouvrir « Solde & historique »")
            }
            if app.buttons["Fermer"].exists { app.buttons["Fermer"].tap() }
            settle(0.8)
        } else {
            diag("11-DIAG-bouton-solde-introuvable")
            XCTFail("le bouton « Solde & historique » doit rester accessible en fin de manche")
        }

        // ── 12 · Manche suivante ─────────────────────────────────────────
        // Le bouton est SOUS le pli (y ≈ 905 pour un écran de 874) et sous la
        // bulle de main : un tap à la coordonnée tombait dans le vide (run
        // 2026-09-25-2010). On fait défiler jusqu'à ce qu'il soit touchable.
        // Manche 2 = `game.mancheEnd` disparaît OU le libellé de phase quitte
        // « Fin de manche ».
        let mancheTwo: () -> Bool = {
            let label = self.phaseLabel
            return !self.element("game.mancheEnd").exists
                || (!label.isEmpty && !label.hasPrefix("Fin de manche"))
        }
        if revealNextMancheButton(), tap(nextMancheButton, timeout: 8) {
            var redealt = waitFor(20, mancheTwo)
            if !redealt, nextMancheButton.exists {
                // Second essai : le premier tap a pu tomber pendant le défilement.
                revealNextMancheButton()
                tap(nextMancheButton, timeout: 5)
                redealt = waitFor(40, mancheTwo)
            }
            if !redealt {
                diag("12-DIAG-manche-2-absente")
                XCTFail("« Manche suivante » doit redistribuer une nouvelle manche")
            }
            settle(1)
            shot("12-manche-2")
        }

        // ── 13 · Changer d'onglet ne quitte JAMAIS la partie ─────────────
        // (L'écran de jeu masque volontairement la tab bar — quand elle n'est
        // pas là, l'assertion d'expérience est déjà tenue par construction :
        // il n'existe aucun chemin implicite vers « Quitter ».)
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists && tabBar.buttons["Accounts"].exists {
            tabBar.buttons["Accounts"].tap()
            settle(1.5)
            shot("13-onglet-comptes")
            tabBar.buttons["Play"].tap()
            settle(2)
            shot("13-retour-partie")
            XCTAssertTrue(element("game.root").waitForExistence(timeout: 15),
                          "changer d'onglet ne doit JAMAIS faire quitter la partie")
        } else {
            XCTContext.runActivity(named: "tab bar masquée en partie — aucun départ implicite possible") { _ in }
            shot("13-tabbar-masquee")
        }

        // ── 14 · Verrouiller, revenir : la partie est toujours là ────────
        let phaseBefore = phaseLabel
        XCUIDevice.shared.press(.home)
        settle(15)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 30)
        settle(3)
        shot("14-retour-premier-plan")

        let stillThere = element("game.root").waitForExistence(timeout: 20)
            || element("game.phaseLabel").waitForExistence(timeout: 5)
        if !stillThere {
            diag("14-DIAG-partie-perdue-au-retour")
            XCTFail("après 15 s en arrière-plan, on doit retrouver la partie — jamais un écran d'entrée")
        }
        XCTAssertFalse(element("play.createOnline").exists,
                       "revenir au premier plan ne doit pas ramener à l'accueil")
        XCTContext.runActivity(named: "phase avant « \(phaseBefore) » → après « \(phaseLabel) »") { _ in }

        // ── 15 · Quitter, explicitement ──────────────────────────────────
        if tapIfExists("game.settings", timeout: 10) {
            settle(1)
            shot("15-reglages")
            // `settings.leave`, sinon un bouton « Quitter… » du SHEET (puis
            // partout) — jamais celui du lobby : on n'est pas au lobby ici.
            var leave = element("settings.leave")
            if !leave.waitForExistence(timeout: 8) {
                let quitter = NSPredicate(format: "label CONTAINS %@", "Quitter")
                let inSheet = app.sheets.buttons.matching(quitter).firstMatch
                leave = inSheet.exists ? inSheet : app.buttons.matching(quitter).firstMatch
            }
            if tap(leave, timeout: 3) {
                // Confirmation éventuelle (« Quitter la partie ? ») : elle vit
                // dans une alerte / un confirmationDialog. On la cherche LÀ,
                // jamais dans la page — sinon on retaperait « Quitter la
                // partie » du sheet lui-même.
                for container in [app.alerts.firstMatch, app.sheets.firstMatch] where container.exists {
                    let confirm = container.buttons
                        .matching(NSPredicate(format: "label BEGINSWITH %@", "Quitter"))
                        .firstMatch
                    if confirm.waitForExistence(timeout: 2), confirm.isHittable {
                        confirm.tap(); break
                    }
                }
                settle(2.5)
                shot("15-retour-accueil")
                let home = element("play.createOnline").waitForExistence(timeout: 20)
                if !home {
                    diag("15-DIAG-pas-de-retour-accueil")
                    XCTFail("« Quitter la partie » doit ramener à l'accueil")
                }
            } else {
                diag("15-DIAG-quitter-introuvable")
                XCTFail("le sheet de réglages doit offrir « Quitter la partie »")
            }
        } else {
            diag("15-DIAG-reglages-introuvables")
            XCTFail("le bouton de réglages mi-partie doit rester accessible")
        }

        dumpVisibleTexts()
    }

    /// Fait défiler l'écran de jeu jusqu'à ce que « Manche suivante » soit
    /// touchable (et hors de la bulle de main, qui couvre le bas de l'écran).
    @discardableResult
    private func revealNextMancheButton() -> Bool {
        let button = nextMancheButton
        guard button.waitForExistence(timeout: 8) else { return false }
        let window = app.windows.firstMatch.frame
        let safeBottom = window.maxY - 220   // la bulle de main ~ 200 pt
        for _ in 0..<5 {
            let f = button.frame
            if button.isHittable, f.minY > window.minY + 100, f.maxY < safeBottom { break }
            let root = element("game.root")
            let target: XCUIElement = root.exists ? root : app
            target.swipeUp(velocity: .slow)
            settle(0.6)
        }
        return true
    }

    // MARK: - Une annonce

    /// Annonce sur le board courant, sur la catégorie par défaut « Hauteur ».
    /// RULES.md : Hauteur = auto-pick, aucune sélection requise — l'app
    /// choisit les 2 meilleures cartes. Le tap sur une carte de la main reste
    /// un best-effort (souvent non « hittable » sous XCUITest) : son échec
    /// n'est PAS un défaut. Ce qui compte : l'annonce part après « Confirmer ».
    private func announceOnCurrentBoard(step: Int, board: Int) {
        // PRÊT À ANNONCER = le libellé de nav dit « BN · Ns » (annonces du
        // board N) ET un bouton « Confirmer » est exposé. On ne s'appuie plus
        // sur `announce.submitted` / `announce.panel` : run 2026-09-25-2010,
        // ni l'un ni l'autre n'étaient fiables d'un board à l'autre.
        // On sort aussi dès que la partie a DÉPASSÉ le board N (l'app a pu le
        // résoudre sans nous — timer d'annonce) : ce n'est pas un défaut.
        var sawAnnouncing = false
        let ready = waitFor(Wait.announce) {
            if self.isPast(board: board) { return true }
            let announcing = self.isAnnouncing(board: board)
            if announcing { sawAnnouncing = true }
            // Board 1 : le libellé peut déjà être là avant le premier poll ;
            // on tolère aussi « Confirmer » seul quand la phase est illisible.
            return (announcing || self.phaseLabel.isEmpty) && self.confirmButton.exists
        }
        if isPast(board: board) && !isAnnouncing(board: board) {
            shot("\(pad(step))-annonce-b\(board)-deja-resolue")
            XCTContext.runActivity(named: "Board \(board) déjà résolu (phase « \(phaseLabel) », "
                                   + "annonces vues : \(sawAnnouncing)) — rien à faire") { _ in }
            return
        }
        if !ready {
            diag("\(pad(step))-DIAG-annonce-b\(board)-absente")
            XCTFail("le panneau d'annonce du Board \(board) doit s'ouvrir "
                    + "(phase « \(phaseLabel) », annonces vues : \(sawAnnouncing))")
            return
        }
        settle(0.8)
        shot("\(pad(step))-annonce-b\(board)")

        // Best-effort : sélectionner une carte n'est pas nécessaire pour
        // Hauteur (auto-pick) — pas de DIAG si le tap échoue.
        let card0 = element("game.hand.card0")
        if card0.exists, card0.isHittable {
            card0.tap()
            settle(0.4)
        }
        // Catégorie : on reste sur le défaut « Hauteur » (auto-pick). Choisir
        // une pilule exigerait une main compatible — le tour ne parie pas.
        settle(0.4)
        shot("\(pad(step))-annonce-b\(board)-choisie")

        if !tap(confirmButton, timeout: 8) {
            diag("\(pad(step))-DIAG-confirm-absent-b\(board)")
            XCTFail("le bouton « Confirmer » doit être là pendant l'annonce")
            return
        }

        // La soumission est partie si : état « envoyée », ou le bouton
        // « Confirmer » / le panneau a disparu, ou la manche est finie.
        // (La puce ⏳/✓ de l'hôte n'a pas d'identifiant — non utilisée.)
        let accepted = waitFor(Wait.reveal) {
            self.element("announce.submitted").exists
                || self.isPast(board: board)
                || !self.isAnnouncing(board: board)
                || !self.confirmButton.exists
        }
        if !accepted {
            diag("\(pad(step))-DIAG-annonce-non-envoyee-b\(board)")
            XCTFail("annonce non envoyée — après « Confirmer : Hauteur », l'annonce "
                    + "doit partir sans sélection (auto-pick, RULES.md)")
        }
        shot("\(pad(step))-annonce-b\(board)-envoyee")

        // Le reveal du board : les bots annoncent en 1-3 s, l'hôte résout.
        // Board 1 et 2 → le board suivant repasse en annonces (le panneau
        // redevient vierge) ; board 3 → fin de manche.
        let revealed = waitFor(Wait.reveal) {
            self.phaseLabel.contains("Reveal") || self.isPast(board: board)
        }
        if !revealed {
            diag("\(pad(step))-DIAG-reveal-b\(board)")
            XCTFail("le Board \(board) doit être révélé une fois toutes les annonces reçues")
        }
        settle(1)
        shot("\(pad(step))-reveal-b\(board)")
    }

    private func pad(_ n: Int) -> String { String(format: "%02d", n) }

    // MARK: - Trace

    /// Le test ne peut pas lire le container de l'app (`Documents/qa.log`) :
    /// c'est le runner qui l'exporte (`export_qa_log`, scripts/online-loop.sh).
    /// On joint ici ce que l'écran disait au moment de la sortie — utile au
    /// juge quand une capture est ambiguë.
    private func dumpVisibleTexts() {
        XCTContext.runActivity(named: "textes visibles en fin de tour") { activity in
            let texts = app.staticTexts.allElementsBoundByIndex
                .prefix(200)
                .map { "\($0.identifier.isEmpty ? "-" : $0.identifier) · \($0.label)" }
                .joined(separator: "\n")
            let attachment = XCTAttachment(string: texts)
            attachment.name = "tour-\(mode)-99-textes"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
