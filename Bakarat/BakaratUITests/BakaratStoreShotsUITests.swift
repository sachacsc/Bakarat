//
//  BakaratStoreShotsUITests.swift
//  BakaratUITests
//
//  Captures App Store (2026-10-09). Ce n'est pas un test : c'est un
//  photographe. Il met l'app en scène avec les hooks QA (nom « Sacha », bots
//  « Léa »/« Marc ») et attache une capture plein écran par écran clé.
//  Langue : env SHOT_LANG = en | fr (défaut en). Export par xcresulttool
//  (scripts/store-shots.sh) vers docs/store/screenshots/<lang>/.
//

import XCTest

final class BakaratStoreShotsUITests: XCTestCase {

    private var app: XCUIApplication!
    private let lang = ProcessInfo.processInfo.environment["SHOT_LANG"] ?? "en"
    private var qaPassword: String {
        ProcessInfo.processInfo.environment["BAKARAT_QA_PASSWORD"] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Lanceur

    private func launch(extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = [
            "-autoLoginEmail", "bakaratqa.host@bakarat.test",
            "-autoLoginPassword", qaPassword,
            "-qaPassword", qaPassword,
            "-qaDisplayName", "Sacha",
            "-qaBotNames", "Léa,Marc",
            "-AppleLanguages", "(\(lang))",
            "-AppleLocale", lang == "fr" ? "fr_FR" : "en_US",
        ] + extra
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
        attachment.name = "store-\(lang)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func labeled(_ labels: [String]) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func buttonStarting(_ prefixes: [String]) -> XCUIElement {
        let preds = prefixes.map { NSPredicate(format: "label BEGINSWITH %@", $0) }
        return app.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: preds)).firstMatch
    }

    @discardableResult
    private func tap(_ el: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        if el.isHittable { el.tap() } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        settle(0.6)
        return true
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.5)
        }
        return condition()
    }

    private var phaseLabel: String {
        let el = element("game.phaseLabel")
        return el.exists ? el.label : ""
    }

    private var confirmButton: XCUIElement {
        let byIdentifier = element("announce.confirm")
        if byIdentifier.exists { return byIdentifier }
        return buttonStarting(["Confirmer", "Confirm"])
    }

    // MARK: - 1 · Accueil, comptes, compteur

    func test01_homeAccountsCounter() {
        // `-online_last_room_at 0` : pas de carte « Reprendre le salon » héritée
        // d'une session précédente (UserDefaults surchargés par l'argument).
        launch(extra: ["-online_last_room_at", "0"])
        settle(3)
        shot("01-home")

        // Onglet Comptes
        let tabBar = app.tabBars.firstMatch
        if tap(tabBar.buttons.matching(NSPredicate(format: "label IN {'Accounts','Comptes'}")).firstMatch) {
            settle(2)
            shot("02-accounts")
            tap(tabBar.buttons.matching(NSPredicate(format: "label IN {'Play','Jouer'}")).firstMatch)
            settle(1)
        }

        // Compteur : création avec 4 joueurs, puis la manche en cours.
        guard tap(element("play.createCounter")) else { return }
        settle(1)
        let nameField = app.textFields.firstMatch
        if nameField.waitForExistence(timeout: 5) {
            nameField.tap()
            nameField.typeText(lang == "fr" ? "Soirée chez Léa" : "Poker night at Léa's")
        }
        for (i, player) in ["Léa", "Marc", "Sacha", "Nina"].enumerated() {
            let fields = app.textFields.matching(NSPredicate(format: "placeholderValue IN {'Prénom','First name'}"))
            let field = fields.element(boundBy: i)
            guard field.waitForExistence(timeout: 4) else { break }
            field.tap()
            field.typeText(player)
            settle(0.3)
        }
        // « C'est moi » sur la ligne de Sacha, puis clavier rangé avant la capture.
        let meChip = app.buttons.matching(NSPredicate(format: "label IN {\"That's me\", \"C'est moi\", \"C’est moi\"}")).element(boundBy: 2)
        if meChip.exists { tap(meChip) }
        if app.keyboards.count > 0 {
            // Un tap hors champ range le clavier (l'en-tête « Players » est inerte).
            let header = app.staticTexts.matching(NSPredicate(format: "label IN {'Players','Joueurs'}")).firstMatch
            if header.exists { header.tap() } else { app.navigationBars.firstMatch.tap() }
            settle(0.8)
            if app.keyboards.count > 0 { app.swipeDown(); settle(0.8) }
        }
        shot("03-counter-setup")
        if tap(labeled(["Create", "Créer"])) {
            settle(2)
            // Sélectionne un gagnant par board (cellules au nom du joueur) :
            // chaque board a sa propre grille, donc le même nom apparaît 3 fois.
            let winners = ["Léa", "Marc", "Léa"]
            for (idx, name) in winners.enumerated() {
                let cells = app.buttons.matching(NSPredicate(format: "label == %@", name))
                let cell = cells.element(boundBy: name == "Léa" && idx == 2 ? 2 : idx)
                if cell.waitForExistence(timeout: 4) { tap(cell) } else { break }
            }
            settle(0.8)
            shot("04-counter-round")
        }
    }

    // MARK: - 2 · Partie en ligne

    func test02_onlineGame() {
        launch(extra: ["-autoCreateRoom", "-qaBots", "2", "-autoStartAt", "3", "-autoStartDelay", "6"])
        guard element("lobby.root").waitForExistence(timeout: 40) else { return }
        _ = waitFor(25) { self.element("lobby.playerCount").exists && self.element("lobby.playerCount").label.contains("3") }
        settle(1)
        shot("05-lobby")

        guard element("game.root").waitForExistence(timeout: 60) else { return }
        // Annonces du Board 1 : panneau ouvert avec la main.
        guard waitFor(90, { self.confirmButton.exists }) else { shot("06-board"); return }
        settle(1)
        shot("06-announce")
        tap(confirmButton)
        _ = waitFor(10) { !self.confirmButton.exists }
        settle(2.5)
        shot("07-reveal")

        // Boards 2 et 3 + tie-breaks éventuels, jusqu'à la fin de manche.
        var confirms = 0
        _ = waitFor(240) {
            if self.element("game.mancheEnd").exists { return true }
            if self.confirmButton.exists, confirms < 8 {
                confirms += 1
                self.tap(self.confirmButton, timeout: 2)
                _ = self.waitFor(8) { !self.confirmButton.exists || self.element("game.mancheEnd").exists }
            }
            return false
        }
        settle(1.5)
        shot("08-end-of-round")

        if tap(element("game.balance")) {
            settle(1.5)
            shot("09-balance")
        }
    }
}
