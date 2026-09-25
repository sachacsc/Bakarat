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

    /// Requêtes XCUITest expirées (« Failed to get matching snapshots:
    /// Timed out while evaluating UI query »). Run 2026-09-25-2137 : deux
    /// simulateurs chargés + le chrono d'annonce (TimelineView 1 Hz) font
    /// grimper le coût d'un snapshot de 0,3 s à 35 s ; la requête finit par
    /// expirer et XCTest enregistre un échec qui masque le vrai verdict.
    /// On en tolère `maxSnapshotTimeouts` (notés, pas comptés en échec) ;
    /// au-delà, ils redeviennent des échecs — l'app est alors vraiment figée.
    private(set) var snapshotTimeouts = 0
    let maxSnapshotTimeouts = 3

    override func setUpWithError() throws {
        // Le duel doit aller au bout des trois scénarios, même si l'un rate.
        continueAfterFailure = true
        snapshotTimeouts = 0
    }

    override func record(_ issue: XCTIssue) {
        let text = issue.compactDescription
        if text.contains("Failed to get matching snapshots")
            || text.contains("Timed out while evaluating UI query") {
            snapshotTimeouts += 1
            if snapshotTimeouts <= maxSnapshotTimeouts {
                let attachment = XCTAttachment(
                    string: "[toléré \(snapshotTimeouts)/\(maxSnapshotTimeouts)] " + text)
                attachment.name = "duel-\(side)-98-requete-lente-\(snapshotTimeouts)"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
        }
        super.record(issue)
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

    /// Dump de la hiérarchie d'accessibilité (tronqué à 20 000 caractères) :
    /// c'est lui qui permet de corriger un identifiant sans rejouer le duel.
    func attachHierarchy(_ name: String) {
        let dump = String(app.debugDescription.prefix(20_000))
        let attachment = XCTAttachment(string: dump)
        attachment.name = "duel-\(side)-\(name)-hierarchie"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Capture + hiérarchie : le couple de diagnostic de tout échec d'attente.
    func diag(_ name: String) {
        shot(name)
        attachHierarchy(name)
    }

    func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func exists(_ identifier: String) -> Bool { element(identifier).exists }

    /// Premier bouton dont le label commence par `prefix` (repli quand
    /// l'identifiant n'est pas exposé).
    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// L'élément `identifier` s'il existe, sinon le bouton de label `prefix…`.
    func resolve(_ identifier: String, orButtonStartingWith prefix: String) -> XCUIElement {
        let byIdentifier = element(identifier)
        if byIdentifier.exists { return byIdentifier }
        return button(startingWith: prefix)
    }

    /// Polling doux. Si l'évaluation de la condition devient lente (snapshot
    /// qui s'alourdit), on espace les sondes au lieu d'enchaîner des requêtes
    /// qui finissent par expirer — et on ne dépasse jamais l'échéance d'une
    /// évaluation supplémentaire.
    @discardableResult
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var pause: TimeInterval = 0.5
        while Date() < deadline {
            let started = Date()
            if condition() { return true }
            let cost = Date().timeIntervalSince(started)
            pause = cost > 5 ? min(8, max(pause * 2, cost / 2)) : 0.5
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            settle(min(pause, remaining))
        }
        return false
    }

    @discardableResult
    func tapIfExists(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        tap(element(identifier), timeout: timeout)
    }

    /// Tape un élément ; s'il n'est pas « hittable » (élément composite), on
    /// tape la coordonnée de son centre plutôt que d'abandonner.
    @discardableResult
    func tap(_ el: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        if el.isHittable {
            el.tap()
        } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        settle(0.6)
        return true
    }

    /// Attente d'écran avec capture `*-DIAG-*` + échec non bloquant.
    @discardableResult
    func expectScreen(_ identifier: String, timeout: TimeInterval,
                      shot name: String, because reason: String) -> Bool {
        if element(identifier).waitForExistence(timeout: timeout) { return true }
        diag("\(name)-DIAG-\(identifier)")
        XCTFail("\(reason) — « \(identifier) » absent après \(Int(timeout)) s")
        return false
    }

    // MARK: - Lecture de l'état visible

    var phaseLabel: String {
        let el = element("game.phaseLabel")
        return el.exists ? el.label : ""
    }

    /// Valeur d'accessibilité du libellé de phase : le board actif (« B1 »,
    /// « B2 », « B3 », « Split »…) — `.accessibilityValue(navLabelForActiveBoard)`.
    var phaseValue: String {
        let el = element("game.phaseLabel")
        guard el.exists else { return "" }
        return (el.value as? String) ?? ""
    }

    /// Annonces du board N : libellé « BN · 27s » (avec chrono), ou
    /// « Annonces » + valeur d'accessibilité « BN » (sans chrono).
    func isAnnouncing(board: Int) -> Bool {
        let label = phaseLabel
        if label.hasPrefix("B\(board) ") { return true }
        guard label.hasPrefix("Annonces") else { return false }
        return phaseValue == "B\(board)"
    }

    /// Une phase d'annonce quelconque : board 1-3 ou tie-break. UNE seule
    /// lecture du libellé (le chrono rend chaque snapshot coûteux).
    var isAnnouncingAny: Bool {
        let label = phaseLabel
        if label.hasPrefix("Annonces") || label.hasPrefix("Split")
            || label.localizedCaseInsensitiveContains("Tie-break — annonces") { return true }
        return (1...3).contains { label.hasPrefix("B\($0) ") }
    }

    /// Le bouton « Confirmer : … » du panneau d'annonce. L'identifiant peut
    /// être écrasé par le `game.root` du conteneur (run 2026-09-25-2010) :
    /// repli par label, sur les boutons d'abord, puis sur tout élément.
    var confirmButton: XCUIElement {
        let byIdentifier = element("announce.confirm")
        if byIdentifier.exists { return byIdentifier }
        let byButton = button(startingWith: "Confirmer")
        if byButton.exists { return byButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Confirmer"))
            .firstMatch
    }

    /// Le bouton « Manche suivante » du récap (hôte seulement).
    var nextMancheButton: XCUIElement {
        resolve("game.nextManche", orButtonStartingWith: "Manche suivante")
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
    ///
    /// Recette du tour (BakaratTourUITests) : la phase se lit dans le libellé
    /// de nav, pas dans `announce.panel` ; la catégorie reste « Hauteur »
    /// (auto-pick, RULES.md) — choisir « Paire » exigerait une main
    /// compatible. Le tap sur une carte est un best-effort.
    @discardableResult
    func announceIfPossible() -> Bool {
        // Sonde la moins chère d'abord : le libellé de phase.
        guard isAnnouncingAny else { return false }
        guard !exists("announce.submitted") else { return false }
        let confirm = confirmButton
        guard confirm.exists else { return false }
        let card0 = element("game.hand.card0")
        if card0.exists, card0.isHittable {
            card0.tap()
            settle(0.4)
        }
        guard tap(confirmButton, timeout: 5) else { return false }
        _ = waitFor(15) {
            self.exists("announce.submitted") || !self.confirmButton.exists
                || self.exists("game.mancheEnd")
        }
        return true
    }

    /// Fait défiler l'écran de jeu jusqu'à ce que « Manche suivante » soit
    /// touchable : il est SOUS le pli et sous la bulle de main (run
    /// 2026-09-25-2137 : introuvable/non touchable sans défilement).
    @discardableResult
    func revealNextMancheButton() -> Bool {
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

    /// Vrai quand la manche qui suit la manche `number` a démarré : le récap
    /// `game.mancheEnd` a disparu (ou annonce une autre manche) OU le libellé
    /// de phase a quitté « Fin de manche ».
    func nextMancheStarted(after number: Int) -> Bool {
        if let ended = endedMancheNumber() {
            if ended > number { return true }   // la suivante est même déjà finie
            let label = phaseLabel
            return !label.isEmpty && !label.hasPrefix("Fin de manche")
        }
        return isInGame
    }

    /// Hôte : fait défiler, tape « Manche suivante », attend la redistribution ;
    /// retape une fois si le premier tap s'est perdu pendant le défilement.
    @discardableResult
    func startNextManche(after number: Int, step: String) -> Bool {
        guard revealNextMancheButton() else {
            diag("\(step)-DIAG-manche-suivante-introuvable")
            XCTFail("l'hôte doit pouvoir lancer la manche \(number + 1) (« Manche suivante » absent)")
            return false
        }
        shot("\(step)-manche-suivante-visible")
        _ = tap(nextMancheButton, timeout: 8)
        var started = waitFor(20) { self.nextMancheStarted(after: number) }
        if !started, nextMancheButton.exists {
            revealNextMancheButton()
            _ = tap(nextMancheButton, timeout: 5)
            started = waitFor(40) { self.nextMancheStarted(after: number) }
        }
        if !started {
            diag("\(step)-DIAG-manche-\(number + 1)-non-distribuee")
            XCTFail("la manche \(number + 1) doit être distribuée après « Manche suivante »")
        }
        return started
    }

    /// Joue tout ce qui se présente jusqu'à la fin de la manche `number`
    /// (ou n'importe quelle fin de manche si `number` est nil).
    /// Les attentes sont longues : l'autre côté peut être en train de revenir
    /// d'un passage en arrière-plan.
    @discardableResult
    func playUntilMancheEnd(number: Int? = nil, timeout: TimeInterval = 180) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ended = endedMancheNumber(), number == nil || ended >= number! {
                return true
            }
            announceIfPossible()
            settle(1.5)
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
