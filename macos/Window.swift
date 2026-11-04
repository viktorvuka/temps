import SwiftUI
import UniformTypeIdentifiers

// La vraie fenêtre de Temps : vue d'ensemble sur une période longue, projets et leurs fiches,
// temps par app, bilan face au devis, export CSV par mois.

// MARK: - Données

struct AppTemps: Decodable, Identifiable {
    let appareil: String
    let app: String
    let secondes: Double
    let surtout: String
    var id: String { appareil + "|" + app }

    var nom: String { Detail(appareil: appareil, app: app, contexte: "", secondes: 0).nomApp }
    var icone: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct Fiche: Decodable, Identifiable {
    let cle: String
    let nom: String
    let famille: String
    let total: Double
    let mois: Double
    let premier: Double?
    let vendu: Double?
    let montant: Double?
    let facturable: Bool
    let taux: Double?
    var id: String { cle }
    var aBilan: Bool { vendu != nil || montant != nil }
}

struct ReponseFenetre: Decodable {
    let depuis: Double?
    let apps: [AppTemps]?
    let projets: [Fiche]?
    let reperes: [Repere]?
    let mois: [String]?
    let histogramme: [Jour]?
    let facturable: Double?
    let erreur: String?
}

enum Rubrique: String, CaseIterable, Identifiable {
    case ensemble = "Vue d'ensemble", apps = "Apps", projets = "Projets", bilan = "Bilan", organiser = "Organiser", export = "Export"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .ensemble: "chart.bar"
        case .projets: "folder"
        case .organiser: "square.stack.3d.up"
        case .apps: "square.grid.2x2"
        case .bilan: "scalemass"
        case .export: "square.and.arrow.up"
        }
    }
}

func heures(_ s: Double) -> String {
    let h = s / 3600
    let f = NumberFormatter()
    f.maximumFractionDigits = h >= 10 ? 0 : 1
    f.minimumFractionDigits = h >= 10 ? 0 : 1
    return (f.string(from: NSNumber(value: h)) ?? "\(h)") + " h"
}

/// Un montant dans la devise de la région du Mac.
func euros(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency  // devise de la région du Mac (€, $, £…)
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(Int(v)) €"
}

func nomMois(_ m: String) -> String {
    let p = DateFormatter()
    p.dateFormat = "yyyy-MM"
    guard let d = p.date(from: m) else { return m }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
    let s = f.string(from: d)
    return s.prefix(1).uppercased() + s.dropFirst()
}

// MARK: - État de la fenêtre

extension Etat {
    func chargerFenetre() async {
        do {
            let url = URL(string: "http://127.0.0.1:8230/fenetre?jours=\(periodeFenetre)")!
            let (d, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(ReponseFenetre.self, from: d)
            erreurFenetre = r.erreur
            apps = r.apps ?? []
            fiches = r.projets ?? []
            reperesTous = r.reperes ?? []
            moisDispos = r.mois ?? []
            histoLong = r.histogramme ?? []
            facturableFenetre = r.facturable ?? 0
            let a = try await lire(periodeFenetre)
            famillesFenetre = a.familles ?? []
            travailFenetre = a.travail ?? 0
        } catch {
            erreurFenetre = L("Serveur injoignable sur le port 8230.")
        }
    }

    /// Fiche vide : on la retire. Sinon on la pose en entier (vendu, montant, facturable).
    func majFiche(_ f: Fiche, vendu: Double?, montant: Double?, facturable: Bool) async {
        var t: [String: Any] = ["facturable": facturable]
        if let v = vendu { t["vendu"] = v }
        if let m = montant { t["montant"] = m }
        await poser("projets", f.cle, t, message: L("Fiche de %@ mise à jour", f.nom))
    }

    /// Heures visées (ou plafond pour le hors travail) par semaine ; vide = pas de repère.
    func majRepere(_ nom: String, valeur: Double?, plafond: Bool) async {
        let ancien = reperesTous.first { $0.nom == nom }
        if let v = valeur {
            await poser("reperes", nom, [plafond ? "plafond" : "heures": v], message: L("Repère de %@ : %@", nom, heures(v * 3600)))
        } else if let a = ancien {
            let avant: [String: Any] = a.plafond.map { ["plafond": $0 / 3600] } ?? ["heures": (a.objectif ?? 0) / 3600]
            await retirer("reperes", nom, ancien: avant, message: L("Repère de %@ retiré", nom))
        }
    }

    func exporter(_ mois: String) async {
        guard let url = URL(string: "http://127.0.0.1:8230/export?mois=\(mois)"),
              let (d, _) = try? await URLSession.shared.data(from: url) else {
            erreurFenetre = L("Export impossible : serveur injoignable sur le port 8230.")
            return
        }
        let panneau = NSSavePanel()
        panneau.nameFieldStringValue = "Temps-\(mois).csv"
        panneau.allowedContentTypes = [.commaSeparatedText]
        guard panneau.runModal() == .OK, let cible = panneau.url else { return }
        do {
            try d.write(to: cible)
            NSWorkspace.shared.activateFileViewerSelecting([cible])
        } catch {
            erreurFenetre = L("Export non écrit : %@", error.localizedDescription)
        }
    }
}

// MARK: - Champs

/// Un nombre modifiable ; Entrée ou sortie du champ valide, vide = aucun.
struct ChampNombre: View {
    let valeur: Double?
    var suffixe = ""
    let valider: (Double?) -> Void
    @State private var texte = ""
    @FocusState private var focus: Bool

    func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)).replacingOccurrences(of: ".", with: ",")
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField("—", text: $texte)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focus)
                .onSubmit { envoyer() }
                .onChange(of: focus) { _, f in if !f { envoyer() } }
            if !suffixe.isEmpty { Text(suffixe).foregroundStyle(.tertiary) }
        }
        .onAppear { texte = format(valeur) }
        .onChange(of: valeur) { _, v in if !focus { texte = format(v) } }
    }

    func envoyer() {
        let t = texte.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        let v = Double(t)
        guard t.isEmpty || v != nil else { texte = format(valeur); return }
        if v != valeur { valider(v) }
    }
}

// MARK: - Vues

struct HistogrammeLong: View {
    let jours: [Jour]
    var body: some View {
        let max = Swift.max(jours.map(\.travail).max() ?? 0, 3600)
        let f: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM"); return f }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: jours.count > 40 ? 1 : 3) {
                ForEach(jours) { j in
                    let date = Date(timeIntervalSince1970: j.jour)
                    let weekend = [1, 7].contains(Calendar.current.component(.weekday, from: date))
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(weekend ? 0.06 : 0.025))
                        BarreEmpilee(parts: j.parts ?? [:], hauteur: 90, max: max)
                    }
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .help(detailParts(j))
                }
            }
            .frame(height: 90, alignment: .bottom)
            HStack {
                if let a = jours.first { Text(f.string(from: Date(timeIntervalSince1970: a.jour))) }
                Spacer()
                if let b = jours.last { Text(f.string(from: Date(timeIntervalSince1970: b.jour))) }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            // Légende : seulement les séries présentes sur la période
            let presentes = ordreSeries.filter { s in jours.contains { ($0.parts?[s] ?? 0) > 0 } }
            HStack(spacing: 14) {
                ForEach(presentes, id: \.self) { s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(couleurSerie(s)).frame(width: 9, height: 9)
                        Text(L(libelleSerie(s)))
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }
}

struct VueEnsemble: View {
    @EnvironmentObject var etat: Etat

    func famille(_ n: String) -> Famille? { etat.famillesFenetre.first { $0.nom == n } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(duree(etat.travailFenetre)).font(.system(size: 34, weight: .semibold)).tracking(-0.6).monospacedDigit()
                        Text(L("de travail sur %d jours, soit %@ par jour, dont %@ facturables", etat.periodeFenetre + 1,
                               duree(etat.travailFenetre / Double(etat.periodeFenetre + 1)), duree(etat.facturableFenetre)))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $etat.periodeFenetre) {
                        Text("7 jours").tag(6)
                        Text("30 jours").tag(29)
                        Text("90 jours").tag(89)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HistogrammeLong(jours: etat.histoLong)
                if !etat.reperesTous.isEmpty {
                    Carte {
                        Etiquette(texte: "Cette semaine")
                        ForEach(etat.reperesTous) { LigneRepere(r: $0) }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Carte {
                        if let p = famille(projets) {
                            Etiquette(texte: projets, compte: p.postes.count, droite: duree(p.secondes))
                            ListeGroupee(postes: p.postes, max: p.postes.first?.secondes ?? 1)
                        }
                        if let n = famille(nonClasse), let poste = n.postes.first {
                            LignePoste(poste: poste, max: famille(projets)?.postes.first?.secondes ?? poste.secondes, teinte: .orange)
                        }
                    }
                    VStack(spacing: 16) {
                        if let a = famille(activites) {
                            Carte {
                                Etiquette(texte: activites, compte: a.postes.count, droite: duree(a.secondes))
                                ListeGroupee(postes: a.postes, max: a.postes.first?.secondes ?? 1, discret: true, famille: activites)
                            }
                        }
                        if let h = famille(horsTravail) {
                            Carte {
                                Etiquette(texte: horsTravail, compte: h.postes.count, droite: duree(h.secondes))
                                ListeGroupee(postes: h.postes, max: h.postes.first?.secondes ?? 1, discret: true, famille: horsTravail)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct VueProjets: View {
    @EnvironmentObject var etat: Etat

    var lignes: [Fiche] { etat.fiches.filter { $0.famille == projets } }

    func repere(_ f: Fiche) -> Double? {
        etat.reperesTous.first { $0.nom == f.nom }.flatMap { ($0.objectif ?? $0.plafond).map { $0 / 3600 } }
    }

    var body: some View {
        Table(lignes) {
            TableColumn("Projet") { f in
                NomModifiable(cle: f.cle, nom: f.nom, actif: true)
            }
            .width(min: 160, ideal: 200)
            TableColumn("Ce mois") { f in Text(heures(f.mois)).monospacedDigit().foregroundStyle(.secondary) }
                .width(56)
            TableColumn("Total") { f in Text(heures(f.total)).monospacedDigit() }
                .width(56)
            TableColumn("Vendues") { f in
                ChampNombre(valeur: f.vendu, suffixe: "h") { v in
                    Task { await etat.majFiche(f, vendu: v, montant: f.montant, facturable: f.facturable) }
                }
            }
            .width(58)
            TableColumn("Montant HT") { f in
                ChampNombre(valeur: f.montant, suffixe: Locale.current.currencySymbol ?? "€") { v in
                    Task { await etat.majFiche(f, vendu: f.vendu, montant: v, facturable: f.facturable) }
                }
            }
            .width(78)
            TableColumn("Bilan") { f in
                if let v = f.vendu {
                    let ecart = f.total / 3600 - v
                    Text(ecart > 0 ? "+\(heures(ecart * 3600))" : "−\(heures(-ecart * 3600))")
                        .monospacedDigit().foregroundStyle(ecart > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .help(ecart > 0 ? L("Dépassement sur les heures vendues") : L("Heures restantes sur les heures vendues"))
                } else if let t = f.taux {
                    Text("\(euros(t)) / h").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(70)
            TableColumn("Facturable") { f in
                Toggle("", isOn: Binding(get: { f.facturable }, set: { b in
                    Task { await etat.majFiche(f, vendu: f.vendu, montant: f.montant, facturable: b) }
                }))
                .labelsHidden().toggleStyle(.checkbox)
            }
            .width(62)
            TableColumn("Repère / sem.") { f in
                ChampNombre(valeur: repere(f), suffixe: "h") { v in
                    Task { await etat.majRepere(f.nom, valeur: v, plafond: false) }
                }
            }
            .width(90)
        }
    }
}

struct VueApps: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        Table(etat.apps) {
            TableColumn("App") { a in
                HStack(spacing: 8) {
                    if let i = a.icone { Image(nsImage: i).resizable().frame(width: 18, height: 18) }
                    else { Image(systemName: "app").frame(width: 18, height: 18).foregroundStyle(.tertiary) }
                    Text(a.nom)
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Appareil") { a in
                Label(a.appareil, systemImage: iconeAppareil(a.appareil)).foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Temps") { a in Text(duree(a.secondes)).monospacedDigit() }
                .width(80)
            TableColumn("Surtout dans") { a in
                Text(a.surtout == nonClasse ? L(nonClasse) : a.surtout).foregroundStyle(a.surtout == nonClasse ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
        }
    }
}

struct CarteBilan: View {
    let f: Fiche
    var body: some View {
        let reel = f.total / 3600
        let depasse = f.vendu.map { reel > $0 } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.nom).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let t = f.taux {
                    Text("\(euros(t)) / h").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                }
            }
            if let v = f.vendu {
                Barre(part: reel / Swift.max(v, 0.1), teinte: depasse ? .orange : .primary)
                HStack {
                    Text(L("%@ réelles sur %@ vendues", heures(f.total), heures(v * 3600)))
                    Spacer()
                    Text(depasse ? "+\(heures((reel - v) * 3600))" : L("%@ de marge", heures((v - reel) * 3600)))
                        .foregroundStyle(depasse ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 12)).monospacedDigit()
            }
            HStack(spacing: 12) {
                if let m = f.montant { Text(L("%@ HT", euros(m))) }
                if let v = f.vendu, let m = f.montant { Text(L("devis à %@ / h", euros(m / Swift.max(v, 0.1)))) }
                if let p = f.premier {
                    Text(L("depuis le %@", Date(timeIntervalSince1970: p).formatted(.dateTime.day().month(.wide))))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct VueBilan: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(etat.fiches.filter(\.aBilan)) { CarteBilan(f: $0) }
            }
            .padding(24)
        }
    }
}

struct VueExport: View {
    @EnvironmentObject var etat: Etat
    @State private var survol: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(etat.moisDispos, id: \.self) { m in
                    HStack {
                        Image(systemName: "tablecells").foregroundStyle(.tertiary)
                        Text(nomMois(m)).font(.system(size: 14))
                        Spacer()
                        Button("Exporter…") { Task { await etat.exporter(m) } }
                            .controlSize(.regular)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(survol == m ? 0.06 : 0.035)))
                    .onHover { survol = $0 ? m : nil }
                }
            }
            .padding(24)
        }
    }
}

struct FenetrePrincipale: View {
    @EnvironmentObject var etat: Etat
    @State private var rubrique: Rubrique? = .ensemble
    init(rubrique r: Rubrique? = nil) { _rubrique = State(initialValue: r ?? .ensemble) }

    func compte(_ r: Rubrique) -> Int? {
        switch r {
        case .ensemble: nil
        case .projets: etat.fiches.filter { $0.famille == projets }.count
        case .organiser: etat.categories.count
        case .apps: etat.apps.count
        case .bilan: etat.fiches.filter(\.aBilan).count
        case .export: etat.moisDispos.count
        }
    }

    func entree(_ r: Rubrique) -> some View {
        HStack {
            Label(L(r.rawValue), systemImage: r.icone)
            Spacer()
            if let c = compte(r) { Text("\(c)").foregroundStyle(.tertiary).monospacedDigit() }
        }
        .tag(r)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $rubrique) {
                Section("Temps") { entree(.ensemble); entree(.apps) }
                Section("Projets") {
                    entree(.projets)
                    if (compte(.bilan) ?? 0) > 0 { entree(.bilan) }
                    entree(.organiser)
                }
                Section("Sorties") { entree(.export) }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                if let e = etat.erreurFenetre {
                    Text(e).font(.callout).foregroundStyle(.orange).padding(10)
                }
                switch rubrique ?? .ensemble {
                case .ensemble: VueEnsemble()
                case .projets: VueProjets()
                case .organiser: ScrollView { EcranOrganiser(dansFenetre: true).frame(maxWidth: 560, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                case .apps: VueApps()
                case .bilan: VueBilan()
                case .export: VueExport()
                }
            }
            .navigationTitle(L(rubrique?.rawValue ?? "Temps"))
        }
        .overlay(alignment: .bottom) {
            if let r = etat.rangement {
                HStack {
                    Text(r.message).lineLimit(1)
                    Spacer()
                    Button("Annuler") { Task { await etat.annuler() } }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.dansFenetre, true)
        .sheet(item: $etat.classerFenetre) { d in
            ScrollView { EcranClasser(d: d).padding(18) }.frame(width: 400).frame(minHeight: 300, idealHeight: 520, maxHeight: 560).environmentObject(etat)
        }
        .task { etat.fenetreOuverte = true; await etat.chargerFenetre() }
        .onAppear {
            if let r = etat.rubriqueDemandee, let x = Rubrique(rawValue: r) { rubrique = x; etat.rubriqueDemandee = nil }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            etat.fenetreOuverte = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: etat.rubriqueDemandee) { _, r in
            if let r, let x = Rubrique(rawValue: r) { rubrique = x; etat.rubriqueDemandee = nil }
        }
        .onAppear { if let r = CommandLine.arguments.first(where: { $0.hasPrefix("--rubrique=") }) {
            rubrique = Rubrique.allCases.first { $0.rawValue == String(r.dropFirst(11)) } ?? .ensemble } }
    }
}
