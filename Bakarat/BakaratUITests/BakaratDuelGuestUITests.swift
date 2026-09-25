//
//  BakaratDuelGuestUITests.swift
//  BakaratUITests
//
//  T34 — le côté INVITÉ du duel. Tourne sur le simulateur `bakarat-guest`,
//  démarré 8 s après l'hôte par `scripts/online-loop.sh` pour que le salon
//  `QATE` existe déjà.
//
//  L'invité rejoint par `-autoJoinCode`. Il ne sait rien de l'hôte : il lit
//  son écran, et rien d'autre. Ses trois scénarios sont le miroir de ceux de
//  l'hôte :
//    1. une manche complète à deux ;
//    2. il disparaît 20 s en pleine phase d'annonces, revient, et son annonce
//       doit encore passer (le serveur fusionne, l'hôte ne l'a pas effacé) ;
//    3. l'HÔTE disparaît 30 s : l'invité doit voir la partie avancer, ou la
//       bannière « X anime maintenant la partie » quand il reprend le bail.
//

import XCTest

final class BakaratDuelGuestUITests: DuelUITestCase {

    override var side: String { "guest" }

    func test00_duelInvite() {
        launch(email: "bakaratqa.g1@bakarat.test",
               extra: ["-autoJoinCode", duelCode])

        // ── 01 · Le salon est rejoint tout seul ──────────────────────────
        let arrived = waitFor(90) { self.exists("lobby.code") || self.isInGame }
        if !arrived {
            diag("01-DIAG-salon-introuvable")
            XCTFail("l'invité doit rejoindre \(duelCode) en moins de 90 s (-autoJoinCode)")
        }
        settle(1)
        shot("01-lobby")

        let inGame = expectScreen("game.phaseLabel", timeout: 90, shot: "02",
                                  because: "l'hôte démarre à 2 joueurs : l'invité doit suivre")
        settle(1)
        shot("02-partie-lancee")
        guard inGame else { dumpVisibleTexts("abandon"); return }

        // L'invité ne voit QUE sa main (expurgation serveur) — visuellement,
        // c'est la bulle du bas avec ses cartes.
        XCTAssertTrue(element("game.hand.card0").waitForExistence(timeout: 60),
                      "l'invité doit recevoir sa main")
        shot("03-main-invite")

        // ── 04 · Scénario 1 : une manche complète ────────────────────────
        let manche1 = playUntilMancheEnd(number: 1, timeout: 240)
        if !manche1 {
            diag("04-DIAG-manche-1-inachevee")
            XCTFail("la manche 1 du duel doit aller jusqu'à son récapitulatif")
        }
        settle(1)
        shot("04-manche-1-terminee")

        // ── 05 · Scénario 2 : l'invité s'absente 20 s en pleine annonce ──
        // (c'est l'hôte qui lance la manche 2 ; l'invité l'attend. L'hôte doit
        // d'abord faire défiler jusqu'à « Manche suivante », taper, parfois
        // retaper : 90 s au minimum, 150 s ici pour absorber la charge.)
        let manche2Dealt = waitFor(150) { self.nextMancheStarted(after: 1) }
        if !manche2Dealt {
            diag("05-DIAG-manche-2-jamais-vue")
            XCTFail("l'invité doit voir la manche 2 arriver")
        }
        shot("05-manche-2-distribuee")
        // Annonces en cours (libellé « BN · Ns » / « Annonces » + valeur BN),
        // pas encore envoyée, bouton « Confirmer » exposé.
        let announcing = waitFor(120) {
            self.isAnnouncingAny && !self.exists("announce.submitted") && self.confirmButton.exists
        }
        if !announcing {
            diag("05-DIAG-pas-d-annonce-a-faire")
        }
        shot("05-avant-absence")

        background(20)
        shot("06-retour-invite")

        let stillThere = element("game.root").waitForExistence(timeout: 30) || isInGame
        if !stillThere {
            diag("06-DIAG-partie-perdue-cote-invite")
            XCTFail("après 20 s en arrière-plan, l'invité doit retrouver la partie")
        }
        XCTAssertFalse(exists("play.createOnline"),
                       "revenir ne doit jamais ramener l'invité à l'accueil")

        // Et son annonce doit encore passer.
        let sent = waitFor(90) {
            if self.exists("announce.submitted") { return true }
            return self.announceIfPossible()
        }
        if !sent {
            diag("07-DIAG-annonce-impossible-apres-retour")
            XCTFail("après une absence de 20 s, l'invité doit pouvoir annoncer")
        }
        shot("07-annonce-apres-retour")

        let manche2 = playUntilMancheEnd(number: 2, timeout: 300)
        if !manche2 {
            diag("08-DIAG-manche-2-inachevee")
            XCTFail("la manche 2 doit se terminer malgré l'absence de l'invité")
        }
        shot("08-manche-2-terminee")

        // ── 09 · Scénario 3 : c'est l'HÔTE qui disparaît 30 s ────────────
        // L'invité ne fait RIEN de spécial : il regarde. La partie doit
        // avancer (bail repris → « X anime maintenant la partie »), sans
        // jamais se figer sur un écran mort.
        let manche3Dealt = waitFor(150) { self.nextMancheStarted(after: 2) }
        if !manche3Dealt {
            diag("09-DIAG-manche-3-jamais-vue")
        }
        shot("09-manche-3")

        let phaseBefore = phaseLabel
        var sawBanner = false
        let moved = waitFor(120) {
            if !self.bannerText.isEmpty { sawBanner = true }
            self.announceIfPossible()
            return self.phaseLabel != phaseBefore || sawBanner || self.endedMancheNumber() != nil
        }
        if sawBanner { shot("10-banniere-releve") }
        if !moved {
            diag("10-DIAG-partie-figee-hote-absent")
            XCTFail("l'absence de 30 s de l'hôte ne doit pas figer l'invité : "
                    + "soit la bannière « anime maintenant », soit la phase avance "
                    + "(lu : « \(phaseLabel) »)")
        }
        XCTContext.runActivity(named: "phase « \(phaseBefore) » → « \(phaseLabel) »"
                               + (bannerText.isEmpty ? "" : " · bannière « \(bannerText) »")) { _ in }

        settle(5)
        shot("11-duel-fin")
        XCTAssertTrue(isInGame, "à la fin du duel, l'invité est toujours dans la partie")
        XCTAssertLessThanOrEqual(snapshotTimeouts, maxSnapshotTimeouts,
                                 "trop de requêtes UI expirées : l'app de l'invité s'est figée")
        dumpVisibleTexts("fin")
    }
}
