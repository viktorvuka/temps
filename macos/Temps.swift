import SwiftUI
import ServiceManagement

// MARK: - Données

struct Reponse: Decodable {
    let depuis: Double?
    let dernier_releve: Double?
    let maj: Double?
    let familles: [Famille]?
    let categories: [Categorie]?
    let travail: Double?
    let histogramme: [Jour]?
    let reperes: [Repere]?
    let couleurs: [String: String]?
    let couleurs_posees: [String]?
    let series: [String]?
    let erreur: String?
}

struct Jour: Decodable, Identifiable {
    let jour: Double
    let travail: Double
    let parts: [String: Double]?
    var id: Double { jour }
}

// MARK: - Couleurs par série (workstation)

/// Ordre fixe des séries, de bas en haut dans les barres empilées. Palette validée (daltonisme,
/// contraste) en clair et en sombre ; l'orange reste réservé au non classé.
/// Teintes proposées (clair, sombre), validées pour le daltonisme et le contraste. L'orange est réservé au non classé.
let teintes: [(nom: String, clair: UInt32, sombre: UInt32)] = [
    ("bleu", 0x2a78d6, 0x3987e5), ("bleu nuit", 0x3a4fb8, 0x6d7fe0), ("ciel", 0x3fa7e0, 0x4cb2ea),
    ("turquoise", 0x1baf7a, 0x199e70), ("vert", 0x008300, 0x2f9e2f), ("olive", 0x7f8f1f, 0x9aab33),
    ("jaune", 0xeda100, 0xc98500), ("ocre", 0xc47a2c, 0xd08a3b), ("rouge", 0xe34948, 0xe66767),
    ("framboise", 0xc2306b, 0xd9507f), ("rose", 0xe87ba4, 0xd55181), ("violet", 0x6250d6, 0x9085e9),
    ("lavande", 0x9b86d6, 0xad9ce6), ("brun", 0x8a6b4f, 0xa3846a), ("ardoise", 0x5b6b7a, 0x7c8c9b),
    ("gris", 0x8f8d87, 0x77756f),
]
/// Couleur de chaque groupe ou sous-projet (choisie, ou donnée d'office par le serveur), mise à jour à chaque chargement.
@MainActor var couleursChoisies: [String: String] = [:]
/// Celles que l'on a posées soi-même dans `[couleurs]` (les autres sont données d'office).
@MainActor var couleursPosees: Set<String> = []
/// Ordre fixe des séries, de bas en haut, donné par le serveur : chaque groupe suivi de ses sous-projets colorés.
@MainActor var ordreSeries: [String] = ["Autres projets", "Activités", "Non classé"]

/// Libellé d'une série dans une légende : un sous-projet coloré garde seulement sa dernière partie.
func libelleSerie(_ s: String) -> String { s.components(separatedBy: " / ").last ?? s }

/// Six nuances d'une couleur, du plus clair au plus foncé, pour les sous-projets d'un groupe.
@MainActor func nuances(de c: Color) -> [String] {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
    let (r, g, b) = (n.redComponent, n.greenComponent, n.blueComponent)
    return [0.5, 0.3, 0.12, -0.15, -0.3, -0.45].map { k in
        func m(_ x: CGFloat) -> Int { Int(255 * (k > 0 ? x + (1 - x) * k : x * (1 + k))) }
        return String(format: "#%02x%02x%02x", m(r), m(g), m(b))
    }
}

@MainActor func teinte(de s: String) -> String? { couleursChoisies[s] }

func ns(_ h: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
}

/// Une teinte de la palette par son nom, ou une couleur libre « #rrggbb ».
func couleurTeinte(_ nom: String) -> Color {
    if nom.hasPrefix("#"), let h = UInt32(nom.dropFirst(), radix: 16) { return Color(nsColor: ns(h)) }
    let t = teintes.first { $0.nom == nom } ?? teintes.last!
    return Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(t.sombre) : ns(t.clair) })
}

@MainActor func couleurSerie(_ s: String) -> Color {
    if let t = teinte(de: s) { return couleurTeinte(t) }
    let (clair, sombre): (UInt32, UInt32) = switch s {
        case "Activités": (0xc4c2bc, 0x4d4c48)
        case "Non classé": (0xeb6834, 0xd95926)
        default: (0x8f8d87, 0x77756f)
    }
    func ns(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(sombre) : ns(clair)
    })
}

/// Même règle que rapport.serie côté serveur.
@MainActor func serie(cle: String, nom: String? = nil, famille: String) -> String {
    if famille == "Non classé" || famille == "Activités" { return famille }
    if cle.contains(" / "), couleursChoisies[cle] != nil { return cle }
    let groupe = (nom ?? cle).components(separatedBy: " / ")[0]
    if couleursChoisies[groupe] != nil { return groupe }
    let ws = cle.components(separatedBy: " / ")[0].components(separatedBy: " (")[0]
    return teinte(de: ws) != nil ? ws : "Autres projets"
}

/// Le groupe dont une catégorie prend la couleur (pour le menu Couleur).
func groupeCouleur(cle: String, nom: String) -> String {
    nom.contains(" / ") ? nom.components(separatedBy: " / ")[0] : cle.components(separatedBy: " / ")[0].components(separatedBy: " (")[0]
}

/// Ce qui permet à une ligne de détail de savoir si elle est dans la fenêtre (feuille) ou dans le panneau.
private struct CleDansFenetre: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var dansFenetre: Bool {
        get { self[CleDansFenetre.self] }
        set { self[CleDansFenetre.self] = newValue }
    }
}

/// Une barre empilée par série, avec 1 pt d'écart entre les segments.
struct BarreEmpilee: View {
    let parts: [String: Double]
    let hauteur: CGFloat
    let max: Double
    var body: some View {
        let presentes = ordreSeries.filter { (parts[$0] ?? 0) > 0 }
        VStack(spacing: 1) {
            ForEach(presentes.reversed(), id: \.self) { s in
                Rectangle().fill(couleurSerie(s))
                    .frame(height: Swift.max(1, hauteur * (parts[s] ?? 0) / max - 1))
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5))
    }
}

@MainActor func detailParts(_ j: Jour) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    let lignes = ordreSeries.compactMap { s in (j.parts?[s]).map { "\(L(libelleSerie(s))) : \(duree($0))" } }
    return ([f.string(from: Date(timeIntervalSince1970: j.jour)) + " — " + duree(j.travail)] + lignes).joined(separator: "\n")
}

struct Repere: Decodable, Identifiable {
    let nom: String
    let secondes: Double
    let objectif: Double?
    let plafond: Double?
    var id: String { nom }
}

struct Detail: Decodable, Identifiable {
    let appareil: String
    let app: String
    let contexte: String
    let secondes: Double
    var suggestion: String? = nil
    var id: String { appareil + "|" + app + "|" + contexte }

    /// Nom affiché de l'app : celui du Mac s'il la connaît, sinon la fin de l'identifiant.
    var nomApp: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return app.split(separator: ".").last.map(String.init) ?? app
    }
}

struct Poste: Decodable, Identifiable {
    var cle: String
    let nom: String
    let secondes: Double
    var detail: [Detail] = []
    var id: String { cle }
}

struct Famille: Decodable, Identifiable {
    let nom: String
    let secondes: Double
    let postes: [Poste]
    var id: String { nom }
}

struct Categorie: Decodable, Identifiable, Hashable {
    let cle: String
    let nom: String
    let famille: String
    var id: String { cle }
    /// « Studio / Dupont » : groupe « Studio », feuille « Dupont ».
    var groupe: String? { nom.contains(" / ") ? nom.components(separatedBy: " / ")[0] : nil }
    var feuille: String { nom.components(separatedBy: " / ").dropFirst(groupe == nil ? 0 : 1).joined(separator: " / ") }
}

/// Regroupe des noms « Groupe / Feuille » : un groupe n'apparaît que s'il a au moins deux membres.
func grouper<T>(_ items: [T], nom: (T) -> String) -> [(groupe: String?, items: [T])] {
    var ordre: [String] = [], paquets: [String: [T]] = [:]
    for i in items {
        let n = nom(i)
        let g = n.contains(" / ") ? n.components(separatedBy: " / ")[0] : n
        if paquets[g] == nil { ordre.append(g) }
        paquets[g, default: []].append(i)
    }
    return ordre.map { g in
        let l = paquets[g]!
        return (l.count > 1 || nom(l[0]).contains(" / ")) && l.count > 1 ? (g, l) : (nil, l)
    }
}

/// « Lun. 2 nov. »
func jourCourt(_ t: Double) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEdMMM")
    let s = f.string(from: Date(timeIntervalSince1970: t))
    return s.prefix(1).uppercased() + s.dropFirst()
}

func feuille(_ nom: String) -> String {
    nom.contains(" / ") ? nom.components(separatedBy: " / ").dropFirst().joined(separator: " / ") : nom
}

/// Texte de l'interface dans la langue du Mac. La clé est la phrase française (langue de développement) ;
/// la traduction anglaise vit dans en.lproj/Localizable.strings.
func L(_ cle: String, _ args: CVarArg...) -> String {
    let s = NSLocalizedString(cle, comment: "")
    return args.isEmpty ? s : String(format: s, arguments: args)
}

/// Une portée de règle proposée pour une ligne de détail : « ce site », « tout le domaine », etc.
struct Portee: Identifiable {
    let libelle: String
    let section: String
    let motif: String
    var id: String { section + "|" + motif }
}

/// Ce qui vient d'être fait, et l'appel qui le défait.
struct Rangement {
    let message: String
    let chemin: String
    let corps: [String: Any]
    let id = UUID()
}

enum Ecran: Equatable {
    case tableau, organiser
    case classer(Detail)
    static func == (a: Ecran, b: Ecran) -> Bool {
        switch (a, b) {
        case (.tableau, .tableau), (.organiser, .organiser): true
        case let (.classer(x), .classer(y)): x.id == y.id
        default: false
        }
    }
}

/// Réponse d'une écriture : l'ancienne valeur (chaîne, nombre ou table) pour pouvoir l'annuler.
struct Retour {
    let avant: Any?
    let erreur: String?
}

let navigateurs: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"]

extension Detail {
    var portees: [Portee] {
        var p: [Portee] = []
        let ctx = contexte
        if app.isEmpty { return p }
        if navigateurs.contains(app) || app.hasPrefix("com.apple.Safari.WebApp"), !ctx.isEmpty {
            p.append(Portee(libelle: L("Ce site"), section: "titres", motif: ctx))
            let morceaux = ctx.split(separator: ".")
            if morceaux.count > 2 {
                let domaine = morceaux.suffix(2).joined(separator: ".")
                p.append(Portee(libelle: L("Tout le domaine : %@", domaine), section: "titres", motif: domaine))
            }
        } else if app == "com.apple.mail", !ctx.isEmpty {
            let parts = ctx.components(separatedBy: " · ")
            let adresse = parts[0]
            p.append(Portee(libelle: L("Ce correspondant"), section: "titres", motif: adresse))
            if let at = adresse.firstIndex(of: "@") {
                let domaine = String(adresse[at...])
                p.append(Portee(libelle: L("Tout le domaine : %@", domaine), section: "titres", motif: domaine))
            }
            if parts.count > 1 {
                p.append(Portee(libelle: L("Toute la boîte : %@", parts[1]), section: "titres", motif: parts[1] + " /"))
            }
        } else if !ctx.isEmpty {
            let quoi = app == "com.anthropic.claudefordesktop" ? "Cette session" : "Ce titre"
            p.append(Portee(libelle: L(quoi), section: "titres", motif: ctx))
        }
        p.append(Portee(libelle: L("Toute l'app %@", nomApp), section: "apps", motif: app))
        return p
    }
}

let projets = "Projets", activites = "Activités", horsTravail = "Hors travail"

func iconeAppareil(_ nom: String) -> String {
    switch nom {
    case "iPhone": "iphone"
    case "iPad": "ipad"
    default: "laptopcomputer"
    }
}

let nonClasse = "Non classé"

func duree(_ s: Double) -> String {
    let m = Int((s / 60).rounded())
    return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
}

// MARK: - Moteur (scripts Python du prototype)

/// Le moteur vit dans « Temps Engine.app », à côté de Temps.app : c'est elle qui porte les accès
/// (disque, Accessibilité, Automatisation), et elle n'est pas recompilée avec l'interface.
final class Moteur {
    static let id = (Bundle.main.bundleIdentifier ?? "temps") + ".engine"
    static let app = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Temps Engine.app")

    func demarrer() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Moteur.id).isEmpty else { return }
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = false
        NSWorkspace.shared.openApplication(at: Moteur.app, configuration: conf)
    }

    func arreter() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Moteur.id).forEach { $0.terminate() }
    }
}

// MARK: - État

@MainActor
final class Etat: ObservableObject {
    @Published var jours = 0 { didSet { jourChoisi = nil; Task { await charger() } } }
    @Published var jourChoisi: Double? = nil
    @Published var histogramme: [Jour] = []
    @Published var reperes: [Repere] = []
    // Fenêtre
    @Published var fenetreOuverte = false
    @Published var periodeFenetre = 29 { didSet { Task { await chargerFenetre() } } }
    @Published var apps: [AppTemps] = []
    @Published var fiches: [Fiche] = []
    @Published var reperesTous: [Repere] = []
    @Published var moisDispos: [String] = []
    @Published var histoLong: [Jour] = []
    @Published var famillesFenetre: [Famille] = []
    @Published var travailFenetre: Double = 0
    @Published var facturableFenetre: Double = 0
    @Published var erreurFenetre: String?
    @Published var rubriqueDemandee: String?
    @Published var renommage: String?
    @Published var classerFenetre: Detail?
    @Published var familles: [Famille] = []
    @Published var categories: [Categorie] = []
    @Published var rangement: Rangement?
    @Published var ecran: Ecran = .tableau
    @Published var travail: Double = 0
    @Published var aujourdhui: Double?
    @Published var depuis: Date?
    @Published var vif = false
    @Published var erreur: String?
    @Published var auDemarrage = SMAppService.mainApp.status == .enabled

    let moteur = Moteur()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--apercu"), i + 1 < CommandLine.arguments.count {
            Etat.apercu(self, vers: CommandLine.arguments[i + 1])
            return
        }
        moteur.demarrer()
        Task {
            try? await Task.sleep(for: .seconds(2))
            while true {
                await charger()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func lire(_ jours: Int, jour: Double? = nil) async throws -> Reponse {
        let url = URL(string: "http://127.0.0.1:8230/api?" + (jour.map { "jour=\($0)" } ?? "jours=\(jours)"))!
        let (d, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Reponse.self, from: d)
    }

    func charger() async {
        do {
            let r = try await lire(jours, jour: jourChoisi)
            erreur = r.erreur
            depuis = r.depuis.map { Date(timeIntervalSince1970: $0) }
            vif = r.dernier_releve.map { (r.maj ?? 0) - $0 < 60 } ?? false
            familles = r.familles ?? []
            categories = r.categories ?? []
            travail = r.travail ?? 0
            couleursChoisies = r.couleurs ?? [:]
            couleursPosees = Set(r.couleurs_posees ?? [])
            if let s = r.series { ordreSeries = s }
            histogramme = r.histogramme ?? []
            reperes = r.reperes ?? []
            aujourdhui = jours == 0 && jourChoisi == nil ? travail : histogramme.last?.travail
        } catch {
            erreur = L("Serveur injoignable sur le port 8230. Journal : ~/Library/Application Support/Temps/journal.log")
        }
    }

    /// Un clic sur une barre de l'histogramme affiche ce jour-là ; sur aujourd'hui, revient à la vue du jour.
    func choisirJour(_ j: Jour) {
        if j.id == histogramme.last?.id {
            jourChoisi = nil
            if jours != 0 { jours = 0; return }
        } else {
            jourChoisi = j.jour
        }
        Task { await charger() }
    }

    /// Affiche la fenêtre quelques secondes et écrit son numéro (pour screencapture -l), puis quitte.
    static func apercu(_ etat: Etat, vers chemin: String) {
        Task { @MainActor in
            if CommandLine.arguments.contains("--semaine") { etat.jours = 6 }
            await etat.charger()
            if CommandLine.arguments.contains("--hier"), etat.histogramme.count > 1 {
                etat.jourChoisi = etat.histogramme[etat.histogramme.count - 2].jour
                await etat.charger()
            }
            if let r = CommandLine.arguments.first(where: { $0.hasPrefix("--rubrique=") }) {
                await etat.chargerFenetre()
                let nom = String(r.dropFirst(11))
                if CommandLine.arguments.contains("--classer"),
                   let d = etat.familles.first(where: { $0.nom == nonClasse })?.postes.first?.detail.first(where: { !$0.portees.isEmpty }) {
                    etat.classerFenetre = d
                }
                let vue = NSHostingView(rootView: FenetrePrincipale(rubrique: Rubrique(rawValue: nom)).environmentObject(etat))
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.contentView = vue
                w.appearance = NSAppearance(named: .darkAqua)
                w.orderFrontRegardless()
                w.center()
                _ = r
                try? await Task.sleep(for: .seconds(2))
                try? String(w.windowNumber).write(toFile: chemin, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(5))
                exit(0)
            }
            if CommandLine.arguments.contains("--organiser") { etat.ecran = .organiser }
            if CommandLine.arguments.contains("--classer"),
               let d = etat.familles.first(where: { $0.nom == nonClasse })?.postes.first?.detail.first(where: { !$0.portees.isEmpty }) {
                etat.ecran = .classer(d)
            }
            let vue = NSHostingView(rootView: Fenetre().environmentObject(etat))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: vue.intrinsicContentSize), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = vue
            w.appearance = NSAppearance(named: CommandLine.arguments.contains("--clair") ? .aqua : .darkAqua)
            w.backgroundColor = .windowBackgroundColor
            w.orderFrontRegardless()
            w.center()
            try? String(w.windowNumber).write(toFile: chemin, atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(6))
            exit(0)
        }
    }

    private func envoyer(_ chemin: String, _ corps: [String: Any]) async throws -> Retour {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8230/\(chemin)")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: corps)
        let (d, _) = try await URLSession.shared.data(for: req)
        let j = (try JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let avant = j["avant"].flatMap { $0 is NSNull ? nil : $0 }
        return Retour(avant: avant, erreur: j["erreur"] as? String)
    }

    /// Envoie une modification, recharge, et affiche la barre « Annuler » pendant 8 s.
    func modifier(_ chemin: String, _ corps: [String: Any], message: String,
                  annulation: (Retour) -> (String, [String: Any])) async {
        do {
            let r = try await envoyer(chemin, corps)
            if let e = r.erreur { erreur = e; return }
            let (c, k) = annulation(r)
            let fait = Rangement(message: message, chemin: c, corps: k)
            withAnimation(.snappy) { rangement = fait }
            await charger()
            if fenetreOuverte { await chargerFenetre() }
            try? await Task.sleep(for: .seconds(8))
            if rangement?.id == fait.id { withAnimation(.snappy) { rangement = nil } }
        } catch {
            erreur = L("Modification non écrite : serveur injoignable sur le port 8230.")
        }
    }

    func poser(_ section: String, _ motif: String, _ valeur: Any, message: String) async {
        await modifier("regle", ["section": section, "motif": motif, "valeur": valeur], message: message) { r in
            ("annuler", ["section": section, "motif": motif, "avant": r.avant ?? NSNull()])
        }
    }

    /// Retire une règle (fiche, repère, nom), annulable.
    func retirer(_ section: String, _ motif: String, ancien: Any, message: String) async {
        await modifier("annuler", ["section": section, "motif": motif, "avant": NSNull()], message: message) { _ in
            ("regle", ["section": section, "motif": motif, "valeur": ancien])
        }
    }

    func classer(_ p: Portee, dans cle: String) async {
        let nom = categories.first { $0.cle == cle }?.nom ?? cle
        withAnimation(.snappy) { ecran = .tableau }
        classerFenetre = nil
        await poser(p.section, p.motif, cle, message: L("Rangé dans %@", nom))
    }

    /// Nom vide ou égal à la clé : on revient au nom d'origine.
    func renommer(cle: String, ancien: String, en nom: String) async {
        let nom = nom.trimmingCharacters(in: .whitespaces)
        guard nom != ancien else { return }
        if nom.isEmpty || nom == cle {
            await modifier("annuler", ["section": "noms", "motif": cle, "avant": NSNull()], message: L("Nom d'origine rétabli")) { _ in
                ("regle", ["section": "noms", "motif": cle, "valeur": ancien])
            }
        } else {
            await poser("noms", cle, nom, message: L("Renommé en %@", nom))
        }
    }

    func changerFamille(_ c: Categorie, en f: String) async {
        guard f != c.famille else { return }
        await modifier("famille", ["cle": c.cle, "famille": f], message: "\(c.nom) → \(L(f))") { r in
            ("famille", ["cle": c.cle, "famille": (r.avant as? String) ?? projets])
        }
    }

    /// Glissé sur une autre catégorie : devient « Groupe / Feuille » et rejoint la famille de la cible.
    func imbriquer(_ c: Categorie, dans cible: Categorie) async {
        guard c.cle != cible.cle else { return }
        let groupe = cible.groupe ?? cible.nom
        await poser("noms", c.cle, "\(groupe) / \(c.feuille)", message: L("%@ rangé sous %@", c.feuille, groupe))
        if c.famille != cible.famille {
            _ = try? await envoyer("famille", ["cle": c.cle, "famille": cible.famille])
            await charger()
        }
    }

    func rangerSous(_ c: Categorie, groupe: String) async {
        await poser("noms", c.cle, "\(groupe) / \(c.feuille)", message: L("%@ rangé sous %@", c.feuille, groupe))
    }

    /// Nouvelle catégorie : une fiche vide suffit à la faire exister, avant toute règle.
    func creer(_ nom: String, famille f: String) async {
        let nom = nom.trimmingCharacters(in: .whitespaces)
        guard !nom.isEmpty, !categories.contains(where: { $0.cle == nom || $0.nom == nom }) else { return }
        await poser("projets", nom, ["facturable": f == projets], message: L("%@ créé", nom))
        if f != projets {
            _ = try? await envoyer("famille", ["cle": nom, "famille": f])
            await charger()
        }
    }

    /// Accepte toutes les suggestions d'une liste, chacune avec sa première portée ; une seule annulation.
    func accepterSuggestions(_ details: [Detail]) async {
        let liste: [[String: Any]] = details.compactMap { d in
            guard let s = d.suggestion, let p = d.portees.first else { return nil }
            return ["section": p.section, "motif": p.motif, "valeur": s]
        }
        guard !liste.isEmpty else { return }
        await modifier("lot", ["regles": liste], message: L("%d suggestions acceptées", liste.count)) { r in
            ("restaurer", ["texte": r.avant ?? ""])
        }
    }

    func supprimer(_ c: Categorie) async {
        await modifier("supprimer", ["cle": c.cle], message: L("%@ supprimé", c.nom)) { r in
            ("restaurer", ["texte": r.avant ?? ""])
        }
    }

    func choisirCouleur(_ groupe: String, teinte t: String?) async {
        if let t {
            await poser("couleurs", groupe, t, message: "\(groupe) → \(t.hasPrefix("#") ? t : L(t))")
        } else if couleursPosees.contains(groupe), let a = couleursChoisies[groupe] {
            await retirer("couleurs", groupe, ancien: a, message: L("%@ : couleur par défaut", groupe))
        }
    }

    func sortirDuGroupe(_ c: Categorie) async {
        await renommer(cle: c.cle, ancien: c.nom, en: c.feuille)
    }

    func annuler() async {
        guard let r = rangement else { return }
        withAnimation(.snappy) { rangement = nil }
        _ = try? await envoyer(r.chemin, r.corps)
        await charger()
    }

    func basculerDemarrage(_ oui: Bool) {
        do {
            if oui { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            erreur = L("Ouverture au démarrage impossible : %@", error.localizedDescription)
        }
        auDemarrage = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Vues

struct Barre: View {
    let part: Double
    var teinte: Color = .primary
    var opacite = 0.72
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(teinte.opacity(opacite))
                    .frame(width: max(3, g.size.width * min(1, part)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.35), value: part)
    }
}

struct Carte<Contenu: View>: View {
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { contenu }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct Etiquette: View {
    let texte: String
    var compte: Int? = nil
    var droite: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(L(texte)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let c = compte { Text("\(c)").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Spacer()
            if let d = droite { Text(d).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.bottom, 2)
    }
}

// MARK: - Tableau

/// Les 7 derniers jours. Un clic affiche le jour ; la barre choisie est pleine.
struct Histogramme: View {
    @EnvironmentObject var etat: Etat
    static let initiales = Calendar.current.veryShortWeekdaySymbols

    func choisi(_ j: Jour) -> Bool {
        if let c = etat.jourChoisi { return c == j.jour }
        return etat.jours == 0 && j.id == etat.histogramme.last?.id
    }

    var body: some View {
        let max = Swift.max(etat.histogramme.map(\.travail).max() ?? 0, 3600)
        let unJour = etat.jours == 0
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(etat.histogramme) { j in
                let date = Date(timeIntervalSince1970: j.jour)
                let jour = Calendar.current.component(.weekday, from: date) - 1
                let aujourdhui = j.id == etat.histogramme.last?.id
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(height: 38)
                        BarreEmpilee(parts: j.parts ?? [:], hauteur: 38, max: max)
                            .opacity(!unJour || choisi(j) ? 1 : 0.35)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(choisi(j) && unJour ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                    Text(Histogramme.initiales[jour])
                        .font(.system(size: 10, weight: aujourdhui || choisi(j) ? .semibold : .regular))
                        .foregroundStyle(aujourdhui ? AnyShapeStyle(Color.accentColor) : (choisi(j) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { etat.choisirJour(j) } }
                .help(detailParts(j))
            }
        }
        .animation(.easeOut(duration: 0.3), value: etat.histogramme.map(\.travail))
    }
}

struct LigneRepere: View {
    let r: Repere
    var body: some View {
        let cible = r.objectif ?? r.plafond ?? 1
        let depasse = r.plafond.map { r.secondes > $0 } ?? false
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(r.nom).lineLimit(1)
                Spacer()
                Text("\(duree(r.secondes)) / \(duree(cible))").monospacedDigit()
                    .foregroundStyle(depasse ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            Barre(part: r.secondes / cible, teinte: depasse ? .orange : .primary, opacite: r.plafond == nil ? 0.72 : 0.4)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 8)
    }
}

struct LigneDetail: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.dansFenetre) private var dansFenetre
    let d: Detail
    @State private var survol = false

    var classable: Bool { !d.portees.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            if d.appareil != "Mac" {
                Image(systemName: iconeAppareil(d.appareil)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(d.contexte.isEmpty ? d.nomApp : d.contexte).lineLimit(1).truncationMode(.middle)
            if !d.contexte.isEmpty && !d.app.isEmpty {
                Text(d.nomApp).lineLimit(1).foregroundStyle(.tertiary).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if survol && classable {
                Text("Classer").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            } else if d.suggestion != nil {
                Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(Color.accentColor.opacity(0.8))
                Text(duree(d.secondes)).monospacedDigit().foregroundStyle(.tertiary)
            } else {
                Text(duree(d.secondes)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(survol && classable ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture {
            guard classable else { return }
            if dansFenetre { etat.classerFenetre = d } else { withAnimation(.snappy(duration: 0.22)) { etat.ecran = .classer(d) } }
        }
        .help(d.suggestion.map { L("Suggestion : %@", $0) } ?? (d.contexte.isEmpty ? d.app : d.contexte))
    }
}

/// Un nom modifiable sur place : double-clic, Entrée pour valider, Échap pour annuler.
struct NomModifiable: View {
    @EnvironmentObject var etat: Etat
    let cle: String
    let nom: String
    var affiche: String? = nil
    var actif = true
    var style: AnyShapeStyle = AnyShapeStyle(.primary)
    @State private var edition = false
    @State private var brouillon = ""
    @FocusState private var focus: Bool

    var body: some View {
        if edition {
            TextField("", text: $brouillon)
                .textFieldStyle(.plain)
                .focused($focus)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.7)))
                .onSubmit { valider() }
                .onExitCommand { edition = false }
                .onChange(of: focus) { _, f in if !f && edition { valider() } }
                .onAppear { focus = true }
        } else {
            Text(affiche ?? nom).lineLimit(1).truncationMode(.tail).foregroundStyle(style)
                .onChange(of: etat.renommage) { _, c in
                    if c == cle { brouillon = nom; edition = true; etat.renommage = nil }
                }
                .onTapGesture(count: 2) {
                    guard actif else { return }
                    brouillon = nom
                    NSApp.activate(ignoringOtherApps: true)
                    edition = true
                }
        }
    }

    func valider() {
        edition = false
        let ancien = nom
        Task { await etat.renommer(cle: cle, ancien: ancien, en: brouillon) }
    }
}

/// Une catégorie : nom, durée, barre, et son détail au clic.
struct LignePoste: View {
    let poste: Poste
    let max: Double
    var teinte: Color = .primary
    var discret = false
    var affiche: String? = nil
    var pastille: Color? = nil
    @EnvironmentObject var etat: Etat
    @State private var ouvert: Bool
    @State private var survol = false
    @State private var tout = false

    var renommable: Bool { ![nonClasse, "autres", "hors"].contains(poste.cle) }

    init(poste: Poste, max: Double, teinte: Color = .primary, discret: Bool = false, affiche: String? = nil, pastille: Color? = nil) {
        self.poste = poste
        self.max = max
        self.teinte = teinte
        self.discret = discret
        self.affiche = affiche
        self.pastille = pastille
        _ouvert = State(initialValue: CommandLine.arguments.contains("--deplier=\(poste.nom)"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: discret ? 4 : 5) {
            HStack(spacing: 5) {
                if let p = pastille { Circle().fill(p).frame(width: 7, height: 7) }
                NomModifiable(cle: poste.cle, nom: poste.nom, affiche: affiche ?? (renommable ? nil : L(poste.nom)), actif: renommable,
                              style: teinte == .primary ? AnyShapeStyle(discret ? .secondary : .primary) : AnyShapeStyle(teinte))
                if !poste.detail.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(ouvert ? 90 : 0))
                }
                Spacer()
                Text(duree(poste.secondes)).monospacedDigit().foregroundStyle(.secondary)
            }
            Barre(part: poste.secondes / max, teinte: teinte, opacite: teinte == .primary ? (discret ? 0.35 : 0.72) : 0.85)
        }
        .font(.system(size: discret ? 12 : 13))
        .padding(.vertical, discret ? 4 : 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(survol && !poste.detail.isEmpty ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { ouvert.toggle() } }

        if ouvert {
            VStack(spacing: 4) {
                let suggerees = poste.detail.filter { $0.suggestion != nil && !$0.portees.isEmpty }
                if poste.cle == nonClasse && suggerees.count > 1 {
                    LigneChoix(texte: L("Accepter les %d suggestions", suggerees.count), icone: "sparkle", mis_en_avant: true) {
                        Task { await etat.accepterSuggestions(suggerees) }
                    }
                    .help(suggerees.map { "\($0.contexte) → \($0.suggestion!)" }.joined(separator: "\n"))
                    .padding(.bottom, 2)
                }
                let limite = tout ? poste.detail.count : 12
                ForEach(poste.detail.prefix(limite)) { LigneDetail(d: $0) }
                if poste.detail.count > 12 {
                    Button(tout ? L("Réduire") : L("Tout afficher (%d)", poste.detail.count)) {
                        withAnimation(.easeOut(duration: 0.16)) { tout.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5).padding(.top, 2)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 12).padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1) }
            .padding(.leading, 10).padding(.trailing, 8).padding(.bottom, 6)
            .transition(.opacity)
        }
    }
}

/// Des catégories « Groupe / Feuille » : le groupe en tête avec son total, ses membres en retrait.
struct ListeGroupee: View {
    let postes: [Poste]
    let max: Double
    var discret = false
    var famille = "Projets"

    func pastille(_ p: Poste) -> Color? {
        famille == "Projets" ? couleurSerie(serie(cle: p.cle, nom: p.nom, famille: famille)) : nil
    }

    var body: some View {
        ForEach(Array(grouper(postes) { $0.nom }.enumerated()), id: \.offset) { _, g in
            if let groupe = g.groupe {
                let total = g.items.reduce(0) { $0 + $1.secondes }
                HStack(spacing: 5) {
                    if let p = pastille(g.items[0]) { Circle().fill(p).frame(width: 7, height: 7) }
                    Text(groupe).font(.system(size: discret ? 12 : 13, weight: .semibold))
                        .foregroundStyle(discret ? .secondary : .primary)
                    Spacer()
                    Text(duree(total)).font(.system(size: discret ? 12 : 13)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(g.items) { p in
                        LignePoste(poste: p, max: max, discret: true, affiche: feuille(p.nom),
                                   pastille: couleursChoisies[p.cle] != nil ? couleurSerie(p.cle) : nil)
                    }
                }
                .padding(.leading, 22)
            } else {
                ForEach(g.items) { LignePoste(poste: $0, max: max, discret: discret, pastille: pastille($0)) }
            }
        }
    }
}

// MARK: - Classer

struct BoutonRetour: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        Button { etat.classerFenetre = nil; withAnimation(.snappy(duration: 0.22)) { etat.ecran = .tableau } } label: {
            Label("Retour", systemImage: "chevron.left").font(.system(size: 12))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
    }
}

struct LigneChoix: View {
    let texte: String
    var icone: String? = nil
    var retrait = false
    var mis_en_avant = false
    let action: () -> Void
    @State private var survol = false
    var body: some View {
        HStack(spacing: 6) {
            if let i = icone { Image(systemName: i).font(.system(size: 10, weight: .semibold)) }
            Text(texte).lineLimit(1)
            Spacer()
            if survol { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(icone == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
        .padding(.vertical, 4).padding(.horizontal, 8)
        .padding(.leading, retrait ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            mis_en_avant ? Color.accentColor.opacity(survol ? 0.22 : 0.14) : Color.primary.opacity(survol ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture(perform: action)
    }
}

/// Classer une ligne : d'abord ce qu'on range et sa portée, puis où on le range.
struct EcranClasser: View {
    @EnvironmentObject var etat: Etat
    let d: Detail
    @State private var portee: Portee?
    @State private var recherche = ""
    @FocusState private var focus: Bool

    var trouvees: [Categorie] {
        let q = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? etat.categories : etat.categories.filter { $0.nom.lowercased().contains(q) || $0.cle.lowercased().contains(q) }
    }

    var nouveau: String? {
        let q = recherche.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || etat.categories.contains { $0.nom.lowercased() == q.lowercased() } ? nil : q
    }

    var suggeree: Categorie? { d.suggestion.flatMap { s in etat.categories.first { $0.cle == s } } }

    func choisir(_ cle: String) {
        guard let p = portee ?? d.portees.first else { return }
        Task { await etat.classer(p, dans: cle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoutonRetour()

            // 1. Ce qu'on range
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.contexte.isEmpty ? d.nomApp : d.contexte)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text([d.contexte.isEmpty ? nil : d.nomApp, d.appareil == "Mac" ? nil : d.appareil, duree(d.secondes)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(d.portees) { p in
                        let choisie = (portee ?? d.portees.first)?.id == p.id
                        Text(p.libelle).lineLimit(1)
                            .font(.system(size: 11, weight: choisie ? .semibold : .regular))
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .foregroundStyle(choisie ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                            .background(Capsule().fill(choisie ? Color.accentColor : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                            .onTapGesture { withAnimation(.snappy(duration: 0.15)) { portee = p } }
                            .help(p.motif)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.06)))

            // 2. Où le ranger
            VStack(alignment: .leading, spacing: 6) {
                Text("Ranger dans").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                TextField("Chercher ou créer un projet", text: $recherche)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus)
                    .onSubmit {
                        if let n = nouveau, trouvees.isEmpty { choisir(n) } else if let c = trouvees.first { choisir(c.cle) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    if let s = suggeree, recherche.isEmpty {
                        LigneChoix(texte: s.nom, icone: "sparkle", mis_en_avant: true) { choisir(s.cle) }
                            .padding(.bottom, 4)
                    }
                    if let n = nouveau {
                        LigneChoix(texte: L("Créer « %@ »", n), icone: "plus") { choisir(n) }
                    }
                    ForEach([projets, activites, horsTravail], id: \.self) { f in
                        let cats = trouvees.filter { $0.famille == f }
                        if !cats.isEmpty {
                            Text(L(f)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                .padding(.top, 6).padding(.horizontal, 8)
                            ForEach(Array(grouper(Array(cats.prefix(recherche.isEmpty ? 14 : 30))) { $0.nom }.enumerated()), id: \.offset) { _, g in
                                if let groupe = g.groupe {
                                    Text(groupe).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 8).padding(.top, 3)
                                    ForEach(g.items) { c in LigneChoix(texte: c.feuille, retrait: true) { choisir(c.cle) } }
                                } else {
                                    ForEach(g.items) { c in LigneChoix(texte: c.nom) { choisir(c.cle) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            portee = d.portees.first
            NSApp.activate(ignoringOtherApps: true)
            focus = true
        }
    }
}

// MARK: - Organiser

func hex(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
    return String(format: "#%02x%02x%02x", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
}

/// Choix de couleur d'un groupe (« Studio ») ou d'un sous-projet (« Studio / Dupont »).
/// Pour un sous-projet : les nuances du groupe d'abord, toute la palette ensuite ; sans choix, il prend la couleur du groupe.
struct ChoixCouleur: View {
    @EnvironmentObject var etat: Etat
    let cle: String
    let titre: String
    var groupe: String? = nil
    @State private var libre: Color = .gray

    func pastille(_ valeur: String, aide: String) -> some View {
        let choisie = couleursChoisies[cle] == valeur
        return Circle().fill(couleurTeinte(valeur))
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.primary.opacity(choisie ? 0.9 : 0), lineWidth: 2).padding(-3))
            .contentShape(Circle())
            .onTapGesture { Task { await etat.choisirCouleur(cle, teinte: valeur) } }
            .help(aide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titre).font(.system(size: 13, weight: .semibold))
            let grille = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8)
            if let g = groupe {
                Text(L("Nuances de %@", g)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: grille, spacing: 8) {
                    ForEach(nuances(de: couleurSerie(g)), id: \.self) { pastille($0, aide: $0) }
                }
                Text("Toutes les teintes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: grille, spacing: 8) {
                ForEach(teintes, id: \.nom) { t in pastille(t.nom, aide: L(t.nom).prefix(1).uppercased() + L(t.nom).dropFirst()) }
            }
            HStack {
                ColorPicker("Autre couleur", selection: Binding(get: { libre }, set: { c in
                    libre = c
                    Task { await etat.choisirCouleur(cle, teinte: hex(c)) }
                }), supportsOpacity: false)
                Spacer()
                if couleursPosees.contains(cle) {
                    Button(groupe == nil ? L("Par défaut") : L("Couleur du groupe")) { Task { await etat.choisirCouleur(cle, teinte: nil) } }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { libre = couleurSerie(couleursChoisies[cle] != nil ? cle : (groupe ?? cle)) }
    }
}

/// Toutes les catégories par famille. Glisser sur une famille pour l'y ranger, sur une catégorie pour en
/// faire un sous-projet ; clic droit pour renommer, ranger sous un groupe, changer la couleur ou supprimer.
struct EcranOrganiser: View {
    @EnvironmentObject var etat: Etat
    var dansFenetre = false
    @State private var cible: String?
    @State private var nouvelles: [String: String] = [:]
    @State private var couleurOuverte: String?
    @State private var survolee: String?

    func trouver(_ cle: String) -> Categorie? { etat.categories.first { $0.cle == cle } }

    var groupes: [String] {
        Array(Set(etat.categories.compactMap(\.groupe))).sorted()
    }

    /// Pastille qui ouvre le choix de couleur. Sur un en-tête de groupe : la couleur du groupe.
    /// Sur un sous-projet : sa couleur propre, ou celle du groupe tant qu'il n'en a pas.
    /// Hors projets, un emplacement vide garde les noms alignés.
    func pastille(cle: String, titre: String, groupe: String?, couleur: Color, famille f: String) -> some View {
        Group {
            if f == projets {
                Circle().fill(couleur)
                    .frame(width: 8, height: 8)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { couleurOuverte = cle }
                    .popover(isPresented: Binding(get: { couleurOuverte == cle }, set: { if !$0 { couleurOuverte = nil } })) {
                        ChoixCouleur(cle: cle, titre: titre, groupe: groupe).environmentObject(etat)
                    }
                    .help(L("Couleur de « %@ »", titre))
            } else {
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .frame(width: 8)
    }

    func ligne(_ c: Categorie, retrait: Bool) -> some View {
        let g = groupeCouleur(cle: c.cle, nom: c.nom)
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
                .opacity(survolee == c.cle ? 1 : 0)
            pastille(cle: retrait ? c.cle : g, titre: retrait ? c.nom : g, groupe: retrait ? g : nil,
                     couleur: couleurSerie(serie(cle: c.cle, nom: c.nom, famille: c.famille)), famille: c.famille)
            NomModifiable(cle: c.cle, nom: c.nom, affiche: retrait ? c.feuille : c.nom)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.vertical, 3).padding(.horizontal, 8)
        .padding(.leading, retrait ? 14 : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(cible == c.cle ? Color.accentColor.opacity(0.18) : Color.primary.opacity(survolee == c.cle ? 0.05 : 0)))
        .onHover { survolee = $0 ? c.cle : (survolee == c.cle ? nil : survolee) }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(cible == c.cle ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .draggable(c.cle) {
            Text(c.nom).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .dropDestination(for: String.self) { cles, _ in
            guard let k = cles.first, let source = trouver(k) else { return false }
            Task { await etat.imbriquer(source, dans: c) }
            return true
        } isTargeted: { dedans in cible = dedans ? c.cle : (cible == c.cle ? nil : cible) }
        .contextMenu {
            Button("Renommer") { etat.renommage = c.cle }
            Menu("Ranger sous") {
                ForEach(groupes.filter { $0 != c.groupe }, id: \.self) { g in
                    Button(g) { Task { await etat.rangerSous(c, groupe: g) } }
                }
                if c.groupe != nil {
                    Divider()
                    Button(L("Sortir de « %@ »", c.groupe!)) { Task { await etat.sortirDuGroupe(c) } }
                }
            }
            Menu("Déplacer vers") {
                ForEach([projets, activites, horsTravail].filter { $0 != c.famille }, id: \.self) { f in
                    Button(L(f)) { Task { await etat.changerFamille(c, en: f) } }
                }
            }
            if c.famille == projets {
                Button("Couleur…") { couleurOuverte = retrait ? c.cle : g }
            }
            Divider()
            Button("Supprimer", role: .destructive) { Task { await etat.supprimer(c) } }
        }
    }

    func champNouvelle(_ f: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
            Color.clear.frame(width: 8, height: 1)
            TextField(f == projets ? L("Nouveau projet, ou Groupe / Projet") : L("Nouvelle catégorie"), text: Binding(
                get: { nouvelles[f] ?? "" }, set: { nouvelles[f] = $0 }))
                .textFieldStyle(.plain)
                .onSubmit {
                    let n = nouvelles[f] ?? ""
                    nouvelles[f] = ""
                    Task { await etat.creer(n, famille: f) }
                }
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !dansFenetre {
                BoutonRetour()
                Text("Organiser").font(.system(size: 15, weight: .semibold))
            }
            ForEach([projets, activites, horsTravail], id: \.self) { f in
                let cats = etat.categories.filter { $0.famille == f }.sorted { $0.nom.lowercased() < $1.nom.lowercased() }
                Carte {
                    Etiquette(texte: f, compte: cats.count)
                    ForEach(Array(grouper(cats) { $0.nom }.enumerated()), id: \.offset) { _, g in
                        if let groupe = g.groupe {
                            HStack(spacing: 6) {
                                Color.clear.frame(width: 10, height: 1)
                                pastille(cle: groupe, titre: groupe, groupe: nil,
                                         couleur: couleurSerie(serie(cle: g.items[0].cle.components(separatedBy: " / ")[0], nom: groupe, famille: f)), famille: f)
                                Text(groupe).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.top, 4)
                            ForEach(g.items) { ligne($0, retrait: true) }
                        } else {
                            ForEach(g.items) { ligne($0, retrait: false) }
                        }
                    }
                    champNouvelle(f)
                }
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(cible == f ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
                .dropDestination(for: String.self) { cles, _ in
                    guard let k = cles.first, let source = trouver(k), source.famille != f else { return false }
                    Task { await etat.changerFamille(source, en: f) }
                    return true
                } isTargeted: { dedans in cible = dedans ? f : (cible == f ? nil : cible) }
            }
        }
    }
}

// MARK: - Fenêtre

struct Fenetre: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.openWindow) private var openWindow

    /// Au plus sept lignes : le reste passe dans « Autres », dépliable.
    /// (Pas de ScrollView : dans la fenêtre de la barre des menus, il s'effondre à une hauteur nulle.)
    static func resserrer(_ postes: [Poste], max: Int = 7) -> [Poste] {
        guard postes.count > max else { return postes }
        let reste = postes.dropFirst(max - 1)
        let detail = reste.flatMap { $0.detail }.sorted { $0.secondes > $1.secondes }
        return Array(postes.prefix(max - 1)) + [Poste(cle: "autres", nom: "Autres", secondes: reste.reduce(0) { $0 + $1.secondes }, detail: detail)]
    }

    func famille(_ nom: String) -> Famille? { etat.familles.first { $0.nom == nom } }

    var periode: String {
        guard let d = etat.depuis else { return "" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let jour = f.string(from: d)
        return etat.jours == 0 || etat.jourChoisi != nil ? jour.prefix(1).uppercased() + jour.dropFirst() : L("Depuis %@", jour)
    }

    /// Le hors travail tient en une ligne : son détail liste les catégories qu'il regroupe.
    func ligneHors(_ f: Famille) -> Poste {
        let detail = f.postes.map { p in
            Detail(appareil: p.detail.first?.appareil ?? "Mac", app: "", contexte: p.nom, secondes: p.secondes)
        }
        return Poste(cle: "hors", nom: horsTravail, secondes: f.secondes, detail: detail)
    }

    var body: some View {
        Group {
            switch etat.ecran {
            case .tableau: tableau
            case .organiser: EcranOrganiser()
            case .classer(let d): EcranClasser(d: d)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let r = etat.rangement {
                HStack {
                    Text(r.message).lineLimit(1)
                    Spacer()
                    Button("Annuler") { Task { await etat.annuler() } }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task { await etat.charger() }
    }

    var tableau: some View {
        let echelle = max(famille(projets)?.postes.first?.secondes ?? 0, famille(nonClasse)?.secondes ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(duree(etat.travail))
                        .font(.system(size: 30, weight: .semibold)).tracking(-0.6).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(periode).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Histogramme().frame(width: 150)
            }
            .padding(.horizontal, 4)

            Picker("", selection: $etat.jours) {
                Text(etat.jourChoisi.map { jourCourt($0) } ?? L("Aujourd'hui")).tag(0)
                Text("7 jours").tag(6)
                Text("30 jours").tag(29)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)

            if let e = etat.erreur {
                Text(e).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if !etat.reperes.isEmpty {
                Carte {
                    Etiquette(texte: "Cette semaine")
                    ForEach(etat.reperes) { LigneRepere(r: $0) }
                }
            }

            Carte {
                if let p = famille(projets) {
                    Etiquette(texte: projets, compte: p.postes.count, droite: duree(p.secondes))
                    ListeGroupee(postes: Fenetre.resserrer(p.postes, max: 9), max: echelle)
                }
                if let n = famille(nonClasse), let poste = n.postes.first {
                    LignePoste(poste: poste, max: echelle, teinte: .orange)
                        .padding(.top, famille(projets) == nil ? 0 : 4)
                }
                if let a = famille(activites) {
                    Divider().padding(.vertical, 6).padding(.horizontal, 8)
                    Etiquette(texte: activites, compte: a.postes.count, droite: duree(a.secondes))
                    ListeGroupee(postes: Fenetre.resserrer(a.postes, max: 4), max: echelle, discret: true, famille: activites)
                }
            }

            if let h = famille(horsTravail) {
                LignePoste(poste: ligneHors(h), max: max(h.secondes, echelle), discret: true)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 14) {
                Button("Ouvrir Temps") {
                    openWindow(id: "fenetre")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Organiser") {
                    etat.rubriqueDemandee = "Organiser"
                    openWindow(id: "fenetre")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Ouvrir au démarrage", isOn: Binding(get: { etat.auDemarrage }, set: { etat.basculerDemarrage($0) }))
                    Divider()
                    Button("Quitter Temps") { etat.moteur.arreter(); NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 4).padding(.top, 2)
        }
    }
}

@main
struct TempsApp: App {
    @StateObject private var etat = Etat()

    var body: some Scene {
        MenuBarExtra {
            Fenetre().environmentObject(etat)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: etat.vif ? "timer" : "pause.circle")
                if let t = etat.aujourdhui { Text(duree(t)).monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Temps", id: "fenetre") {
            FenetrePrincipale().environmentObject(etat)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Exporter le mois en cours…") {
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM"
                    Task { await etat.exporter(f.string(from: Date())) }
                }
                .keyboardShortcut("e")
            }
            CommandGroup(after: .appSettings) {
                Toggle("Ouvrir au démarrage", isOn: Binding(get: { etat.auDemarrage }, set: { etat.basculerDemarrage($0) }))
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(Rubrique.allCases.enumerated()), id: \.offset) { i, r in
                    Button(L(r.rawValue)) { etat.rubriqueDemandee = r.rawValue }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quitter Temps") { etat.moteur.arreter(); NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}
