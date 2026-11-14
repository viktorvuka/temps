import SwiftUI

// La page Projets : une liste légère à gauche (organiser, choisir), la fiche du projet choisi à droite
// (ses chiffres, ses missions, et le détail de la période : jours, apps, fichiers, sites, sessions).

struct JourProjet: Decodable, Identifiable {
    let jour: Double
    let secondes: Double
    var id: Double { jour }
}

struct LigneProjet: Decodable, Identifiable {
    let appareil: String
    let app: String
    var contexte: String? = nil
    let secondes: Double
    var id: String { appareil + "|" + app + "|" + (contexte ?? "") }
    var detail: Detail { Detail(appareil: appareil, app: app, contexte: contexte ?? "", secondes: secondes) }
}

struct SousProjet: Decodable, Identifiable {
    let cle: String
    let nom: String
    let secondes: Double
    var id: String { cle }
}

struct DetailProjet: Decodable {
    let cle: String
    let total: Double
    let jours: [JourProjet]
    let apps: [LigneProjet]
    let contextes: [LigneProjet]
    var sous: [SousProjet]? = nil
}

extension Etat {
    func chargerProjet() async {
        guard let cle = projetChoisi,
              let c = cle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))),
              let url = URL(string: "http://127.0.0.1:8230/projet?cle=\(c)&\(requetePeriode)"),
              let (d, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(DetailProjet.self, from: d),
              r.cle == projetChoisi else { return }
        detailProjet = r
    }
}

struct VueProjets: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            EcranOrganiser()
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            FicheProjet()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        }
        .padding(24)
        .onAppear {
            if etat.projetChoisi == nil {
                etat.projetChoisi = etat.categories.first { $0.famille == projets && !$0.archivee }?.cle
            }
        }
    }
}

/// Une section de la fiche : un titre discret, puis son contenu.
struct SectionFiche<Contenu: View>: View {
    let titre: String
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(titre)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            contenu
        }
    }
}

struct FicheProjet: View {
    @EnvironmentObject var etat: Etat

    var body: some View {
        if let cle = etat.projetChoisi, cle.hasPrefix("groupe:") {
            ficheGroupe(String(cle.dropFirst(7)))
        } else if let cle = etat.projetChoisi, let c = etat.categories.first(where: { $0.cle == cle }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    entete(c)
                    if c.famille == projets {
                        chiffres(c)
                        missions(c)
                    }
                    SectionPlages(cles: [c.cle], cleDefaut: c.cle)
                    detail(c)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(cle)
        } else {
            Text("Choisis un projet.").foregroundStyle(.secondary)
        }
    }

    /// La fiche d'un groupe (un domaine) : son temps, la part de chacun de ses projets, puis le même détail.
    func ficheGroupe(_ g: String) -> some View {
        let membre = etat.categories.first { $0.groupe == g || $0.nom == g }
        let teinte = membre.map { couleur($0) } ?? .secondary
        let d = etat.detailProjet?.cle == "groupe:" + g ? etat.detailProjet : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(teinte).frame(width: 11, height: 11)
                            Text(g).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                        }
                        Text(L(membre?.famille ?? projets)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(duree(d?.total ?? 0)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        Text(L("sur la période")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                SectionPlages(cles: Set(etat.categories.filter { $0.nom == g || $0.nom.hasPrefix(g + " / ") }.map(\.cle)),
                              cleDefaut: etat.categories.first { $0.nom == g }?.cle)
                if let d, d.total >= 60 {
                    if let sous = d.sous, !sous.isEmpty {
                        SectionFiche(titre: "Projets") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(sous) { p in
                                    Button { etat.projetChoisi = p.cle } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(p.nom.hasPrefix(g + " / ") ? String(p.nom.dropFirst(g.count + 3)) : p.nom).lineLimit(1)
                                                Spacer()
                                                Text(duree(p.secondes)).monospacedDigit().foregroundStyle(.secondary)
                                            }
                                            GeometryReader { geo in
                                                Capsule().fill(teinte.opacity(0.75))
                                                    .frame(width: max(3, geo.size.width * CGFloat(p.secondes / max(sous[0].secondes, 1))))
                                            }
                                            .frame(height: 4)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                }
                            }
                        }
                    }
                    SectionFiche(titre: "Jours") { BarresJours(jours: d.jours, couleur: teinte) }
                    SectionFiche(titre: "Apps") { Barres(lignes: d.apps, max: d.apps.first?.secondes ?? 1, couleur: teinte, contexte: false) }
                    if !d.contextes.isEmpty {
                        SectionFiche(titre: "Fichiers, sites et sessions") {
                            Barres(lignes: d.contextes, max: d.contextes.first?.secondes ?? 1, couleur: teinte, contexte: true)
                        }
                    }
                } else if d != nil {
                    Text("Rien sur cette période.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id("groupe:" + g)
    }

    func couleur(_ c: Categorie) -> Color {
        c.famille == projets ? couleurSerie(serie(cle: c.cle, nom: c.nom, famille: c.famille)) : .secondary
    }

    // MARK: En-tête

    func entete(_ c: Categorie) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(couleur(c)).frame(width: 11, height: 11)
                    Text(c.feuille).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                }
                Text([c.groupe, L(c.famille)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(duree(etat.detailProjet?.cle == c.cle ? etat.detailProjet!.total : 0))
                    .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text(L("sur la période")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Chiffres du devis

    func fiche(_ c: Categorie) -> Fiche {
        etat.fiches.first { $0.cle == c.cle }
            ?? Fiche(cle: c.cle, nom: c.nom, famille: c.famille, total: 0, mois: 0, premier: nil, vendu: nil, montant: nil, facturable: true, taux: nil)
    }

    func chiffres(_ c: Categorie) -> some View {
        let f = fiche(c)
        let repere = etat.reperesTous.first { $0.nom == c.nom }.flatMap { ($0.objectif ?? $0.plafond).map { $0 / 3600 } }
        return SectionFiche(titre: "Devis") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Heures vendues").foregroundStyle(.secondary)
                    ChampNombre(valeur: f.vendu, suffixe: "h", cadre: true) { v in
                        Task { await etat.majFiche(f, vendu: v, montant: f.montant, facturable: f.facturable) }
                    }.frame(width: 110)
                    Text("Total passé").foregroundStyle(.secondary)
                    Text(heures(f.total)).monospacedDigit()
                }
                GridRow {
                    Text("Montant HT").foregroundStyle(.secondary)
                    ChampNombre(valeur: f.montant, suffixe: Locale.current.currencySymbol ?? "€", cadre: true) { v in
                        Task { await etat.majFiche(f, vendu: f.vendu, montant: v, facturable: f.facturable) }
                    }.frame(width: 110)
                    Text("Bilan").foregroundStyle(.secondary)
                    bilan(f)
                }
                GridRow {
                    Text("Repère par semaine").foregroundStyle(.secondary)
                    ChampNombre(valeur: repere, suffixe: "h", cadre: true) { v in
                        Task { await etat.majRepere(c.nom, valeur: v, plafond: false) }
                    }.frame(width: 110)
                    Text("Facturable").foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(get: { f.facturable }, set: { b in
                        Task { await etat.majFiche(f, vendu: f.vendu, montant: f.montant, facturable: b) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder func bilan(_ f: Fiche) -> some View {
        if let v = f.vendu {
            let ecart = f.total / 3600 - v
            Text(ecart > 0 ? L("%@ de dépassement", heures(ecart * 3600)) : L("%@ de marge", heures(-ecart * 3600)))
                .foregroundStyle(ecart > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        } else if let t = f.taux {
            Text("\(euros(t)) / h")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    // MARK: Missions

    /// Une mission peut démarrer à une date : dès ce jour, le temps de son projet va à elle.
    @ViewBuilder func missions(_ c: Categorie) -> some View {
        if etat.projetDeMission(c) != nil {
            let debut = etat.debutMission(c)
            SectionFiche(titre: "Départ") {
                HStack(spacing: 12) {
                    if let debut {
                        DatePicker("", selection: Binding(get: { debut }, set: { d in Task { await etat.dater(c, d) } }),
                                   displayedComponents: .date).labelsHidden().fixedSize()
                        Button(L("Retirer la date")) { Task { await etat.dater(c, nil) } }
                            .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    } else {
                        Button { Task { await etat.dater(c, Date()) } } label: {
                            Label(L("Date de départ"), systemImage: "plus").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: Détail de la période

    @ViewBuilder func detail(_ c: Categorie) -> some View {
        if let d = etat.detailProjet, d.cle == c.cle {
            if d.total < 60 {
                Text("Rien sur cette période.").foregroundStyle(.secondary)
            } else {
                SectionFiche(titre: "Jours") { BarresJours(jours: d.jours, couleur: couleur(c)) }
                SectionFiche(titre: "Apps") { Barres(lignes: d.apps, max: d.apps.first?.secondes ?? 1, couleur: couleur(c), contexte: false) }
                if !d.contextes.isEmpty {
                    SectionFiche(titre: "Fichiers, sites et sessions") {
                        Barres(lignes: d.contextes, max: d.contextes.first?.secondes ?? 1, couleur: couleur(c), contexte: true)
                    }
                }
            }
        }
    }
}

struct BarresJours: View {
    let jours: [JourProjet]
    let couleur: Color
    var paquets: [(Double, Double)] {
        guard jours.count > 62 else { return jours.map { ($0.jour, $0.secondes) } }
        return stride(from: 0, to: jours.count, by: 7).map { i in
            (jours[i].jour, jours[i..<min(i + 7, jours.count)].reduce(0) { $0 + $1.secondes })
        }
    }
    var body: some View {
        let p = paquets
        let max = Swift.max(p.map(\.1).max() ?? 0, 1)
        let f = Date.FormatStyle().day().month(.abbreviated)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: p.count > 40 ? 1 : 3) {
                ForEach(Array(p.enumerated()), id: \.offset) { _, x in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.05))
                        RoundedRectangle(cornerRadius: 2).fill(couleur).frame(height: CGFloat(x.1 / max) * 70)
                    }
                    .frame(height: 70).frame(maxWidth: .infinity)
                    .help("\(Date(timeIntervalSince1970: x.0).formatted(f)) · \(duree(x.1))")
                }
            }
            HStack {
                if let a = p.first { Text(Date(timeIntervalSince1970: a.0).formatted(f)) }
                Spacer()
                if let b = p.last { Text(Date(timeIntervalSince1970: b.0).formatted(f)) }
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// Des lignes avec l'icône de l'app, le nom (ou le fichier, le site, la session), une barre et la durée.
/// Un fichier, un site ou une session se déplace vers un autre projet depuis ici (règle forcée, prioritaire sur le dossier).
struct Barres: View {
    let lignes: [LigneProjet]
    let max: Double
    let couleur: Color
    let contexte: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lignes) { l in LigneBarre(l: l, max: max, couleur: couleur, contexte: contexte) }
        }
    }
}

struct LigneBarre: View {
    @EnvironmentObject var etat: Etat
    let l: LigneProjet
    let max: Double
    let couleur: Color
    let contexte: Bool
    @State private var survol = false
    @State private var choix = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icone = Apps.partage.icone(l.app) {
                    Image(nsImage: icone).resizable()
                } else {
                    Image(systemName: iconeAppareil(l.appareil)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(contexte ? (l.contexte ?? "") : l.detail.nomApp).lineLimit(1)
                    Spacer()
                    if contexte && (survol || choix) {
                        Button { choix = true } label: {
                            Label(L("Déplacer"), systemImage: "arrow.turn.up.right").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .popover(isPresented: $choix, arrowEdge: .bottom) {
                            ChoixCategorie { cle in
                                choix = false
                                Task { await etat.deplacer(l.detail, vers: cle) }
                            }
                            .environmentObject(etat)
                        }
                    }
                    Text(duree(l.secondes)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(couleur.opacity(0.75)).frame(width: Swift.max(3, g.size.width * CGFloat(l.secondes / max)))
                }
                .frame(height: 4)
            }
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
    }
}

extension Etat {
    /// Déplace un fichier, un site ou une session vers un autre projet : une règle forcée, qui passe avant le dossier.
    func deplacer(_ d: Detail, vers cle: String) async {
        let motif = d.portees.first(where: { $0.section == "titres" })?.motif ?? d.contexte
        guard !motif.isEmpty else { return }
        let nom = categories.first { $0.cle == cle }?.nom ?? cle
        await poser("forcer", motif, cle, message: L("« %@ » déplacé vers %@", motif, nom))
    }
}

// MARK: - Domaines › Projets › Missions

/// La famille « Projets » (le nom `projets` est pris par la liste de projets d'un domaine).
let familleProjets = projets

/// Un domaine (Studio, Enseignement, Perso…) : sa nature (projets, activités, hors travail) et ses projets.
struct Domaine: Codable, Identifiable, Hashable {
    var nom: String
    var nature: String
    var projets: [String]
    var id: String { nom }
    var famille: String { nature == "activites" ? activites : nature == "hors_travail" ? horsTravail : familleProjets }
}

struct NoeudProjet: Identifiable {
    /// Le nom affiché du projet, et le début de nom de toutes ses catégories (« Studio / Logo »).
    let nom: String
    let prefixe: String
    var cats: [Categorie]
    var id: String { prefixe }
    /// Un projet sans mission est une seule catégorie.
    var seul: Categorie? { cats.count == 1 && cats[0].nom == prefixe ? cats[0] : nil }
}

struct NoeudDomaine: Identifiable {
    let domaine: Domaine
    var projets: [NoeudProjet]
    var id: String { domaine.nom }
    /// Le domaine porte le nom d'un ancien groupe : ses projets sont les sous-catégories de ce groupe.
    var estGroupe: Bool { domaine.projets.contains(domaine.nom) }
}

extension Etat {
    static func natureDe(_ famille: String) -> String {
        famille == activites ? "activites" : famille == horsTravail ? "hors_travail" : "projets"
    }

    /// L'arbre de la page Projets. Une catégorie va dans le domaine qui liste son premier segment, sinon dans
    /// le premier domaine de même nature que sa famille. Dans un domaine qui porte le nom de ce premier segment,
    /// le projet est le deuxième segment (« Studio / Logo » : projet Logo) ; ailleurs, c'est le premier.
    /// Les domaines qui ont du temps parmi ces postes, dans leur ordre.
    func domainesAvec(_ postes: [Poste], famille: String) -> [String] {
        let pris = Set(postes.filter { $0.cle != "autres" }.map { placer($0.nom, famille: famille).domaine })
        return domaines.map(\.nom).filter { pris.contains($0) }
    }

    /// Où va un nom de catégorie : son domaine, et son projet (nom affiché, préfixe commun à ses missions).
    func placer(_ nomCategorie: String, famille: String) -> (domaine: String, nom: String, prefixe: String) {
        let segs = nomCategorie.components(separatedBy: " / ")
        let d = domaines.first { $0.projets.contains(segs[0]) }?.nom
            ?? domaines.first { $0.nature == Etat.natureDe(famille) }?.nom ?? domaines.first?.nom ?? ""
        return segs[0] == d && segs.count > 1 ? (d, segs[1], segs[0] + " / " + segs[1]) : (d, segs[0], segs[0])
    }

    var arbre: [NoeudDomaine] {
        var range: [String: [String: (nom: String, cats: [Categorie])]] = [:]
        for c in categories where !c.archivee {
            let (d, nom, prefixe) = placer(c.nom, famille: c.famille)
            range[d, default: [:]][prefixe, default: (nom, [])].cats.append(c)
        }
        return domaines.map { d in
            NoeudDomaine(domaine: d, projets: (range[d.nom] ?? [:]).map { NoeudProjet(nom: $0.value.nom, prefixe: $0.key, cats: $0.value.cats.sorted { $0.nom.lowercased() < $1.nom.lowercased() }) }
                .sorted { ($0.prefixe == d.nom ? 0 : 1, $0.nom.lowercased()) < ($1.prefixe == d.nom ? 0 : 1, $1.nom.lowercased()) })
        }
    }

    /// Les domaines à écrire : chacun liste les premiers segments qu'il contient, pour figer ce qui est affiché.
    var domainesComplets: [Domaine] {
        arbre.map { n in
            var premiers: [String] = []
            for p in n.projets { let x = p.prefixe.components(separatedBy: " / ")[0]; if !premiers.contains(x) { premiers.append(x) } }
            return Domaine(nom: n.domaine.nom, nature: n.domaine.nature, projets: premiers)
        }
    }

    /// Déplace une branche (« Studio / Logo » et ses missions) sous un autre domaine-groupe, d'un seul geste.
    func deplacerBranche(_ prefixe: String, vers domaine: String) async {
        let feuille = prefixe.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        let base = feuille.isEmpty ? prefixe : feuille
        let liste: [[String: Any]] = categories.filter { $0.nom == prefixe || $0.nom.hasPrefix(prefixe + " / ") }.map {
            ["section": "noms", "motif": $0.cle, "valeur": domaine + " / " + base + String($0.nom.dropFirst(prefixe.count))]
        }
        guard !liste.isEmpty else { return }
        await modifier("lot", ["regles": liste], message: L("%@ rangé dans %@", base, domaine)) { r in ("restaurer", ["texte": r.avant ?? ""]) }
    }

    /// Renomme un projet et ses missions : « Studio / Logo / … » devient « Studio / Nouveau / … ».
    func renommerBranche(_ prefixe: String, en nom: String) async {
        var segs = prefixe.components(separatedBy: " / ")
        segs[segs.count - 1] = nom
        let nouveau = segs.joined(separator: " / ")
        let liste: [[String: Any]] = categories.filter { $0.nom == prefixe || $0.nom.hasPrefix(prefixe + " / ") }.map {
            ["section": "noms", "motif": $0.cle, "valeur": nouveau + String($0.nom.dropFirst(prefixe.count))]
        }
        guard !liste.isEmpty else { return }
        await modifier("lot", ["regles": liste], message: L("Renommé en %@", nom)) { r in ("restaurer", ["texte": r.avant ?? ""]) }
    }

    func ecrireDomaines(_ l: [Domaine], message: String) async {
        let corps: [[String: Any]] = l.map { ["nom": $0.nom, "nature": $0.nature, "projets": $0.projets] }
        await modifier("domaines", ["domaines": corps], message: message) { r in ("restaurer", ["texte": r.avant ?? ""]) }
    }

    func creerDomaine(_ nom: String) async {
        let n = nom.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !domaines.contains(where: { $0.nom == n }) else { return }
        await ecrireDomaines(domainesComplets + [Domaine(nom: n, nature: "projets", projets: [])], message: L("Domaine « %@ » créé", n))
    }

    func renommerDomaine(_ ancien: String, en nouveau: String) async {
        let n = nouveau.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != ancien, !domaines.contains(where: { $0.nom == n }) else { return }
        await ecrireDomaines(domainesComplets.map { var d = $0; if d.nom == ancien { d.nom = n }; return d },
                             message: L("Domaine renommé en %@", n))
    }

    func natureDomaine(_ nom: String, _ nature: String) async {
        await ecrireDomaines(domainesComplets.map { var d = $0; if d.nom == nom { d.nature = nature }; return d },
                             message: L("%@ : %@", nom, L(Domaine(nom: "", nature: nature, projets: []).famille)))
    }

    func deplacerDomaine(_ nom: String, _ sens: Int) async {
        var l = domainesComplets
        guard let i = l.firstIndex(where: { $0.nom == nom }), l.indices.contains(i + sens) else { return }
        l.swapAt(i, i + sens)
        await ecrireDomaines(l, message: L("Domaines réordonnés"))
    }

    /// Supprimer un domaine ne supprime pas ses projets : ils retournent dans le premier domaine de même nature.
    func supprimerDomaine(_ nom: String) async {
        guard domaines.count > 1 else { return }
        await ecrireDomaines(domainesComplets.filter { $0.nom != nom }, message: L("Domaine « %@ » supprimé", nom))
    }

    func rangerProjet(_ projet: String, dans domaine: String) async {
        let l = domainesComplets.map { d -> Domaine in
            var d = d
            d.projets.removeAll { $0 == projet }
            if d.nom == domaine { d.projets.append(projet) }
            return d
        }
        await ecrireDomaines(l, message: L("%@ rangé dans %@", projet, domaine))
    }

    /// Nouveau projet dans un domaine : la catégorie, puis sa place dans le domaine.
    func creerProjet(_ nom: String, dans d: Domaine) async {
        let n = nom.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if d.projets.contains(d.nom) {
            await creer("\(d.nom) / \(n)", famille: d.famille)
            return
        }
        var l = domainesComplets
        await creer(n, famille: d.famille)
        if let i = l.firstIndex(where: { $0.nom == d.nom }) {
            l[i].projets.append(n.components(separatedBy: " / ")[0])
            await ecrireDomaines(l, message: L("%@ créé", n))
        }
    }
}


/// Le temps de travail rangé Domaine › Projet › Mission, pour la Vue d'ensemble et le panneau.
/// Chaque domaine et chaque projet à missions se replie d'un clic ; l'état est gardé d'une ouverture à l'autre.
struct ListeDomaines: View {
    @EnvironmentObject var etat: Etat
    let postes: [Poste]
    let max: Double
    var famille = "Projets"
    /// Un seul domaine (une carte par domaine dans la Vue d'ensemble), ou tous.
    var domaine: String? = nil
    @AppStorage("temps.ensembleReplies") private var repliesTexte = ""

    struct Proj: Identifiable { let nom: String; let prefixe: String; var postes: [Poste]; var id: String { prefixe }
        var total: Double { postes.reduce(0) { $0 + $1.secondes } } }
    struct Dom: Identifiable { let nom: String; var projets: [Proj]; var id: String { nom }
        var total: Double { projets.reduce(0) { $0 + $1.total } } }

    var replies: Set<String> { Set(repliesTexte.split(separator: "\n").map(String.init)) }
    func basculer(_ k: String) {
        var r = replies
        if r.contains(k) { r.remove(k) } else { r.insert(k) }
        withAnimation(.easeOut(duration: 0.15)) { repliesTexte = r.sorted().joined(separator: "\n") }
    }

    var arbre: [Dom] {
        var range: [String: [String: Proj]] = [:]
        for p in postes {
            if p.cle == "autres" { continue }
            let (d, nom, prefixe) = etat.placer(p.nom, famille: famille)
            range[d, default: [:]][prefixe, default: Proj(nom: nom, prefixe: prefixe, postes: [])].postes.append(p)
        }
        return etat.domaines.compactMap { d in
            guard let l = range[d.nom], domaine == nil || domaine == d.nom else { return nil }
            return Dom(nom: d.nom, projets: l.values.sorted { $0.total > $1.total })
        }
    }

    func couleur(_ cle: String, _ nom: String) -> Color { couleurSerie(serie(cle: cle, nom: nom, famille: famille)) }

    func chevron(_ ouvert: Bool) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(ouvert ? 90 : 0)).frame(width: 10)
    }

    var body: some View {
        let r = replies
        let autres = postes.first { $0.cle == "autres" }
        ForEach(arbre) { d in
            let ouvert = !r.contains("d:" + d.nom)
            HStack(spacing: 5) {
                chevron(ouvert)
                Circle().fill(couleur(d.nom, d.nom)).frame(width: 7, height: 7)
                Text(d.nom).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(duree(d.total)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { basculer("d:" + d.nom) }
            if ouvert {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(d.projets) { p in
                        if p.postes.count == 1 && p.postes[0].nom == p.prefixe || p.postes.count == 1 && p.postes[0].nom == d.nom + " / " + p.nom {
                            LignePoste(poste: p.postes[0], max: max, discret: true, affiche: p.nom, pastille: couleur(p.postes[0].cle, p.postes[0].nom))
                                .padding(.leading, 15)
                        } else {
                            let po = !r.contains("p:" + p.prefixe)
                            HStack(spacing: 5) {
                                chevron(po)
                                Circle().fill(couleur(p.prefixe, p.prefixe)).frame(width: 7, height: 7)
                                Text(p.nom).font(.system(size: 13))
                                Spacer()
                                Text(duree(p.total)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture { basculer("p:" + p.prefixe) }
                            if po {
                                ForEach(p.postes.sorted { $0.secondes > $1.secondes }) { m in
                                    let feuille = m.nom == p.prefixe ? L("Sans mission") : (m.nom.components(separatedBy: " / ").last ?? m.nom)
                                    LignePoste(poste: m, max: max, discret: true, affiche: feuille)
                                        .padding(.leading, 30)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 10)
            }
        }
        if let a = autres { LignePoste(poste: a, max: max, discret: true) }
    }
}


// MARK: - Plages saisies à la main

struct PlageSaisie: Decodable, Identifiable, Hashable {
    let id: String
    let debut: Double
    let fin: Double
    let cle: String
    let note: String
    let nom: String?
}

extension Etat {
    func chargerSaisies() async {
        guard let url = URL(string: "http://127.0.0.1:8230/manuel"),
              let (d, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode([String: [PlageSaisie]].self, from: d) else { return }
        plagesSaisies = r["plages"] ?? []
    }

    func ajouterPlage(debut: Date, fin: Date, cle: String, note: String) async {
        let nom = categories.first { $0.cle == cle }?.nom ?? cle
        await modifier("manuel", ["debut": debut.timeIntervalSince1970, "fin": fin.timeIntervalSince1970, "cle": cle, "note": note],
                       message: L("Plage ajoutée à %@", nom)) { r in ("manuel/retirer", ["id": r.avant as? String ?? ""]) }
        await chargerSaisies()
    }

    func retirerPlage(_ p: PlageSaisie) async {
        await modifier("manuel/retirer", ["id": p.id], message: L("Plage retirée")) { _ in
            ("manuel", ["debut": p.debut, "fin": p.fin, "cle": p.cle, "note": p.note])
        }
        await chargerSaisies()
    }
}

/// Saisir une plage : le jour, l'heure de début et de fin, une note ; le projet aussi quand on ne vient pas de sa fiche.
struct FormulairePlage: View {
    @EnvironmentObject var etat: Etat
    var cle: String? = nil
    let fini: () -> Void
    @State private var choisi: String?
    @State private var jour = Date()
    @State private var debut = Date()
    @State private var fin = Date()
    @State private var note = ""
    @State private var recherche = ""

    var trouves: [Categorie] {
        let t = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        return etat.categories.filter { !$0.archivee && $0.famille == projets && (t.isEmpty || $0.nom.lowercased().contains(t)) }
    }

    init(cle: String? = nil, fini: @escaping () -> Void) {
        self.cle = cle
        self.fini = fini
        let maintenant = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.down) * 300)
        _fin = State(initialValue: maintenant)
        _debut = State(initialValue: maintenant.addingTimeInterval(-3600))
    }

    /// L'heure choisie, posée sur le jour choisi.
    func sur(_ h: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: h)
        return cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: jour) ?? h
    }

    var body: some View {
        let projet = cle ?? choisi
        let a = sur(debut), b = sur(fin)
        VStack(alignment: .leading, spacing: 12) {
            if cle == nil {
                if let p = projet {
                    HStack {
                        Text(etat.categories.first { $0.cle == p }?.nom ?? p).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(L("Changer")) { choisi = nil }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                } else {
                    TextField(L("Chercher un projet"), text: $recherche).textFieldStyle(.roundedBorder)
                        .onSubmit { choisi = trouves.first?.cle }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(trouves) { c in LigneChoix(texte: c.nom) { choisi = c.cle } }
                        }
                    }
                    .frame(height: 170)
                    .clipped()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Jour").foregroundStyle(.secondary)
                    DatePicker("", selection: $jour, in: ...Date(), displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("De").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        DatePicker("", selection: $debut, displayedComponents: .hourAndMinute).labelsHidden()
                        Text("à").foregroundStyle(.secondary)
                        DatePicker("", selection: $fin, displayedComponents: .hourAndMinute).labelsHidden()
                        Text(b > a ? duree(b.timeIntervalSince(a)) : "").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Note").foregroundStyle(.secondary)
                    TextField(L("Réunion, rendez-vous, croquis…"), text: $note).textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button(L("Annuler"), action: fini).keyboardShortcut(.cancelAction)
                Button(L("Ajouter")) {
                    guard let p = projet else { return }
                    fini()
                    Task { await etat.ajouterPlage(debut: a, fin: b, cle: p, note: note) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projet == nil || b <= a)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Les plages saisies d'un projet (ou d'un groupe), les plus récentes d'abord ; « + Plage » pour en ajouter.
struct SectionPlages: View {
    @EnvironmentObject var etat: Etat
    let cles: Set<String>
    let cleDefaut: String?
    @State private var ouvert = false

    var body: some View {
        let liste = etat.plagesSaisies.filter { cles.contains($0.cle) }
        SectionFiche(titre: "Plages saisies") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(liste.prefix(12)) { p in
                    AvecSurvol { survol in
                        HStack(spacing: 10) {
                            Text(Date(timeIntervalSince1970: p.debut).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .frame(width: 96, alignment: .leading)
                            Text("\(heureMinute(p.debut))–\(heureMinute(p.fin))").monospacedDigit().foregroundStyle(.secondary)
                            Text(p.note.isEmpty ? (cles.count > 1 ? (p.nom ?? p.cle) : "") : p.note).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            if survol {
                                Button { Task { await etat.retirerPlage(p) } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).help(L("Retirer la plage"))
                            }
                            Text(duree(p.fin - p.debut)).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 2)
                    }
                }
                Button { ouvert = true } label: {
                    Label(L("Nouvelle plage"), systemImage: "plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .padding(.top, liste.isEmpty ? 0 : 4)
                .popover(isPresented: $ouvert, arrowEdge: .bottom) {
                    FormulairePlage(cle: cleDefaut) { ouvert = false }.environmentObject(etat)
                }
            }
        }
        .task { if etat.plagesSaisies.isEmpty { await etat.chargerSaisies() } }
    }
}
