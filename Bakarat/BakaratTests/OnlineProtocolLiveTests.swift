//
//  OnlineProtocolLiveTests.swift
//  BakaratTests
//
//  T31 (docs/PLAN_ONLINE_V2.md — P3) : le protocole, en vrai.
//
//  Deux (ou trois) `OnlineGameService` dans le MÊME process, chacun sur son
//  propre `SupabaseClient` et son propre compte QA, contre le Supabase réel.
//  On ne simule rien : les RPC `room_*`, le CAS `room_publish`, l'expurgation
//  des mains, le bail d'hôte et la fusion des annonces sont ceux de la prod.
//
//  Ces tests coûtent du réseau et du temps : ils ne tournent QUE si le runner
//  pose `BAKARAT_LIVE_TESTS=1` (via `TEST_RUNNER_BAKARAT_LIVE_TESTS=1`), avec
//  le mot de passe QA dans `BAKARAT_QA_PASSWORD`. Ils sont sérialisés : les
//  comptes QA sont partagés, deux salons simultanés pour la même identité
//  n'auraient aucun sens.
//
//  Toutes les attentes sont des attentes de CONVERGENCE (polling), jamais des
//  `sleep` calibrés : le protocole converge, il ne promet pas de délais.
//

import Foundation
import Testing
@testable import Bakarat

@MainActor
@Suite("T31 · Protocole online (live Supabase)",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BAKARAT_LIVE_TESTS"] == "1"))
struct OnlineProtocolLiveTests {

    // MARK: - Mise en place commune

    /// Un salon ouvert par l'hôte et rejoint par un invité.
    private struct Table {
        let host: LiveFixtures.Identity
        let guest: LiveFixtures.Identity
        let hostService: OnlineGameService
        let guestService: OnlineGameService
        let code: String
    }

    /// Hôte crée, invité rejoint. Le code est celui tiré par `createRoom`
    /// (aléatoire, donc unique par test — `-qaRoomCode` n'est pas passé au
    /// process des tests unitaires, seulement au tour XCUITest).
    private static func openTable(guestChaos: ChaosProfile? = nil) async throws -> Table {
        let host = try await LiveFixtures.signIn(LiveFixtures.hostEmail, displayName: "QA-host")
        let guest = try await LiveFixtures.signIn(LiveFixtures.guest1Email, displayName: "QA-g1")

        let hostService = LiveFixtures.makeService(host)
        await hostService.createRoom(myUserId: host.userId, myDisplayName: host.displayName)
        guard let code = hostService.room?.code else {
            throw LiveFixtures.LiveError.noRoom("createRoom (\(hostService.lastError ?? "sans erreur"))")
        }

        let guestService = LiveFixtures.makeService(guest, chaos: guestChaos)
        _ = await guestService.joinRoom(code: code, myUserId: guest.userId,
                                        myDisplayName: guest.displayName)

        return Table(host: host, guest: guest,
                     hostService: hostService, guestService: guestService, code: code)
    }

    /// Attend que l'invité soit visible côté hôte, puis démarre la partie.
    private static func start(_ t: Table) async -> Bool {
        let joined = await LiveFixtures.waitUntil(timeout: 25) {
            (t.hostService.room?.participants.count ?? 0) >= 2
        }
        guard joined else { return false }
        await t.hostService.startGame()
        return true
    }

    // MARK: - 1 · Créer, rejoindre, démarrer

    @Test("createJoinStart : les deux voient la partie, l'invité ne voit QUE sa main")
    func createJoinStart() async throws {
        let t = try await Self.openTable()

        #expect(t.hostService.role == .host)
        #expect(t.guestService.role == .guest)
        #expect(t.guestService.room?.code == t.code, "l'invité a rejoint le bon salon")

        let started = await Self.start(t)
        #expect(started, "l'invité doit apparaître dans le lobby de l'hôte")

        // Les deux basculent en partie.
        let hostPlaying = await LiveFixtures.waitUntil(timeout: 20) {
            t.hostService.room?.status == .playing
        }
        let guestPlaying = await LiveFixtures.waitUntil(timeout: 20) {
            t.guestService.room?.status == .playing
        }
        #expect(hostPlaying, "l'hôte voit status == .playing")
        #expect(guestPlaying, "l'invité voit status == .playing (snapshot propagé)")
        #expect(t.hostService.phase == .playing)
        #expect(t.guestService.phase == .playing)

        // Expurgation : l'invité reçoit sa main, et rien d'autre.
        let gotHand = await LiveFixtures.waitUntil(timeout: 20) {
            (t.guestService.room?.gameState?.hands.count ?? 0) == 1
        }
        #expect(gotHand, "l'invité reçoit exactement UNE main")
        if let gs = t.guestService.room?.gameState {
            #expect(gs.hands.count == 1, "jamais la main d'un autre joueur")
            let mySeat = LiveFixtures.seat(of: t.guest.userId, in: t.guestService)
            #expect(gs.hands.keys.first == mySeat, "et c'est la sienne")
            #expect(gs.hands.values.first?.count == 6, "2 joueurs actifs → 6 cartes")
            #expect(gs.pendingFlop.isEmpty, "les cartes à venir sont expurgées côté invité")
            #expect(gs.pendingTurns.isEmpty)
            #expect(gs.pendingRivers.isEmpty)
            #expect(gs.burns.isEmpty)
        }
        // L'hôte, lui, voit tout (il est la source du tempo).
        #expect(t.hostService.room?.gameState?.hands.count == 2)
        #expect(t.hostService.room?.gameState?.pendingFlop.count == 3)

        // Les 15 cartes communes arrivent, puis les annonces s'ouvrent.
        // Budget d'expérience : ~17 s de tempo + les allers-retours RPC.
        let (allDealt, seconds) = await LiveFixtures.measureWait(timeout: 45) {
            let cards = t.guestService.room?.gameState?.communityCards ?? []
            return cards.count == 3 && cards.allSatisfy { $0.count == 5 }
        }
        #expect(allDealt, "les 15 cartes communautaires doivent être révélées")
        #expect(seconds < 40, "distribution + flop/turn/river en \(Int(seconds)) s — trop lent au-delà de 40 s")

        let announcing = await LiveFixtures.waitUntil(timeout: 20) {
            t.guestService.room?.gameState?.phase == .announcing
        }
        #expect(announcing, "après le river, on entre en phase d'annonces")

        await LiveFixtures.cleanup([t.guestService, t.hostService])
    }

    // MARK: - 2 · Annonces, reveal, fin de manche

    @Test("announceAndReveal : 3 boards, mancheEnd, scores à somme nulle")
    func announceAndReveal() async throws {
        let t = try await Self.openTable()
        let started = await Self.start(t)
        #expect(started)

        // Les deux jouent tout seuls : dès qu'un board leur est ouvert, ils
        // annoncent la meilleure catégorie VALIDE (HandEvaluator).
        let hostPlay = LiveFixtures.autoplay(t.hostService, userId: t.host.userId)
        let guestPlay = LiveFixtures.autoplay(t.guestService, userId: t.guest.userId)

        // Board 1 : annonces puis reveal.
        let board1Revealed = await LiveFixtures.waitUntil(timeout: 70) {
            guard let gs = t.guestService.room?.gameState else { return false }
            return gs.boardResults[0] != nil
        }
        #expect(board1Revealed, "le Board 1 est résolu une fois les deux annonces reçues")

        // Board 2 ouvert : on est repassé en `announcing` sur le board suivant.
        let board2Announcing = await LiveFixtures.waitUntil(timeout: 40) {
            guard let gs = t.guestService.room?.gameState else { return false }
            return gs.currentBoard >= 1
        }
        #expect(board2Announcing, "le tempo enchaîne sur le Board 2")

        // Fin de manche (tie-breaks compris : l'autoplay les joue aussi).
        let ended = await LiveFixtures.waitUntil(timeout: 120) {
            t.hostService.room?.gameState?.phase == .mancheEnd
        }
        #expect(ended, "les 3 boards résolus → mancheEnd")

        let converged = await LiveFixtures.waitUntil(timeout: 30) {
            t.guestService.version == t.hostService.version
                && t.guestService.room?.gameState?.phase == .mancheEnd
        }
        #expect(converged,
                "même version des deux côtés (hôte v\(t.hostService.version), invité v\(t.guestService.version))")

        if let gs = t.hostService.room?.gameState {
            #expect(gs.boardResults.allSatisfy { $0 != nil }, "les 3 boards sont résolus")
            let total = gs.players.reduce(0.0) { $0 + $1.score }
            #expect(abs(total) < 0.001, "le jeu est à somme nulle, lu : \(total)")
        }

        let archived = await LiveFixtures.waitUntil(timeout: 25) {
            t.hostService.room?.pastManches.count == 1
        }
        #expect(archived, "la manche terminée est archivée une seule fois")

        // En `mancheEnd` le serveur n'expurge plus : tout le monde voit tout.
        #expect(t.guestService.room?.gameState?.hands.count == 2,
                "à la fin de manche, les mains sont dévoilées à tous")

        await LiveFixtures.cleanup([t.guestService, t.hostService],
                                   tasks: [hostPlay, guestPlay])
    }

    // MARK: - 3 · Coupure de l'invité pendant les annonces

    @Test("guestBlipResync : l'invité perd le socket 10 s et converge quand même")
    func guestBlipResync() async throws {
        // Le profil chaos coupe le socket de l'invité dès qu'il voit un
        // snapshot en `announcing`, et resynchronise 10 s plus tard (T24).
        let blip = ChaosProfile.named("guest-blip-10s")
        #expect(blip != nil, "le profil chaos guest-blip-10s doit exister")

        let t = try await Self.openTable(guestChaos: blip)
        let started = await Self.start(t)
        #expect(started)

        // Seul l'hôte joue : sans l'annonce de l'invité, le board ne peut pas
        // se résoudre — la fenêtre d'observation est donc stable.
        let hostPlay = LiveFixtures.autoplay(t.hostService, userId: t.host.userId)

        let announcing = await LiveFixtures.waitUntil(timeout: 60) {
            t.hostService.room?.gameState?.phase == .announcing
        }
        #expect(announcing, "on atteint la phase d'annonces")

        // Le chaos a coupé : le transport de l'invité sort de `connected`.
        let dropped = await LiveFixtures.waitUntil(timeout: 20) {
            t.guestService.transport.connectionState != .connected
        }
        #expect(dropped, "la coupure chaos doit se voir dans connectionState")

        // …puis il revient : même version que l'hôte.
        let (converged, seconds) = await LiveFixtures.measureWait(timeout: 40) {
            t.guestService.version == t.hostService.version
        }
        #expect(converged, "l'invité rattrape la version de l'hôte après le blip")
        #expect(seconds < 30, "convergence en \(Int(seconds)) s après la coupure")

        // Et il peut encore annoncer : le board se résout.
        let submitted = await LiveFixtures.waitUntil(timeout: 30) {
            t.guestService.room?.gameState?.phase == .announcing
        }
        #expect(submitted, "l'invité retrouve une phase d'annonce jouable")
        let didSubmit = await LiveFixtures.submitIfNeeded(t.guestService, userId: t.guest.userId)
        #expect(didSubmit, "l'annonce part après la reconnexion")

        let resolved = await LiveFixtures.waitUntil(timeout: 45) {
            guard let gs = t.hostService.room?.gameState else { return false }
            return gs.boardResults[0] != nil || gs.currentBoard > 0
        }
        #expect(resolved, "le board se résout avec l'annonce arrivée après la coupure")

        await LiveFixtures.cleanup([t.guestService, t.hostService], tasks: [hostPlay])
    }

    // MARK: - 4 · Mort de l'hôte, relève du bail

    @Test("hostLeaseHandoff : l'invité reprend l'animation, l'ex-hôte revient invité")
    func hostLeaseHandoff() async throws {
        let t = try await Self.openTable()
        let started = await Self.start(t)
        #expect(started)

        let playing = await LiveFixtures.waitUntil(timeout: 25) {
            t.guestService.room?.status == .playing
        }
        #expect(playing)

        let guestPlay = LiveFixtures.autoplay(t.guestService, userId: t.guest.userId)

        // Mort brutale de l'hôte : on ferme son transport SANS `room_leave`.
        // Le bail serveur va expirer tout seul (15 s, plus 5 s de marge).
        await t.hostService.transport.close()

        let promoted = await LiveFixtures.waitUntil(timeout: 45) {
            t.guestService.role == .host
        }
        #expect(promoted, "bail expiré → room_claim_host → l'invité anime")
        #expect(t.guestService.room?.hostUserId == t.guest.userId,
                "et le serveur est d'accord sur l'identité de l'hôte")

        // L'animation repart : la version progresse sous le nouvel hôte.
        let versionAtHandoff = t.guestService.version
        let resumed = await LiveFixtures.waitUntil(timeout: 45) {
            t.guestService.version > versionAtHandoff
        }
        #expect(resumed, "le nouvel hôte reprend le tempo (la partie avance)")

        // L'ex-hôte revient : même compte, même code, mais il est invité.
        let revived = LiveFixtures.makeService(t.host)
        _ = await revived.joinRoom(code: t.code, myUserId: t.host.userId,
                                   myDisplayName: t.host.displayName)
        let demoted = await LiveFixtures.waitUntil(timeout: 30) {
            revived.role == .guest && revived.room != nil
        }
        #expect(demoted, "l'ancien hôte revient en invité, il ne reprend pas la main de force")
        #expect(revived.room?.hostUserId == t.guest.userId)

        await LiveFixtures.cleanup([revived, t.guestService, t.hostService], tasks: [guestPlay])
    }

    // MARK: - 5 · Fusion des annonces (l'hôte n'efface jamais un invité)

    @Test("submitConflictPreserved : l'annonce de l'invité survit aux publications de l'hôte")
    func submitConflictPreserved() async throws {
        let t = try await Self.openTable()
        let started = await Self.start(t)
        #expect(started)

        let announcing = await LiveFixtures.waitUntil(timeout: 60) {
            t.guestService.room?.gameState?.phase == .announcing
                && (t.guestService.room?.gameState?.hands.values.first?.isEmpty == false)
        }
        #expect(announcing, "on atteint la phase d'annonces avec une main côté invité")

        guard let guestSeat = LiveFixtures.seat(of: t.guest.userId, in: t.guestService) else {
            #expect(Bool(false), "l'invité doit avoir un siège")
            await LiveFixtures.cleanup([t.guestService, t.hostService])
            return
        }

        // L'invité soumet PENDANT que l'hôte publie : 3 mutations rapprochées
        // (chacune = room_get → room_publish avec CAS). Le serveur doit
        // ré-injecter la soumission absente du payload de l'hôte.
        let hostWrites = Task { @MainActor in
            for price in [1.5, 2.0, 3.5] {
                await t.hostService.updateSettings(linePrice: price)
            }
        }
        let guestSubmit = Task { @MainActor in
            _ = await LiveFixtures.submitIfNeeded(t.guestService, userId: t.guest.userId)
        }
        await hostWrites.value
        await guestSubmit.value

        let preserved = await LiveFixtures.waitUntil(timeout: 30) {
            guard let gs = t.hostService.room?.gameState else { return false }
            // Soit l'annonce est encore dans `submissions`, soit le board a
            // déjà été résolu grâce à elle — dans les deux cas elle a compté.
            return gs.submissions[guestSeat] != nil || gs.boardResults[0] != nil
        }
        #expect(preserved,
                "une annonce reçue entre la lecture et l'écriture de l'hôte n'est JAMAIS écrasée")
        #expect(t.hostService.room?.linePrice == 3.5,
                "et les publications de l'hôte ont bien abouti")

        await LiveFixtures.cleanup([t.guestService, t.hostService])
    }

    // MARK: - 6 · Quitter est un geste explicite

    @Test("leaveIsExplicit : seul `leave()` retire un joueur, le silence non")
    func leaveIsExplicit() async throws {
        let t = try await Self.openTable()

        let seen = await LiveFixtures.waitUntil(timeout: 25) {
            (t.hostService.room?.participants.count ?? 0) >= 2
        }
        #expect(seen, "l'hôte voit l'invité arriver")

        // (a) Un invité qui ne fait RIEN reste dans le salon : la grâce de
        //     présence ne le jette pas dehors (T23 — plus de mise en
        //     spectateur automatique).
        await LiveFixtures.sleep(10)
        #expect(t.hostService.room?.participants.contains { $0.userId == t.guest.userId } == true,
                "10 s sans geste ne retirent personne")
        let member = t.hostService.members.first { $0.userId == t.guest.userId }
        #expect(member != nil, "l'invité est toujours membre côté serveur")
        #expect(member?.leftAt == nil, "et il n'est pas marqué parti")
        #expect(t.guestService.room != nil, "l'invité, lui, est toujours dans son salon")

        // (b) Le départ explicite, en revanche, se voit tout de suite.
        await t.guestService.leave()
        #expect(t.guestService.phase == .left)
        #expect(t.guestService.room == nil)

        let departed = await LiveFixtures.waitUntil(timeout: 30) {
            let gone = t.hostService.room?.participants.contains { $0.userId == t.guest.userId } != true
            let marked = t.hostService.members.first { $0.userId == t.guest.userId }?.leftAt != nil
            return gone || marked
        }
        #expect(departed, "après `leave()`, l'hôte voit le joueur parti")

        await LiveFixtures.cleanup([t.hostService])
    }
}
