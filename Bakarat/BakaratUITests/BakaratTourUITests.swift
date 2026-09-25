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
//  assertions d'EXPÉRIENCE — « le lobby se remplit en moins de 20 s », « les
//  15 cartes arrivent en moins de 40 s », « la partie survit au verrouillage ».
//  Un échec produit une capture `*-FAIL-*` ou `*-DIAG-*` et le tour CONTINUE
//  (`continueAfterFailure = true`) : on veut le film entier, pas le premier
//  pixel fautif.
//
//  Lancé par `scripts/online-loop.sh` deux fois (clair puis sombre) via
//  `TEST_RUNNER_TOUR_MODE`.
//

import XCTest

final class BakaratTourUITests: XCTestCase {

    private var app: XCUIApplication!

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
            "-autoStartAt", "3",
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

    /// Attend un écran. En cas d'absence : capture `*-DIAG-*` + échec, puis on
    /// continue — le tour doit filmer la suite.
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
        shot("\(name)-DIAG-\(identifier)")
        XCTFail("\(reason) — « \(identifier) » toujours absent après \(Int(timeout)) s")
        return false
    }

    @discardableResult
    private func tapIfExists(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let el = element(identifier)
        guard el.waitForExistence(timeout: timeout), el.isHittable else { return false }
        el.tap()
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
        expectScreen("lobby.code", timeout: 60, shot: "01",
                     because: "le salon doit s'ouvrir sans le moindre geste (-autoCreateRoom)")
        settle(1)
        shot("01-lobby")

        let code = element("lobby.code")
        if code.exists {
            XCTAssertEqual(code.label, roomCode,
                           "le code affiché doit être celui imposé par -qaRoomCode")
        }

        // Les deux bots rejoignent : trois joueurs dans le lobby.
        let filled = waitFor(20) {
            let counter = self.element("lobby.playerCount")
            return counter.exists && (Int(counter.label) ?? 0) >= 3
        }
        if !filled {
            shot("02-DIAG-lobby-incomplet")
            XCTFail("le lobby doit compter 3 joueurs en moins de 20 s (2 bots + l'hôte)")
        }
        shot("02-lobby-rempli")

        // ── 03 · La distribution ─────────────────────────────────────────
        // `-autoStartAt 3` a lancé la partie : l'écran de jeu remplace le lobby.
        expectScreen("game.phaseLabel", timeout: 30, shot: "03",
                     because: "la partie doit démarrer dès le 3ème joueur")
        let handDealt = expectScreen("game.hand.card0", timeout: 30, shot: "03",
                                     because: "la main du joueur doit être distribuée")
        settle(1)
        shot("03-distribution")
        XCTAssertTrue(handDealt, "sans main visible, il n'y a rien à jouer")

        // ── 04 · Flop, turn, river ───────────────────────────────────────
        let dealStart = Date()
        var lastSeen = -1
        let complete = waitFor(40) {
            let total = (1...3).map { self.boardCardCount($0) }.filter { $0 > 0 }.reduce(0, +)
            if total != lastSeen {
                lastSeen = total
                if total == 9 { self.shot("04-flop") }
                if total == 12 { self.shot("05-turn") }
            }
            return self.allBoardsComplete
        }
        if !complete {
            shot("06-DIAG-board-incomplet")
            XCTFail("les 15 cartes communautaires doivent être posées en moins de 40 s "
                    + "(lu : \((1...3).map { boardCardCount($0) }))")
        } else {
            XCTContext.runActivity(named: "15 cartes en \(Int(Date().timeIntervalSince(dealStart))) s") { _ in }
        }
        shot("06-river")

        // ── 07 · Les trois boards : annoncer, révéler ────────────────────
        for board in 1...3 {
            announceOnCurrentBoard(step: 6 + board, board: board)
        }

        // ── 10 · Fin de manche ───────────────────────────────────────────
        let ended = waitFor(90) { self.element("game.mancheEnd").exists }
        if !ended {
            shot("10-DIAG-pas-de-fin-de-manche")
            XCTFail("après les 3 boards, la manche doit se terminer (récap + « Manche suivante »)")
        }
        settle(1)
        shot("10-fin-de-manche")
        XCTAssertTrue(element("game.nextManche").exists,
                      "l'hôte doit pouvoir enchaîner sur la manche suivante")

        // ── 11 · Le sheet « Solde & historique » ─────────────────────────
        if tapIfExists("game.balance", timeout: 8) {
            settle(1.2)
            shot("11-solde-historique")
            let sheetOpened = app.navigationBars["Solde & historique"].waitForExistence(timeout: 6)
            if !sheetOpened {
                shot("11-DIAG-solde-absent")
                XCTFail("le bouton € doit ouvrir « Solde & historique »")
            }
            if app.buttons["Fermer"].exists { app.buttons["Fermer"].tap() }
            settle(0.8)
        } else {
            shot("11-DIAG-bouton-solde-introuvable")
            XCTFail("le bouton « Solde & historique » doit rester accessible en fin de manche")
        }

        // ── 12 · Manche suivante ─────────────────────────────────────────
        if tapIfExists("game.nextManche", timeout: 8) {
            let redealt = waitFor(60) {
                self.element("game.hand.card0").exists && !self.element("game.mancheEnd").exists
            }
            if !redealt {
                shot("12-DIAG-manche-2-absente")
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
            shot("14-DIAG-partie-perdue-au-retour")
            XCTFail("après 15 s en arrière-plan, on doit retrouver la partie — jamais un écran d'entrée")
        }
        XCTAssertFalse(element("play.createOnline").exists,
                       "revenir au premier plan ne doit pas ramener à l'accueil")
        XCTContext.runActivity(named: "phase avant « \(phaseBefore) » → après « \(phaseLabel) »") { _ in }

        // ── 15 · Quitter, explicitement ──────────────────────────────────
        if tapIfExists("game.settings", timeout: 10) {
            settle(1)
            shot("15-reglages")
            if tapIfExists("settings.leave", timeout: 8) {
                // Confirmation éventuelle (« Quitter la partie ? »).
                for label in ["Quitter", "Quitter la partie"] {
                    let confirm = app.buttons[label]
                    if confirm.waitForExistence(timeout: 2), confirm.isHittable {
                        confirm.tap(); break
                    }
                }
                settle(2.5)
                shot("15-retour-accueil")
                let home = element("play.createOnline").waitForExistence(timeout: 20)
                if !home {
                    shot("15-DIAG-pas-de-retour-accueil")
                    XCTFail("« Quitter la partie » doit ramener à l'accueil")
                }
            } else {
                shot("15-DIAG-quitter-introuvable")
                XCTFail("le sheet de réglages doit offrir « Quitter la partie »")
            }
        } else {
            shot("15-DIAG-reglages-introuvables")
            XCTFail("le bouton de réglages mi-partie doit rester accessible")
        }

        dumpVisibleTexts()
    }

    // MARK: - Une annonce

    /// Annonce sur le board courant : on choisit une carte dans la main (toute
    /// annonce, Hauteur comprise, exige au moins une carte sélectionnée), on
    /// laisse la catégorie par défaut (Hauteur auto) ou on prend la première
    /// proposée, puis on confirme.
    private func announceOnCurrentBoard(step: Int, board: Int) {
        let opened = waitFor(90) {
            self.element("announce.panel").exists || self.element("announce.submitted").exists
        }
        if !opened {
            shot("\(pad(step))-DIAG-annonce-b\(board)-absente")
            XCTFail("le panneau d'annonce du Board \(board) doit s'ouvrir")
            return
        }
        settle(0.8)
        shot("\(pad(step))-annonce-b\(board)")

        guard !element("announce.submitted").exists else {
            // Déjà soumis (timer, ou tour rejoué) : rien à faire.
            return
        }

        // 1 carte de la main suffit — le kicker est complété par l'app.
        if !tapIfExists("game.hand.card0", timeout: 8) {
            shot("\(pad(step))-DIAG-main-intappable-b\(board)")
            XCTFail("les cartes de la main doivent être sélectionnables pendant l'annonce")
        }
        // Catégorie : « Hauteur » est l'auto-pick par défaut (pas de pilule
        // dans la grille) ; on prend « Paire » si elle est proposée, sinon on
        // reste sur le défaut.
        _ = tapIfExists("announce.cat.pair", timeout: 2)
        settle(0.4)
        shot("\(pad(step))-annonce-b\(board)-choisie")

        if !tapIfExists("announce.confirm", timeout: 8) {
            shot("\(pad(step))-DIAG-confirm-absent-b\(board)")
            XCTFail("le bouton « Confirmer » doit être là pendant l'annonce")
            return
        }

        let accepted = waitFor(20) {
            self.element("announce.submitted").exists || !self.element("announce.panel").exists
        }
        if !accepted {
            shot("\(pad(step))-DIAG-annonce-non-prise-b\(board)")
            XCTFail("après « Confirmer », l'annonce doit être enregistrée")
        }
        shot("\(pad(step))-annonce-b\(board)-envoyee")

        // Le reveal du board : les bots annoncent en 1-3 s, l'hôte résout.
        let revealed = waitFor(60) {
            self.phaseLabel.contains("Reveal") || self.element("game.mancheEnd").exists
                || (board < 3 && self.phaseLabel.contains("Annonces")
                    && !self.element("announce.submitted").exists)
        }
        if !revealed {
            shot("\(pad(step))-DIAG-reveal-b\(board)")
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
