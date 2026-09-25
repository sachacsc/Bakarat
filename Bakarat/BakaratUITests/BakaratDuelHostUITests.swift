//
//  BakaratDuelHostUITests.swift
//  BakaratUITests
//
//  T34 — le côté HÔTE du duel. Tourne sur le simulateur `bakarat-host`,
//  démarre 8 s avant le guest (cf. `scripts/online-loop.sh`, section duel).
//
//  L'hôte crée le salon `QATE` (`-autoCreateRoom -qaRoomCode`) et démarre dès
//  que le second joueur est là (`-autoStartAt 2`). Il ne sait RIEN du guest :
//  il ne lit que son propre écran.
//
//  Trois scénarios, à la suite, dans une seule session d'app (couper l'app
//  entre deux scénarios ferait perdre le salon au partenaire) :
//    1. une manche complète à deux ;
//    2. la manche 2, pendant laquelle le guest disparaît 20 s — l'hôte ne doit
//       ni forfait-er le joueur, ni se figer ;
//    3. la manche 3, pendant laquelle l'HÔTE disparaît 30 s — à son retour, la
//       partie est toujours là (et il est peut-être redevenu invité : le bail
//       a pu passer au guest, c'est le comportement attendu, pas un échec).
//

import XCTest

final class BakaratDuelHostUITests: DuelUITestCase {

    override var side: String { "host" }

    func test00_duelHote() {
        launch(email: "bakaratqa.host@bakarat.test",
               extra: ["-qaRoomCode", duelCode, "-autoCreateRoom", "-autoStartAt", "2"])

        // ── 01 · Le salon s'ouvre tout seul ──────────────────────────────
        expectScreen("lobby.code", timeout: 60, shot: "01",
                     because: "l'hôte doit ouvrir le salon du duel sans geste")
        settle(1)
        shot("01-lobby")
        let code = element("lobby.code")
        if code.exists {
            XCTAssertEqual(code.label, duelCode, "le salon du duel doit porter le code convenu")
        }

        // ── 02 · Le guest arrive, la partie démarre ──────────────────────
        let joined = waitFor(90) {
            let counter = self.element("lobby.playerCount")
            return (counter.exists && (Int(counter.label) ?? 0) >= 2) || self.isInGame
        }
        if !joined {
            diag("02-DIAG-guest-jamais-arrive")
            XCTFail("le guest doit rejoindre \(duelCode) en moins de 90 s")
        }
        shot("02-guest-arrive")

        let inGame = expectScreen("game.phaseLabel", timeout: 60, shot: "03",
                                  because: "-autoStartAt 2 doit lancer la partie dès le duo formé")
        settle(1)
        shot("03-partie-lancee")
        guard inGame else { dumpVisibleTexts("abandon"); return }

        // ── 04 · Scénario 1 : une manche complète ────────────────────────
        let dealt = waitFor(60) { (1...3).allSatisfy { self.boardCardCount($0) == 5 } }
        if !dealt {
            diag("04-DIAG-boards-incomplets")
            XCTFail("les 15 cartes communautaires doivent arriver en moins de 60 s")
        }
        shot("04-boards-complets")

        let manche1 = playUntilMancheEnd(number: 1, timeout: 240)
        if !manche1 {
            diag("05-DIAG-manche-1-inachevee")
            XCTFail("la manche 1 du duel doit aller jusqu'à son récapitulatif")
        }
        settle(1)
        shot("05-manche-1-terminee")

        // ── 06 · Scénario 2 : le guest s'absente pendant la manche 2 ─────
        // Côté hôte, il n'y a rien à faire de spécial : on enchaîne, et on
        // vérifie qu'on ne se fige pas en attendant une annonce qui tarde.
        // « Manche suivante » est SOUS le pli et sous la bulle de main : on
        // fait défiler jusqu'à ce qu'il soit touchable (recette du tour).
        startNextManche(after: 1, step: "06")
        settle(1)
        shot("06-manche-2-distribuee")

        let manche2 = playUntilMancheEnd(number: 2, timeout: 300)
        if !manche2 {
            diag("07-DIAG-manche-2-inachevee")
            XCTFail("l'absence de 20 s du guest ne doit pas bloquer la manche 2")
        }
        settle(1)
        shot("07-manche-2-terminee")
        XCTAssertTrue(isInGame, "l'hôte est toujours dans la partie après l'absence du guest")

        // ── 08 · Scénario 3 : c'est l'HÔTE qui s'absente 30 s ────────────
        if !startNextManche(after: 2, step: "08") {
            dumpVisibleTexts("fin")
            return
        }
        // On attend une phase « vivante » (annonces ou reveal) avant de partir :
        // c'est là que la coupure fait le plus mal. Avec chrono, le libellé
        // d'annonce est « BN · 27s » (pas « Annonces ») → `isAnnouncingAny`.
        _ = waitFor(90) {
            self.isAnnouncingAny || self.phaseLabel.contains("Reveal")
        }
        shot("08-avant-absence-hote")
        let phaseBefore = phaseLabel

        background(30)
        shot("09-retour-hote")

        let alive = element("game.root").waitForExistence(timeout: 30) || isInGame
        if !alive {
            diag("09-DIAG-partie-perdue-cote-hote")
            XCTFail("après 30 s en arrière-plan, l'hôte doit retrouver SA partie")
        }
        XCTAssertFalse(exists("play.createOnline"),
                       "revenir ne doit jamais ramener l'hôte à l'accueil")
        XCTContext.runActivity(named: "phase « \(phaseBefore) » → « \(phaseLabel) »"
                               + (bannerText.isEmpty ? "" : " · bannière « \(bannerText) »")) { _ in }

        // La partie continue — que l'hôte ait gardé le bail ou que le guest
        // l'ait repris (relève d'hôte, T22), les deux sont des fins heureuses.
        announceIfPossible()
        settle(5)
        shot("10-duel-fin")
        XCTAssertLessThanOrEqual(snapshotTimeouts, maxSnapshotTimeouts,
                                 "trop de requêtes UI expirées : l'app de l'hôte s'est figée")
        dumpVisibleTexts("fin")
    }
}
