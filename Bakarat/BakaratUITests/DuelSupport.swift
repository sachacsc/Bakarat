//
//  DuelSupport.swift
//  BakaratUITests
//
//  T34 (docs/PLAN_ONLINE_V2.md — P3) : l'outillage commun au duel à deux
//  simulateurs. `scripts/online-loop.sh --only duel` lance
//  `BakaratDuelHostUITests` sur `bakarat-host` et, 8 s plus tard,
//  `BakaratDuelGuestUITests` sur `bakarat-guest`.
//
//  RÈGLE DU DUEL : les deux côtés ne partagent AUCUN fichier, aucun signal,
//  aucune horloge. Ils ne se synchronisent que par l'état VISIBLE du salon
//  (« le panneau d'annonce est ouvert », « la manche 2 est terminée »). Chaque
//  étape est donc idempotente et les attentes sont généreuses : un côté qui
//  prend 20 s de retard ne doit pas faire tomber l'autre.
//
//  Le code du salon est volontairement à 4 caractères : `OnlineGameService`
//  refuse tout autre format côté client (« Code invalide (4 caractères
//  attendus) »), même si le RPC `room_create` en accepte 3 à 8.
//

import XCTest

/// Base commune aux deux côtés du duel : lancement, captures, attentes,
/// annonce idempotente.
class DuelUITestCase: XCTestCase {

    var app: XCUIApplication!

    /// « host » ou « guest » — préfixe des captures (`duel-host-01-…`).
    var side: String { "host" }

    /// Code du salon du duel. 4 caractères (contrainte client), surchargeable
    /// par le runner via `DUEL_CODE`.
    var duelCode: String {
        let raw = ProcessInfo.processInfo.environment["DUEL_CODE"] ?? ""
        return raw.isEmpty ? "QATE" : raw.uppercased()
    }

    var qaPassword: String {
        ProcessInfo.processInfo.environment["BAKARAT_QA_PASSWORD"] ?? ""
    }

    override func setUpWithError() throws {
        // Le duel doit aller au bout des trois scénarios, même si l'un rate.
        continueAfterFailure = true
    }

    // MARK: - Lancement

    func launch(email: String, extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = [
            "-autoLoginEmail", email,
            "-autoLoginPassword", qaPassword,
            "-qaPassword", qaPassword,
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
        answerSystemAlerts()
    }

    @discardableResult
    func answerSystemAlerts() -> Bool {
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

    // MARK: - Captures et attentes

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "duel-\(side)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func exists(_ identifier: String) -> Bool { element(identifier).exists }

    @discardableResult
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.5)
        }
        return condition()
    }

    @discardableResult
    func tapIfExists(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let el = element(identifier)
        guard el.waitForExistence(timeout: timeout), el.isHittable else { return false }
        el.tap()
        settle(0.5)
        return true
    }

    /// Attente d'écran avec capture `*-DIAG-*` + échec non bloquant.
    @discardableResult
    func expectScreen(_ identifier: String, timeout: TimeInterval,
                      shot name: String, because reason: String) -> Bool {
        if element(identifier).waitForExistence(timeout: timeout) { return true }
        shot("\(name)-DIAG-\(identifier)")
        XCTFail("\(reason) — « \(identifier) » absent après \(Int(timeout)) s")
        return false
    }

    // MARK: - Lecture de l'état visible

    var phaseLabel: String {
        let el = element("game.phaseLabel")
        return el.exists ? el.label : ""
    }

    /// Bannière « X anime maintenant la partie » / « Reconnexion… ».
    var bannerText: String {
        let el = element("game.banner")
        return el.exists ? el.label : ""
    }

    func boardCardCount(_ index: Int) -> Int {
        let title = element("game.board\(index).title")
        guard title.exists, let raw = title.value as? String else { return -1 }
        return Int(raw) ?? -1
    }

    /// Numéro de la manche terminée, lu dans « Manche N terminée ». nil si on
    /// n'est pas en fin de manche.
    func endedMancheNumber() -> Int? {
        let el = element("game.mancheEnd")
        guard el.exists else { return nil }
        let digits = el.label.compactMap { $0.isNumber ? $0 : nil }
        return Int(String(digits))
    }

    /// Vrai quand l'écran de jeu est là (et pas le lobby ni l'accueil).
    var isInGame: Bool { exists("game.phaseLabel") || exists("game.root") }

    // MARK: - Gestes de jeu (idempotents)

    /// Annonce sur le board ouvert, si et seulement s'il y a quelque chose à
    /// annoncer. Rejouable sans dommage : si l'annonce est déjà partie, on ne
    /// touche à rien. Retourne vrai si une annonce vient d'être envoyée.
    @discardableResult
    func announceIfPossible() -> Bool {
        guard exists("announce.panel"), !exists("announce.submitted") else { return false }
        // Toute annonce — Hauteur comprise — exige au moins une carte
        // sélectionnée (garde-fou anti-tap accidentel côté app).
        guard tapIfExists("game.hand.card0", timeout: 4) else { return false }
        _ = tapIfExists("announce.cat.pair", timeout: 1.5)
        guard tapIfExists("announce.confirm", timeout: 5) else { return false }
        _ = waitFor(15) { self.exists("announce.submitted") || !self.exists("announce.panel") }
        return true
    }

    /// Joue tout ce qui se présente jusqu'à la fin de la manche `number`
    /// (ou n'importe quelle fin de manche si `number` est nil).
    /// Les attentes sont longues : l'autre côté peut être en train de revenir
    /// d'un passage en arrière-plan.
    @discardableResult
    func playUntilMancheEnd(number: Int? = nil, timeout: TimeInterval = 180) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ended = endedMancheNumber(), number == nil || ended == number! {
                return true
            }
            announceIfPossible()
            settle(1.0)
        }
        return endedMancheNumber() != nil
    }

    /// Passe en arrière-plan `seconds` puis revient — le geste qui casse tout
    /// dans un protocole fragile (verrouillage, appel entrant, changement d'app).
    func background(_ seconds: TimeInterval) {
        XCUIDevice.shared.press(.home)
        settle(seconds)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 30)
        settle(3)
    }

    /// Joint la liste des textes visibles — le juge s'en sert quand une
    /// capture est ambiguë (le `qa.log` du container est exporté par le runner).
    func dumpVisibleTexts(_ name: String) {
        XCTContext.runActivity(named: "textes visibles · \(name)") { activity in
            let texts = app.staticTexts.allElementsBoundByIndex
                .prefix(200)
                .map { "\($0.identifier.isEmpty ? "-" : $0.identifier) · \($0.label)" }
                .joined(separator: "\n")
            let attachment = XCTAttachment(string: texts)
            attachment.name = "duel-\(side)-99-textes-\(name)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
