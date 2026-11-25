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
    let mois: [Jour]?
    let reperes: [Repere]?
    let couleurs: [String: String]?
    let couleurs_posees: [String]?
    let series: [String]?
    let missions: [String: [String: String]]?
    let lissage: Double?
    let domaines: [Domaine]?
    let erreur: String?
}

struct Jour: Decodable, Identifiable {
    let jour: Double
    let travail: Double
    let parts: [String: Double]?
    var id: Double { jour }
}

// MARK: - Couleurs par série (workstation)

extension Color {
    /// Liens et boutons texte : la couleur d'accent, éclaircie en mode sombre pour rester lisible sur le fond.
    static let lien = Color(nsColor: NSColor(name: nil) { a in
        let c = NSColor.controlAccentColor
        // lisible des deux côtés (AA) : éclairci en sombre, assombri en clair
        guard a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return c.blended(withFraction: 0.25, of: .black) ?? c }
        return c.blended(withFraction: 0.25, of: .white) ?? c
    })
}

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

// MARK: - Nuances en OKLCH
// Des pas de clarté réguliers à l'œil (OKLCH est perceptuellement uniforme), la teinte du domaine gardée,
// la saturation qui baisse aux extrêmes, et un léger glissement de teinte aux deux bouts :
// vers le jaune pour les nuances claires, vers le bleu pour les foncées. Les pas alternent clair et foncé,
// pour que deux projets voisins dans une liste se distinguent.

/// Écart de clarté (L d'OKLCH) de chaque pas, de 1 à 8.
let pasDeNuance: [Double] = [0.09, -0.09, 0.17, -0.16, 0.045, -0.045, 0.13, -0.125]

func versOKLab(_ c: NSColor) -> (Double, Double, Double) {
    func lin(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    let (r, g, b) = (lin(c.redComponent), lin(c.greenComponent), lin(c.blueComponent))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

/// sRGB linéaire d'un point OKLab (peut sortir de [0, 1] : hors gamut).
func depuisOKLab(_ L: Double, _ A: Double, _ B: Double) -> (Double, Double, Double) {
    let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
    let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
    let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
}

func nuanceOKLCH(_ c: NSColor, pas: Int, sombre: Bool) -> NSColor {
    let (L, A, B) = versOKLab(c)
    var C = (A * A + B * B).squareRoot()
    var h = atan2(B, A) * 180 / .pi
    var dL = pasDeNuance[(Swift.max(pas, 1) - 1) % pasDeNuance.count]
    if !sombre && dL > 0 { dL *= 0.75 }   // sur fond clair, une nuance trop pâle disparaît
    if sombre && dL < 0 { dL *= 0.8 }     // sur fond sombre, une nuance trop foncée aussi
    let L2 = Swift.min(Swift.max(L + dL, 0.25), 0.93)
    // glissement de teinte vers le jaune (≈ 95°) en clair, vers le bleu (≈ 265°) en foncé, au plus 12 %
    let cible = dL > 0 ? 95.0 : 265.0
    var ecart = (cible - h).truncatingRemainder(dividingBy: 360)
    if ecart > 180 { ecart -= 360 } else if ecart < -180 { ecart += 360 }
    h += ecart * Swift.min(abs(dL) / 0.17, 1) * 0.12
    // la saturation suit la clarté : moins vive aux extrêmes
    C *= 1 - Swift.min(abs(dL) / 0.17, 1) * 0.22
    // rester dans le gamut sRGB : on baisse la saturation jusqu'à y entrer
    func rgb(_ C: Double) -> (Double, Double, Double) {
        depuisOKLab(L2, C * cos(h * .pi / 180), C * sin(h * .pi / 180))
    }
    var (r, g, b) = rgb(C)
    var i = 0
    while i < 20 && [r, g, b].contains(where: { $0 < -0.0001 || $0 > 1.0001 }) { C *= 0.92; (r, g, b) = rgb(C); i += 1 }
    func gam(_ x: Double) -> CGFloat {
        let x = Swift.min(Swift.max(x, 0), 1)
        return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }
    return NSColor(srgbRed: gam(r), green: gam(g), blue: gam(b), alpha: 1)
}

/// Une teinte de la palette par son nom, ou une couleur libre « #rrggbb ».
func couleurTeinte(_ nom: String) -> Color {
    // « nuance:teinte:n » : le n-ième pas de nuance de la teinte du domaine, calculé en OKLCH
    if nom.hasPrefix("nuance:") {
        let p = nom.dropFirst(7).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(p.first ?? ""), pas = Int(p.count > 1 ? String(p[1]) : "1") ?? 1
        let fond = NSColor(couleurTeinte(base))
        return Color(nsColor: NSColor(name: nil) { a in
            var c = fond
            a.performAsCurrentDrawingAppearance { c = fond.usingColorSpace(.sRGB) ?? .gray }
            return nuanceOKLCH(c, pas: pas, sombre: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        })
    }
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
    let segs = (nom ?? cle).components(separatedBy: " / ")
    if segs.count >= 2 {
        let k = segs[0] + " / " + (segs[1].components(separatedBy: " · ").first ?? segs[1])
        if couleursChoisies[k] != nil { return k }
    }
    let groupe = segs[0]
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
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
    }
}

/// Un format de date localisé, créé une fois (en créer un par ligne et par dessin coûte cher).
func formatDate(_ gabarit: String) -> DateFormatter {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(gabarit)
    return f
}
let formatJourLong = formatDate("EEEEdMMMM"), formatJourCourt = formatDate("EEEdMMM"), formatHeureCourte = formatDate("jm")

@MainActor func detailParts(_ j: Jour) -> String {
    let f = formatJourLong
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
    var partage: Bool? = nil
    var raison: String? = nil
    /// La catégorie où la ligne est rangée aujourd'hui (nil ou Non classé : à classer).
    var dans: String? = nil
    /// Un créneau du ruban [début, fin] : il devient la première portée.
    var creneau: [Double]? = nil
    var id: String { appareil + "|" + app + "|" + contexte + (creneau.map { "|\($0[0])" } ?? "") }
    /// Déjà rangée ailleurs : une règle de texte ne suffirait pas face à un dossier, on force.
    var dejaRangee: Bool { dans != nil && dans != "Non classé" && dans != "" }

    /// Nom affiché de l'app : celui du Mac s'il la connaît, sinon la fin de l'identifiant.
    var nomApp: String { app == "manuel" ? L("Saisie à la main") : Apps.partage.nom(app) }
    /// Une ligne sans app (un regroupement) ne se classe pas.
    var classable: Bool { !app.isEmpty }
}

/// Nom et icône de chaque app, demandés une fois au Mac puis gardés : les listes en affichent des centaines,
/// et les redemander à chaque dessin ralentit le défilement.
final class Apps: @unchecked Sendable {
    static let partage = Apps()
    private let verrou = NSLock()
    private var noms: [String: String] = [:]
    private var icones: [String: NSImage?] = [:]

    func nom(_ id: String) -> String {
        verrou.lock(); defer { verrou.unlock() }
        if let n = noms[id] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? id.split(separator: ".").last.map(String.init) ?? id
        noms[id] = n
        return n
    }

    func icone(_ id: String) -> NSImage? {
        verrou.lock(); defer { verrou.unlock() }
        if let i = icones[id] { return i }
        let i = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icones[id] = i
        return i
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
    var archive: Bool? = nil
    /// Pour une mission : la clé de son client. Pour un client découpé en missions : `missions == true`.
    var mission_de: String? = nil
    var missions: Bool? = nil
    var id: String { cle }
    var archivee: Bool { archive == true }
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
    let s = formatJourCourt.string(from: Date(timeIntervalSince1970: t))
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

/// La file de rattrapage : les lignes non classées une à une, de la plus longue à la plus courte.
struct Rattrapage {
    var total: Int
    var faits = 0
    var ecartes: Set<String> = []
}

/// Ce qui vient d'être fait, et l'appel qui le défait.
struct Rangement {
    let message: String
    let chemin: String
    let corps: [String: Any]
    let id = UUID()
}

enum Ecran: Equatable {
    case tableau
    case classer(Detail)
    static func == (a: Ecran, b: Ecran) -> Bool {
        switch (a, b) {
        case (.tableau, .tableau): true
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
        if app.isEmpty && creneau == nil { return p }
        if navigateurs.contains(app), let local = ctx.components(separatedBy: " — ").last,
           local.hasPrefix("localhost") || local.hasPrefix("127.0.0.1") || local.contains(".localhost") || local.contains(".test") {
            // serveur de développement : « Titre — localhost:8463 »
            let titre = ctx.contains(" — ") ? ctx.components(separatedBy: " — ").dropLast().joined(separator: " — ") : ""
            if !titre.isEmpty { p.append(Portee(libelle: L("Cette page"), section: "titres", motif: titre)) }
            p.append(Portee(libelle: L("Ce port : %@", local), section: "titres", motif: local))
        } else if navigateurs.contains(app) || app.hasPrefix("com.apple.Safari.WebApp"), !ctx.isEmpty {
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
        if dejaRangee {
            p = p.map { Portee(libelle: $0.libelle, section: $0.section == "titres" ? "forcer" : $0.section, motif: $0.motif) }
        } else if !app.isEmpty {
            p.append(Portee(libelle: L("Toute l'app %@", nomApp), section: "apps", motif: app))
        }
        if let c = creneau, c.count == 2 {
            let h = "\(formatHeureCourte.string(from: Date(timeIntervalSince1970: c[0])))–\(formatHeureCourte.string(from: Date(timeIntervalSince1970: c[1])))"
            p.insert(Portee(libelle: L("Ce créneau : %@", h), section: "creneau", motif: "\(c[0])|\(c[1])"), at: 0)
        }
        if !ctx.isEmpty {
            // sans règle : seulement cette source, sur la période affichée
            let fois = Portee(libelle: L("Juste cette fois"), section: "une-fois", motif: ctx)
            if partage == true && creneau == nil { p.insert(fois, at: 0) } else { p.append(fois) }
        }
        return p
    }

    /// Le motif qui marque la source comme partagée : le domaine d'un site, sinon le contexte.
    var motifPartage: String {
        if navigateurs.contains(app) || app.hasPrefix("com.apple.Safari.WebApp") {
            let morceaux = contexte.split(separator: ".")
            if morceaux.count > 2, !contexte.contains(" — ") { return morceaux.suffix(2).joined(separator: ".") }
        }
        return contexte
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

// MARK: - Moteur (scripts Python)

/// Temps lance lui-même l'enregistreur et le serveur Python et les relance s'ils s'arrêtent. Dans l'app
/// prête à télécharger (`macos/paquet.sh`), les scripts et un Python autonome sont rangés dans l'app elle-même
/// (Resources/moteur, Resources/python) et les règles vont dans Application Support ; sinon, les scripts
/// sont à côté de Temps.app et Python est celui du Mac. Les accès macOS (disque, Accessibilité, Automatisation) sont ceux de
/// Temps.app : macOS les attribue à l'app qui a lancé les scripts.
/// `open Temps.app --args --demo` lance seulement le serveur, sur les données de démonstration.
final class Moteur {
    static let ressources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    /// Vrai pour l'app prête à télécharger : son moteur et son Python sont dedans.
    static let embarque = FileManager.default.fileExists(atPath: ressources.appendingPathComponent("moteur/server.py").path)
    static let dossier = embarque ? ressources.appendingPathComponent("moteur") : Bundle.main.bundleURL.deletingLastPathComponent()
    static let donnees = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Temps")
    /// Python 3.11 ou plus récent (tomllib) : celui de l'app s'il y en a un, puis Homebrew, python.org, celui du système.
    static let python = [ressources.appendingPathComponent("python/bin/python3").path,
                         "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    let demo = CommandLine.arguments.contains("--demo")
    var scripts: [String] { demo ? ["server.py"] : ["recorder.py", "server.py"] }
    private var enfants: [String: Process] = [:]
    private var minuteur: Timer?
    private var pids: URL { Moteur.donnees.appendingPathComponent("moteur.pid") }

    func demarrer() {
        try? FileManager.default.createDirectory(at: Moteur.donnees, withIntermediateDirectories: true)
        nettoyer()
        for s in scripts { lancer(s) }
        minuteur = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            for s in self.scripts where self.enfants[s]?.isRunning != true { self.lancer(s) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.arreter()
        }
    }

    func arreter() {
        minuteur?.invalidate()
        enfants.values.forEach { $0.terminate() }
        enfants = [:]
        try? FileManager.default.removeItem(at: pids)
    }

    private func lancer(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Moteur.python)
        var env = ProcessInfo.processInfo.environment
        env["TEMPS_LANGUE"] = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        if demo { env["TEMPS_DEMO"] = "1" }
        if Moteur.embarque {
            // rien ne s'écrit dans l'app : les règles vivent avec les données (la démo garde les siennes à part)
            if !demo { env["TEMPS_REGLES"] = Moteur.donnees.appendingPathComponent("rules.toml").path }
            env["PYTHONDONTWRITEBYTECODE"] = "1"
        }
        p.environment = env
        p.arguments = [Moteur.dossier.appendingPathComponent(script).path]
        p.currentDirectoryURL = Moteur.dossier
        let journal = Moteur.donnees.appendingPathComponent("journal.log")
        if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: journal) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        try? p.run()
        enfants[script] = p
        let liste = enfants.values.filter(\.isRunning).map { String($0.processIdentifier) }
        try? liste.joined(separator: "\n").write(to: pids, atomically: true, encoding: .utf8)
    }

    /// Arrête les scripts laissés par une session de Temps qui ne s'est pas fermée proprement.
    private func nettoyer() {
        guard let texte = try? String(contentsOf: pids, encoding: .utf8) else { return }
        for ligne in texte.split(separator: "\n") {
            if let pid = pid_t(ligne), Moteur.estPython(pid) { kill(pid, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: pids)
    }

    /// Vrai si le processus est bien un des scripts Python de Temps (un numéro peut avoir été réattribué).
    private static func estPython(_ pid: pid_t) -> Bool {
        var nom = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &nom, UInt32(nom.count)) > 0 else { return false }
        return String(cString: nom).lowercased().contains("python")
    }
}

// MARK: - État

@MainActor
final class Etat: ObservableObject {
    @Published var jours = 0 { didSet { jourChoisi = nil; Task { await charger() } } }
    @Published var jourChoisi: Double? = nil
    /// Les lignes dépliées du panneau et de la fenêtre (clés « p:… », « f:… »).
    @Published var deplies: Set<String> = []
    @Published var histogramme: [Jour] = []
    /// Les 30 derniers jours, pour le calendrier du panneau.
    @Published var mois: [Jour] = []
    @Published var reperes: [Repere] = []
    // Fenêtre
    @Published var fenetreOuverte = false
    @Published var periodeFenetre = Etat.datesLibres { didSet { if !enLot { Task { await chargerFenetre() } } } }
    /// La période se choisit par unité (jour, semaine, mois) et par un jour de référence qu'on déplace.
    enum Unite: String, CaseIterable { case jour, semaine, mois, trimestre, annee, plage }
    /// Plage libre choisie dans le calendrier (unite == .plage).
    var plageDebut = Calendar.current.startOfDay(for: Date())
    var plageFin = Calendar.current.startOfDay(for: Date())
    @Published var unite: Unite = .semaine
    @Published var ancre = Calendar.current.startOfDay(for: Date())
    /// Pendant qu'on règle plusieurs valeurs d'un coup, un seul chargement à la fin.
    var enLot = false
    @Published var fiches: [Fiche] = []
    @Published var reperesTous: [Repere] = []
    /// Récap de la semaine affichée (unité Semaine seulement).
    @Published var recap: Recap?
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
    @Published var rattrapage: Rattrapage?
    @Published var aClasserCourant: Detail?
    @Published var missions: [String: [String: String]] = [:]
    @Published var lissage = true
    @Published var domaines: [Domaine] = []
    /// Projets : la catégorie choisie dans la liste, son détail sur la période, et le temps de chaque catégorie sur la période.
    @Published var projetChoisi: String? { didSet { if projetChoisi != oldValue { detailProjet = nil; Task { await chargerProjet() } } } }
    @Published var detailProjet: DetailProjet?
    @Published var plagesSaisies: [PlageSaisie] = []
    @Published var secondesFenetre: [String: Double] = [:]
    @Published var frise: Frise?
    @Published var jourFrise = Calendar.current.startOfDay(for: Date()) {
        didSet { if !enLot && periodeFenetre == Etat.jourSeul && oldValue != jourFrise { Task { await chargerFenetre() } } }
    }
    /// Période libre de la fenêtre (periodeFenetre == Etat.datesLibres), jours entiers, fin comprise.
    @Published var debutLibre = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date()) {
        didSet { if !enLot && periodeFenetre == Etat.datesLibres { Task { await chargerFenetre() } } }
    }
    @Published var finLibre = Calendar.current.startOfDay(for: Date()) {
        didSet { if !enLot && periodeFenetre == Etat.datesLibres { Task { await chargerFenetre() } } }
    }
    static let jourSeul = 0, datesLibres = -1

    /// La période de la fenêtre en paramètres d'URL, et son nombre de jours.
    var requetePeriode: String {
        switch periodeFenetre {
        case Etat.jourSeul: "jour=\(jourFrise.timeIntervalSince1970)"
        case Etat.datesLibres: "debut=\(debutLibre.timeIntervalSince1970)&fin=\(finLibre.timeIntervalSince1970)"
        default: "jours=\(periodeFenetre)"
        }
    }
    var joursPeriode: Int {
        switch periodeFenetre {
        case Etat.jourSeul: 1
        case Etat.datesLibres: (Calendar.current.dateComponents([.day], from: Swift.min(debutLibre, finLibre), to: Swift.max(debutLibre, finLibre)).day ?? 0) + 1
        default: periodeFenetre + 1
        }
    }
    @Published var ecran: Ecran = .tableau
    @Published var travail: Double = 0
    @Published var aujourdhui: Double?
    @Published var depuis: Date?
    @Published var vif = false
    @Published var erreur: String?
    @Published var auDemarrage = SMAppService.mainApp.status == .enabled

    let moteur = Moteur()
    /// Numéro du dernier chargement de la fenêtre : une réponse plus ancienne n'écrase jamais une plus récente.
    var chargementFenetre = 0
    /// Ouvre la fenêtre principale (posé par la barre des menus, utilisé par les notifications).
    var ouvrirFenetre: (() -> Void)?

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--apercu"), i + 1 < CommandLine.arguments.count {
            Etat.apercu(self, vers: CommandLine.arguments[i + 1])
            return
        }
        moteur.demarrer()
        Task {
            let d = UserDefaults.standard
            if d.object(forKey: "rappelVendredi") as? Bool ?? true || d.object(forKey: "recapLundi") as? Bool ?? true { await autoriserNotifications() }
            try? await Task.sleep(for: .seconds(2))
            while true {
                await charger()
                await rappelVendredi()
                await recapLundi()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func lire(_ jours: Int, jour: Double? = nil, requete: String? = nil) async throws -> Reponse {
        let url = URL(string: "http://127.0.0.1:8230/api?" + (requete ?? jour.map { "jour=\($0)" } ?? "jours=\(jours)"))!
        let (d, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Reponse.self, from: d)
    }

    func charger() async {
        // une réponse pour une période que l'on a quittée entre-temps ne s'affiche pas
        let (periode, jour) = (jours, jourChoisi)
        do {
            let r = try await lire(periode, jour: jour)
            guard periode == jours, jour == jourChoisi else { return }
            erreur = r.erreur
            depuis = r.depuis.map { Date(timeIntervalSince1970: $0) }
            vif = r.dernier_releve.map { (r.maj ?? 0) - $0 < 60 } ?? false
            familles = r.familles ?? []
            categories = r.categories ?? []
            travail = r.travail ?? 0
            couleursChoisies = r.couleurs ?? [:]
            couleursPosees = Set(r.couleurs_posees ?? [])
            if let s = r.series { ordreSeries = s }
            missions = r.missions ?? [:]
            lissage = (r.lissage ?? 10) > 0
            if let d = r.domaines { domaines = d }
            histogramme = r.histogramme ?? []
            mois = r.mois ?? []
            reperes = r.reperes ?? []
            aujourdhui = jours == 0 && jourChoisi == nil ? travail : histogramme.last?.travail
        } catch {
            if periode == jours, jour == jourChoisi { erreur = L("Serveur injoignable sur le port 8230. Journal : ~/Library/Application Support/Temps/journal.log") }
        }
    }

    /// Un clic sur une barre de l'histogramme affiche ce jour-là ; sur aujourd'hui, revient à la vue du jour.
    /// Le jour d'avant ou d'après dans le panneau ; on ne dépasse pas aujourd'hui.
    func decalerJour(_ n: Int) {
        let cal = Calendar.current, aujourdhui = cal.startOfDay(for: Date())
        let base = jourChoisi.map { Date(timeIntervalSince1970: $0) } ?? aujourdhui
        guard let j = cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: base)) else { return }
        if jours != 0 { jours = 0 }
        jourChoisi = j >= aujourdhui ? nil : j.timeIntervalSince1970
        Task { await charger() }
    }

    /// Depuis l'histogramme du panneau : ouvrir ce jour-là (ruban), en revenant au mode jour.
    func ouvrirJour(_ j: Jour) {
        let auj = j.id == histogramme.last?.id
        if jours != 0 { jours = 0 }
        jourChoisi = auj ? nil : j.jour
        Task { await charger() }
    }

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
            if CommandLine.arguments.contains("--clair") { NSApp.appearance = NSAppearance(named: .aqua) }
            if CommandLine.arguments.contains("--semaine") { etat.jours = 6 }
            if CommandLine.arguments.contains("--mois") { etat.jours = 29 }
            await etat.charger()
            if CommandLine.arguments.contains("--hier"), etat.histogramme.count > 1 {
                etat.jourChoisi = etat.histogramme[etat.histogramme.count - 2].jour
                await etat.charger()
            }
            if let r = CommandLine.arguments.first(where: { $0.hasPrefix("--rubrique=") }) {
                await etat.chargerFenetre()
                let nom = String(r.dropFirst(11))
                if let p = CommandLine.arguments.first(where: { $0.hasPrefix("--projet=") }) { etat.projetChoisi = String(p.dropFirst(9)) }
                if CommandLine.arguments.contains("--classer"),
                   let d = etat.familles.first(where: { $0.nom == nonClasse })?.postes.first?.detail.first(where: { !$0.portees.isEmpty }) {
                    etat.classerFenetre = d
                }
                // --classer-dans=<nom> : l'écran Classer sur la première ligne d'une catégorie déjà rangée
                if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--classer-dans=") }) {
                    let nom = String(a.dropFirst(15))
                    if let poste = etat.familles.flatMap(\.postes).first(where: { $0.nom == nom || $0.cle == nom }),
                       var d = poste.detail.first(where: { !$0.contexte.isEmpty && $0.classable }) {
                        d.dans = poste.cle
                        etat.classerFenetre = d
                    }
                }
                let plage = nom == "plage"
                let vue = plage ? NSHostingView(rootView: AnyView(FormulairePlage {}.environmentObject(etat)))
                    : NSHostingView(rootView: AnyView(FenetrePrincipale(rubrique: Rubrique(rawValue: nom)).environmentObject(etat)))
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: plage ? 320 : 920, height: plage ? 400 : 620), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.contentView = vue
                w.appearance = NSAppearance(named: .darkAqua)
                if CommandLine.arguments.contains("--clair") { w.appearance = NSAppearance(named: .aqua) }
                w.orderFrontRegardless()
                w.center()
                _ = r
                try? await Task.sleep(for: .seconds(2))
                try? String(w.windowNumber).write(toFile: chemin, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(5))
                exit(0)
            }
            if CommandLine.arguments.contains("--classer"),
               let d = etat.familles.first(where: { $0.nom == nonClasse })?.postes.first?.detail.first(where: { !$0.portees.isEmpty }) {
                etat.ecran = .classer(d)
            }
            if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--classer-dans=") }),
               let poste = etat.familles.flatMap(\.postes).first(where: { $0.nom == String(a.dropFirst(15)) || $0.cle == String(a.dropFirst(15)) }),
               var d = poste.detail.first(where: { !$0.contexte.isEmpty && $0.classable }) {
                d.dans = poste.cle
                etat.ecran = .classer(d)
            }
            let vue = NSHostingView(rootView: Fenetre().environmentObject(etat))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: vue.intrinsicContentSize), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = vue
            w.appearance = NSAppearance(named: CommandLine.arguments.contains("--clair") ? .aqua : .darkAqua)
            w.backgroundColor = .windowBackgroundColor
            if CommandLine.arguments.contains("--clair") { w.appearance = NSAppearance(named: .aqua) }
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
            if let e = r.erreur { signaler(e); return }
            let (c, k) = annulation(r)
            let fait = Rangement(message: message, chemin: c, corps: k)
            withAnimation(mouvement(.snappy)) { rangement = fait }
            await rechargerTout()
            // la barre reste 8 s, sans retenir ce qui suit (une seconde écriture, une liste à relire)
            Task {
                try? await Task.sleep(for: .seconds(8))
                if rangement?.id == fait.id { withAnimation(mouvement(.snappy)) { rangement = nil } }
            }
        } catch {
            signaler(L("Modification non écrite : serveur injoignable sur le port 8230."))
        }
    }

    /// Une écriture refusée se lit là où l'on travaille : dans le panneau, et dans la fenêtre si elle est ouverte.
    func signaler(_ message: String) {
        erreur = message
        if fenetreOuverte { erreurFenetre = message }
    }

    /// Après une écriture ou son annulation : le panneau, puis la fenêtre et le ruban s'ils sont ouverts.
    func rechargerTout() async {
        await charger()
        guard fenetreOuverte else { return }
        await chargerFenetre()
        verifierFile()
        if frise != nil { await chargerFrise() }
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

    func classer(_ p: Portee, dans cle: String, enFile: Bool = false) async {
        let nom = categories.first { $0.cle == cle }?.nom ?? cle
        let (debut, fin) = bornesUneFois(dansFenetre: enFile || classerFenetre != nil)
        if enFile, let d = aClasserCourant {
            rattrapage?.faits += 1
            rattrapage?.ecartes.insert(d.id)
            suivant()
        } else {
            withAnimation(mouvement(.snappy)) { ecran = .tableau }
        }
        classerFenetre = nil
        if p.section == "creneau" {
            let b = p.motif.split(separator: "|").compactMap { Double($0) }
            if b.count == 2 {
                await ajouterPlage(debut: Date(timeIntervalSince1970: b[0]), fin: Date(timeIntervalSince1970: b[1]),
                                   cle: cle, note: "", force: true, message: L("Rangé dans %@", nom))
            }
        } else if p.section == "une-fois" {
            await ajouterPlage(debut: debut, fin: fin, cle: cle, note: p.motif, motif: p.motif, message: L("Rangé dans %@", nom))
        } else {
            await poser(p.section, p.motif, cle, message: L("Rangé dans %@", nom))
        }
    }

    /// La période d'où vient la ligne : celle de la fenêtre pour À classer, celle du panneau sinon.
    func bornesUneFois(dansFenetre: Bool) -> (Date, Date) {
        let cal = Calendar.current
        if dansFenetre {
            let (a, b) = bornesUnite
            return (cal.startOfDay(for: a), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: b))!)
        }
        if let j = jourChoisi {
            let a = cal.startOfDay(for: Date(timeIntervalSince1970: j))
            return (a, cal.date(byAdding: .day, value: 1, to: a)!)
        }
        return (depuis.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date()), Date())
    }

    /// Marque une source comme partagée : plus de règle, elle suit le projet autour d'elle.
    func marquerPartagee(_ d: Detail, enFile: Bool = false) async {
        if enFile {
            rattrapage?.faits += 1
            rattrapage?.ecartes.insert(d.id)
            suivant()
        } else {
            withAnimation(mouvement(.snappy)) { ecran = .tableau }
        }
        classerFenetre = nil
        await poser("partages", d.motifPartage, true, message: L("Source partagée : %@", d.motifPartage))
    }

    /// Les lignes non classées de la période de la fenêtre, classables, de la plus longue à la plus courte
    /// (refaite à chaque chargement de la fenêtre).
    @Published var aRattraper: [Detail] = []

    /// Ouvre la file sur une ligne (la plus longue par défaut).
    func rattraper(depuis d: Detail? = nil) {
        let file = aRattraper
        if rattrapage == nil { rattrapage = Rattrapage(total: file.count) }
        aClasserCourant = d ?? file.first { !(rattrapage?.ecartes.contains($0.id) ?? false) }
    }

    func passer() {
        guard let d = aClasserCourant else { return }
        rattrapage?.ecartes.insert(d.id)
        suivant()
    }

    /// La prochaine ligne de la file, ou rien quand elle est vide.
    func suivant() {
        let r = rattrapage ?? Rattrapage(total: aRattraper.count)
        withAnimation(mouvement(.snappy(duration: 0.18))) {
            aClasserCourant = aRattraper.first { !r.ecartes.contains($0.id) }
        }
        if aClasserCourant == nil { rattrapage = nil }
    }

    /// Après un rechargement : si la ligne affichée a été rangée par une règle plus large, on passe à la suivante.
    func verifierFile() {
        guard let d = aClasserCourant else { return }
        if !aRattraper.contains(where: { $0.id == d.id }) { suivant() }
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
            await rechargerTout()
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
            await rechargerTout()
        }
    }

    /// Accepte toutes les suggestions d'une liste, chacune avec sa première portée ; une seule annulation.
    func accepterSuggestions(_ details: [Detail]) async {
        let liste: [[String: Any]] = details.compactMap { d in
            guard let s = d.suggestion, let p = d.portees.first(where: { $0.section != "une-fois" }) else { return nil }
            return ["section": p.section, "motif": p.motif, "valeur": s]
        }
        guard !liste.isEmpty else { return }
        await modifier("lot", ["regles": liste], message: L("%d suggestions acceptées", liste.count)) { r in
            ("restaurer", ["texte": r.avant ?? ""])
        }
    }

    /// Missions d'un client : `[missions]` "client" = { "nom" = "AAAA-MM-JJ", … }.
    func ecrireMissions(_ client: String, _ table: [String: String], message: String) async {
        if table.isEmpty, let ancien = missions[client] {
            await retirer("missions", client, ancien: ancien, message: message)
        } else if !table.isEmpty {
            await poser("missions", client, table, message: message)
        }
    }

    /// Le projet d'une mission (« Projet / Mission ») et la clé de la mission dans sa table de dates.
    func projetDeMission(_ c: Categorie) -> (projet: String, cleTable: String)? {
        if let client = c.mission_de { return (client, c.cle.components(separatedBy: " · ").last ?? c.cle) }
        let (_, _, prefixe) = placer(c.nom, famille: c.famille)
        guard c.nom != prefixe, c.nom.hasPrefix(prefixe + " / ") else { return nil }
        return (categories.first { $0.nom == prefixe }?.cle ?? prefixe, c.cle)
    }

    /// La date de départ d'une mission, si elle en a une.
    func debutMission(_ c: Categorie) -> Date? {
        guard let (p, k) = projetDeMission(c) else { return nil }
        return missions[p]?[k].flatMap { EcranOrganiser.jour.date(from: $0) }
    }

    /// Pose (ou retire, avec nil) la date de départ d'une mission : dès ce jour, le temps du projet va à elle.
    func dater(_ c: Categorie, _ debut: Date?) async {
        guard let (p, k) = projetDeMission(c) else { return }
        var t = missions[p] ?? [:]
        t[k] = debut.map { EcranOrganiser.jour.string(from: $0) }
        let nom = c.nom.components(separatedBy: " / ").last ?? c.nom
        await ecrireMissions(p, t, message: debut.map { L("« %@ » démarre le %@", nom, $0.formatted(.dateTime.day().month(.abbreviated))) }
                             ?? L("« %@ » n'a plus de date de départ", nom))
    }

    /// Fusionne une catégorie dans une autre : tout son temps (dossier, règles, historique) y passe, et elle disparaît.
    func fusionner(_ c: Categorie, dans cible: String) async {
        let nom = categories.first { $0.cle == cible }?.nom ?? cible
        if projetChoisi == c.cle { projetChoisi = cible }
        await poser("fusions", c.cle, cible, message: L("« %@ » fusionné dans %@", c.nom, nom))
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
        withAnimation(mouvement(.snappy)) { rangement = nil }
        _ = try? await envoyer(r.chemin, r.corps)
        await rechargerTout()
        if r.chemin.hasPrefix("manuel") { await chargerSaisies() }
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
                Capsule().fill(Color.fondPastille)
                Capsule().fill(teinte.opacity(opacite))
                    .frame(width: max(3, g.size.width * min(1, part)))
            }
        }
        .frame(height: 4)
        .animation(mouvement(.easeOut(duration: 0.2)), value: part)
    }
}

struct Carte<Contenu: View>: View {
    @ViewBuilder let contenu: Contenu
    @Environment(\.dansFenetre) private var dansFenetre
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { contenu }
            .padding(.vertical, 12).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // dans la fenêtre translucide : une plaque de verre ; dans le panneau (déjà en verre) : un voile léger
                if dansFenetre {
                    RoundedRectangle(cornerRadius: 12).fill(Color.voile)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color.voile)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(dansFenetre ? 0.06 : 0.07)))
    }
}

/// Le fond de la fenêtre : le bureau flouté derrière, comme les barres latérales de macOS.
struct VerreDeFenetre: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Etiquette: View {
    let texte: String
    var compte: Int? = nil
    var droite: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(L(texte)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.texteDiscret)
            if let c = compte { Text("\(c)").font(.system(size: 11)).foregroundStyle(Color.texteDiscret) }
            Spacer()
            if let d = droite { Text(d).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.texteDiscret) }
        }
        .padding(.horizontal, 8).padding(.bottom, 2)
    }
}

// MARK: - Tableau

/// Les 7 derniers jours. Un clic affiche le jour ; la barre choisie est pleine.
struct Histogramme: View {
    @EnvironmentObject var etat: Etat
    var hauteur: CGFloat = 38
    /// Un clic sur un jour ; par défaut, le choisir.
    var ouvrir: ((Jour) -> Void)? = nil
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
                Button { if let o = ouvrir { o(j) } else { withAnimation(mouvement(.snappy(duration: 0.2))) { etat.choisirJour(j) } } } label: {
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.voile).frame(height: hauteur)
                        BarreEmpilee(parts: j.parts ?? [:], hauteur: hauteur, max: max)
                            .opacity(!unJour || choisi(j) ? 1 : 0.35)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(choisi(j) && unJour ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                    Text(Histogramme.initiales[jour])
                        .font(.system(size: 10, weight: aujourdhui || choisi(j) ? .semibold : .regular))
                        .foregroundStyle(aujourdhui ? AnyShapeStyle(Color.lien) : (choisi(j) ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.texteDiscret)))
                }
                .frame(maxWidth: .infinity)
                .padding(2)
                .contentShape(Rectangle())
                }
                .buttonStyle(StyleTouche(forme: .rectangle(Rayon.petit)))
                .help(detailParts(j))
                .accessibilityLabel(detailParts(j))
            }
        }
        .animation(mouvement(.easeOut(duration: 0.2)), value: etat.histogramme.map(\.travail))
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
                    .foregroundStyle(depasse ? AnyShapeStyle(Color.signal) : AnyShapeStyle(Color.texteDiscret))
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
    var dans: String? = nil
    @State private var survol = false

    var classable: Bool { d.classable }

    var body: some View {
        HStack(spacing: 6) {
            if d.appareil != "Mac" {
                Image(systemName: iconeAppareil(d.appareil)).font(.system(size: 10)).foregroundStyle(Color.texteDiscret)
            }
            Text(d.contexte.isEmpty ? d.nomApp : d.contexte).lineLimit(1).truncationMode(.middle)
            if !d.contexte.isEmpty && !d.app.isEmpty {
                Text(d.nomApp).lineLimit(1).foregroundStyle(Color.texteDiscret).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if survol && classable {
                Text("Classer").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.lien)
            } else if d.suggestion != nil {
                Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.lien.opacity(0.8))
                Text(duree(d.secondes)).monospacedDigit().foregroundStyle(Color.texteDiscret)
            } else {
                Text(duree(d.secondes)).monospacedDigit().foregroundStyle(Color.texteDiscret)
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(survol && classable ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture {
            guard classable else { return }
            var x = d
            x.dans = dans
            if dansFenetre { etat.classerFenetre = x } else { withAnimation(mouvement(.snappy(duration: 0.2))) { etat.ecran = .classer(x) } }
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
                    activer()
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
    @State private var survol = false
    @Environment(\.dansFenetre) private var dansFenetre

    /// Déplié ou non, et « tout afficher » : gardés dans l'état, pour les retrouver au retour de Classer.
    var cleDepli: String { (dansFenetre ? "f:" : "p:") + poste.cle }
    var ouvert: Bool {
        get { etat.deplies.contains(cleDepli) || CommandLine.arguments.contains("--deplier=\(poste.nom)") }
        nonmutating set { if newValue { etat.deplies.insert(cleDepli) } else { etat.deplies.remove(cleDepli) } }
    }
    var tout: Bool {
        get { etat.deplies.contains("tout:" + cleDepli) }
        nonmutating set { if newValue { etat.deplies.insert("tout:" + cleDepli) } else { etat.deplies.remove("tout:" + cleDepli) } }
    }

    var renommable: Bool { ![nonClasse, "autres", "hors"].contains(poste.cle) }

    /// La barre à la teinte d'une série (le nom, lui, reste en couleur de texte).
    var barre: Color? = nil

    init(poste: Poste, max: Double, teinte: Color = .primary, discret: Bool = false, affiche: String? = nil, pastille: Color? = nil, barre: Color? = nil) {
        self.barre = barre
        self.poste = poste
        self.max = max
        self.teinte = teinte
        self.discret = discret
        self.affiche = affiche
        self.pastille = pastille
    }

    var body: some View {
        VStack(alignment: .leading, spacing: discret ? 4 : 5) {
            HStack(spacing: 5) {
                if let p = pastille { Circle().fill(p).frame(width: 7, height: 7) }
                NomModifiable(cle: poste.cle, nom: poste.nom, affiche: affiche ?? (renommable ? nil : L(poste.nom)), actif: renommable,
                              style: teinte == .primary ? AnyShapeStyle(discret ? Color.texteDiscret : Color.primary) : AnyShapeStyle(teinte))
                if !poste.detail.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.texteDiscret)
                        .rotationEffect(.degrees(ouvert ? 90 : 0))
                }
                Spacer()
                Text(duree(poste.secondes)).monospacedDigit().foregroundStyle(Color.texteDiscret)
            }
            Barre(part: poste.secondes / max, teinte: barre ?? teinte, opacite: barre != nil ? 0.85 : teinte == .primary ? (discret ? 0.35 : 0.72) : 0.85)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(survol && !poste.detail.isEmpty ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture { withAnimation(mouvement(.easeOut(duration: 0.16))) { ouvert.toggle() } }

        if ouvert {
            VStack(spacing: 4) {
                let suggerees = poste.detail.filter { $0.suggestion != nil && $0.classable && $0.partage != true }
                if poste.cle == nonClasse && suggerees.count > 1 {
                    LigneChoix(texte: L("Accepter les %d suggestions", suggerees.count), icone: "sparkle", mis_en_avant: true) {
                        Task { await etat.accepterSuggestions(suggerees) }
                    }
                    .help(suggerees.map { "\($0.contexte) → \($0.suggestion!)" }.joined(separator: "\n"))
                    .padding(.bottom, 2)
                }
                let limite = tout ? poste.detail.count : 12
                ForEach(poste.detail.prefix(limite)) { LigneDetail(d: $0, dans: poste.cle) }
                if poste.detail.count > 12 {
                    Button(tout ? L("Réduire") : L("Tout afficher (%d)", poste.detail.count)) {
                        withAnimation(mouvement(.easeOut(duration: 0.16))) { tout.toggle() }
                    }
                    .buttonStyle(StyleLien()).font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 2)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.texteDiscret)
            .padding(.leading, 12).padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(Color.survol).frame(width: 1) }
            .padding(.leading, 12).padding(.trailing, 8).padding(.bottom, 8)
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
                    Text(groupe).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(discret ? Color.texteDiscret : Color.primary)
                    Spacer()
                    Text(duree(total)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.texteDiscret)
                }
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(g.items) { p in
                        LignePoste(poste: p, max: max, discret: true, affiche: feuille(p.nom),
                                   pastille: couleursChoisies[p.cle] != nil ? couleurSerie(p.cle) : nil)
                    }
                }
                .padding(.leading, 24)
            } else {
                ForEach(g.items) { LignePoste(poste: $0, max: max, discret: discret, pastille: pastille($0)) }
            }
        }
    }
}

/// Le temps non classé, à part et en tête : c'est le seul endroit où il y a quelque chose à faire.
struct CarteNonClasse: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.dansFenetre) private var dansFenetre
    let poste: Poste
    let max: Double
    let classer: () -> Void

    var premieres: [Detail] { Array(poste.detail.filter(\.classable).prefix(3)) }

    var body: some View {
        Carte {
            HStack {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text(L(nonClasse)).foregroundStyle(Color.signal)
                Spacer()
                Text(duree(poste.secondes)).monospacedDigit().foregroundStyle(Color.signal)
            }
            .font(.corps)
            .padding(.vertical, 4).padding(.horizontal, 8)
            ForEach(Array(premieres.enumerated()), id: \.1.id) { i, d in
                LigneSuggeree(d: d, premiere: i == 0)
            }
            if poste.detail.count > premieres.count || !dansFenetre {
                Button(L("Classer une à une (%d)", poste.detail.count), action: classer)
                    .buttonStyle(StyleLien()).font(.secondaire)
                    .padding(.horizontal, 4).padding(.top, 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bordSignal))
    }
}

/// Une source non classée : un clic ouvre Classer ; sa suggestion s'accepte sur place (↵ pour la première).
struct LigneSuggeree: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.dansFenetre) private var dansFenetre
    let d: Detail
    var premiere = false

    /// « Dupont », et son domaine à part : jamais « Studio / Dupont ».
    var nomSuggestion: (nom: String, domaine: String?)? {
        guard let s = d.suggestion else { return nil }
        let c = etat.categories.first { $0.cle == s }
        let (dom, nom, _) = etat.placer(c?.nom ?? s, famille: c?.famille ?? projets)
        let court = (c?.nom ?? s).hasPrefix(dom + " / ") ? String((c?.nom ?? s).dropFirst(dom.count + 3)) : (c?.nom ?? nom)
        return (court, court == dom ? nil : dom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if dansFenetre { etat.classerFenetre = d } else { withAnimation(mouvement(.snappy(duration: 0.18))) { etat.ecran = .classer(d) } }
            } label: {
                HStack {
                    Text(d.contexte.isEmpty ? d.nomApp : d.contexte).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(duree(d.secondes)).font(.secondaire).monospacedDigit().foregroundStyle(Color.texteDiscret)
                }
                .font(.corps)
            }
            .buttonStyle(StyleLigne())
            if let s = d.suggestion, let nom = nomSuggestion, let p = d.portees.first {
                let accepter = Button { Task { await etat.classer(p, dans: s) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.legende)
                        Text(nom.nom).lineLimit(1)
                        if let dom = nom.domaine { Text(dom).foregroundStyle(Color.texteDiscret).lineLimit(1) }
                        Spacer(minLength: 8)
                        if premiere { Image(systemName: "return").font(.legende).foregroundStyle(Color.texteDiscret) }
                    }
                    .font(.secondaire)
                    .foregroundStyle(Color.lien)
                    .padding(.leading, 12)
                }
                .buttonStyle(StyleLigne())
                .help(d.raison ?? "")
                if premiere { accepter.keyboardShortcut(.defaultAction) } else { accepter }
            }
        }
    }
}

// MARK: - Classer

struct BoutonRetour: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        Button { etat.classerFenetre = nil; withAnimation(mouvement(.snappy(duration: 0.2))) { etat.ecran = .tableau } } label: {
            Label("Retour", systemImage: "chevron.left").font(.system(size: 13))
        }
        .buttonStyle(StyleLien(couleur: Color.texteDiscret))
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
            if survol { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Color.texteDiscret) }
        }
        .font(.system(size: 13))
        .foregroundStyle(icone == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lien))
        .padding(.vertical, 4).padding(.horizontal, 8)
        .padding(.leading, retrait ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            mis_en_avant ? Color.accentColor.opacity(survol ? 0.22 : 0.14) : Color.primary.opacity(survol ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture(perform: action)
    }
}

/// Des étiquettes qui passent à la ligne quand la place manque.
struct Rangs: Layout {
    var espace: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (_, taille) = placer(largeur: proposal.width ?? .infinity, subviews)
        return taille
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (points, _) = placer(largeur: bounds.width, subviews)
        for (v, pt) in zip(subviews, points) {
            v.place(at: CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y), proposal: .unspecified)
        }
    }
    private func placer(largeur: CGFloat, _ subviews: Subviews) -> ([CGPoint], CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, ligne: CGFloat = 0, large: CGFloat = 0
        for v in subviews {
            let t = v.sizeThatFits(.unspecified)
            if x > 0, x + t.width > largeur { x = 0; y += ligne + espace; ligne = 0 }
            points.append(CGPoint(x: x, y: y))
            x += t.width + espace
            ligne = max(ligne, t.height)
            large = max(large, x - espace)
        }
        return (points, CGSize(width: min(large, largeur), height: y + ligne))
    }
}

/// Le détail d'une ligne sur la période : titres de fenêtre, adresses ou chemins, moments (`GET /source`).
struct InfosSource: Decodable {
    struct Ligne: Decodable, Hashable { let texte: String; let secondes: Double }
    struct Moment: Decodable, Hashable { let jour: Double; let debut: Double; let fin: Double }
    let titres: [Ligne]
    let adresses: [Ligne]
    let moments: [Moment]
}

extension Etat {
    func lireSource(_ d: Detail, dansFenetre: Bool) async -> InfosSource? {
        var (debut, fin) = bornesUneFois(dansFenetre: dansFenetre)
        if let c = d.creneau, c.count == 2 { (debut, fin) = (Date(timeIntervalSince1970: c[0]), Date(timeIntervalSince1970: c[1])) }
        var u = URLComponents(string: "http://127.0.0.1:8230/source")!
        u.queryItems = [.init(name: "appareil", value: d.appareil), .init(name: "app", value: d.app),
                        .init(name: "contexte", value: d.contexte),
                        .init(name: "debut", value: String(debut.timeIntervalSince1970)),
                        .init(name: "fin", value: String(fin.timeIntervalSince1970))]
        guard let url = u.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(InfosSource.self, from: data)
    }
}

struct VueInfosSource: View {
    let infos: InfosSource?

    /// Les moments regroupés par jour : « mar. 24 nov. » → « 10:40–10:50 · 16:05–16:15 ».
    func parJour(_ m: [InfosSource.Moment]) -> [(String, String)] {
        let jours = Dictionary(grouping: m, by: \.jour).sorted { $0.key > $1.key }
        return jours.map { j, ms in
            (formatJourCourt.string(from: Date(timeIntervalSince1970: ms[0].debut)),
             ms.sorted { $0.debut < $1.debut }.map {
                 "\(formatHeureCourte.string(from: Date(timeIntervalSince1970: $0.debut)))–\(formatHeureCourte.string(from: Date(timeIntervalSince1970: $0.fin)))"
             }.joined(separator: " · "))
        }
    }

    func etiquette(_ t: String) -> some View {
        Text(L(t)).font(.system(size: 11)).foregroundStyle(Color.texteDiscret).gridColumnAlignment(.leading)
    }

    var body: some View {
        if let i = infos {
            let jours = parJour(i.moments)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                if !i.titres.isEmpty {
                    GridRow {
                        etiquette("Fenêtres")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(i.titres.prefix(4), id: \.self) { t in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(t.texte).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(duree(t.secondes)).monospacedDigit().foregroundStyle(Color.texteDiscret)
                                }
                            }
                        }
                    }
                }
                if let a = i.adresses.first {
                    GridRow {
                        etiquette(a.texte.hasPrefix("/") ? "Fichier" : "Adresse")
                        Text(a.texte).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Color.texteDiscret).textSelection(.enabled)
                            .help(i.adresses.map(\.texte).joined(separator: "\n"))
                    }
                }
                if !jours.isEmpty {
                    GridRow {
                        etiquette("Quand")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(jours.prefix(4), id: \.0) { j, h in
                                (Text(j).foregroundStyle(.primary) + Text("  " + h).foregroundStyle(Color.texteDiscret))
                                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                            }
                            if jours.count > 4 {
                                Text(L("et %d autres jours", jours.count - 4)).foregroundStyle(Color.texteDiscret)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Classer une ligne : d'abord ce qu'on range et sa portée, puis où on le range.
struct EcranClasser: View {
    @EnvironmentObject var etat: Etat
    let d: Detail
    var enFile = false
    @State private var infos: InfosSource?
    @State private var portee: Portee?
    @State private var recherche = ""
    @FocusState private var focus: Bool

    var trouvees: [Categorie] {
        let q = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        // le client (la date choisit la mission) comme ses missions (pour forcer une mission précise)
        return q.isEmpty ? etat.categories.filter { !$0.archivee } : etat.categories.filter { $0.nom.lowercased().contains(q) || $0.cle.lowercased().contains(q) }
    }

    var nouveau: String? {
        let q = recherche.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || etat.categories.contains { $0.nom.lowercased() == q.lowercased() } ? nil : q
    }

    var suggeree: Categorie? { d.suggestion.flatMap { s in etat.categories.first { $0.cle == s } } }

    func choisir(_ cle: String) {
        guard let p = portee ?? d.portees.first else { return }
        Task { await etat.classer(p, dans: cle, enFile: enFile) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !enFile { BoutonRetour() }
                Spacer()
                if enFile, let r = etat.rattrapage {
                    Text("\(min(r.ecartes.count + 1, r.total)) / \(r.total)").monospacedDigit()
                        .font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
                    Button { etat.passer() } label: {
                        Label("Passer", systemImage: "chevron.right").labelStyle(.titleAndIcon).font(.system(size: 13))
                    }
                    .buttonStyle(StyleLien(couleur: Color.texteDiscret))
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("⌘→")
                }
            }

            // 1. Ce qu'on range
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.contexte.isEmpty ? d.nomApp : d.contexte)
                        .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text([d.contexte.isEmpty ? nil : d.nomApp, d.appareil == "Mac" ? nil : d.appareil, duree(d.secondes)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
                    if d.dejaRangee, let cle = d.dans {
                        Label(L("Rangé dans %@", etat.categories.first { $0.cle == cle }?.nom ?? cle), systemImage: "folder")
                            .font(.system(size: 11)).foregroundStyle(Color.texteDiscret).padding(.top, 4)
                    }
                }
                Rangs(espace: 6) {
                    ForEach(d.portees) { p in
                        let choisie = (portee ?? d.portees.first)?.id == p.id
                        Button { withAnimation(mouvement(.snappy(duration: 0.15))) { portee = p } } label: { Text(p.libelle).lineLimit(1) }
                            .buttonStyle(StylePastille(choisie: choisie))
                            .help(p.motif)
                    }
                }
                if d.partage != true, !d.contexte.isEmpty {
                    Button { Task { await etat.marquerPartagee(d, enFile: enFile) } } label: {
                        Label(L("Source partagée entre projets"), systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StyleLien()).font(.system(size: 11))
                    .help(d.motifPartage)
                }
                if d.app != "manuel" && !d.app.isEmpty {
                    Divider().padding(.vertical, 2)
                    VueInfosSource(infos: infos)
                }
            }
            .task(id: d.id) {
                guard d.app != "manuel" && !d.app.isEmpty else { return }
                infos = nil
                infos = await etat.lireSource(d, dansFenetre: enFile || etat.classerFenetre != nil)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.survol))

            // 2. Où le ranger
            VStack(alignment: .leading, spacing: 6) {
                Text("Ranger dans").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.texteDiscret)
                    .padding(.horizontal, 2)
                TextField("Chercher ou créer un projet", text: $recherche)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus)
                    .onSubmit {
                        if recherche.trimmingCharacters(in: .whitespaces).isEmpty { if let s = suggeree { choisir(s.cle) } }
                        else if let n = nouveau, trouvees.isEmpty { choisir(n) } else if let c = trouvees.first { choisir(c.cle) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    if let s = suggeree, recherche.isEmpty {
                        LigneChoix(texte: s.groupe.map { "\(s.feuille) · \($0)" } ?? s.nom, icone: "sparkle", mis_en_avant: true) { choisir(s.cle) }
                        if let r = d.raison {
                            Text(r).font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
                                .lineLimit(2).padding(.horizontal, 8).padding(.top, 2)
                        }
                        Spacer().frame(height: 4)
                    }
                    if let n = nouveau {
                        LigneChoix(texte: L("Créer « %@ »", n), icone: "plus") { choisir(n) }
                    }
                    ForEach([projets, activites, horsTravail], id: \.self) { f in
                        let cats = trouvees.filter { $0.famille == f }
                        if !cats.isEmpty {
                            Text(L(f)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.texteDiscret)
                                .padding(.top, 8).padding(.horizontal, 8)
                            ForEach(Array(grouper(Array(cats)) { $0.nom }.enumerated()), id: \.offset) { _, g in
                                if let groupe = g.groupe {
                                    Text(groupe).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.texteDiscret)
                                        .padding(.horizontal, 8).padding(.top, 4)
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
            activer()
            focus = true
        }
        .onChange(of: d.id) {
            portee = d.portees.first
            recherche = ""
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
            .touchable(rayon: Rayon.grand)
            .onTapGesture { Task { await etat.choisirCouleur(cle, teinte: valeur) } }
            .help(aide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titre).font(.system(size: 13, weight: .semibold))
            let grille = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8)
            if let g = groupe {
                Text(L("Nuances de %@", g)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.texteDiscret)
                LazyVGrid(columns: grille, spacing: 8) {
                    ForEach(nuances(de: couleurSerie(g)), id: \.self) { pastille($0, aide: $0) }
                }
                Text("Toutes les teintes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.texteDiscret)
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
                        .buttonStyle(StyleLien(couleur: Color.texteDiscret))
                }
            }
            .font(.system(size: 13))
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { libre = couleurSerie(couleursChoisies[cle] != nil ? cle : (groupe ?? cle)) }
    }
}

/// La liste de la page Projets : Domaine › Projet › Mission. Glisser un projet sur un domaine, une catégorie sur
/// un projet pour en faire une mission ; clic droit pour renommer, ranger, dater, archiver, fusionner ou supprimer.
struct EcranOrganiser: View {
    @EnvironmentObject var etat: Etat
    @State private var cible: String?
    @State private var nouvelles: [String: String] = [:]
    @State private var couleurOuverte: String?
    @State private var archivesOuvertes = false
    @State private var saisie: String?
    @State private var fusionDe: String?
    @State private var renommeDomaine: String?
    @State private var renommeBranche: String?
    @State private var dateOuverte: String?
    /// Projets dont les missions sont repliées, gardés d'une ouverture à l'autre.
    @AppStorage("temps.projetsReplies") private var repliesTexte = ""
    var replies: Set<String> { Set(repliesTexte.split(separator: "\n").map(String.init)) }
    func basculer(_ prefixe: String) {
        var r = replies
        if r.contains(prefixe) { r.remove(prefixe) } else { r.insert(prefixe) }
        repliesTexte = r.sorted().joined(separator: "\n")
    }
    @FocusState private var champ: Bool

    func trouver(_ cle: String) -> Categorie? { etat.categories.first { $0.cle == cle } }

    /// Heures, sans rien pour zéro : une colonne vide se lit mieux qu'une colonne de « 0,0 h ».
    func heuresOuRien(_ s: Double?) -> String { (s ?? 0) >= 180 ? heures(s!) : "" }

    var groupes: [String] {
        Array(Set(etat.categories.compactMap(\.groupe))).sorted()
    }

    /// Pastille qui ouvre le choix de couleur. Sur un en-tête de groupe : la couleur du groupe.
    /// Sur un sous-projet : sa couleur propre, ou celle du groupe tant qu'il n'en a pas.
    /// Hors projets, un emplacement vide garde les noms alignés.
    func pastille(cle: String, titre: String, groupe: String?, couleur: Color, famille f: String) -> some View {
        Group {
            if f == projets && groupe != nil {
                Circle().fill(couleur).frame(width: 8, height: 8)
            } else if f == projets {
                Circle().fill(couleur)
                    .frame(width: 8, height: 8)
                    .padding(4).touchable(rayon: Rayon.petit).padding(-4)
                    .onTapGesture { couleurOuverte = cle }
                    .accessibilityLabel(L("Couleur…"))
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

    /// Dans la liste de la fenêtre : le temps de la période et, s'il y a un devis, l'écart en couleur.
    @ViewBuilder func resumeListe(_ c: Categorie) -> some View {
        HStack(spacing: 8) {
            if let f = etat.fiches.first(where: { $0.cle == c.cle }), let v = f.vendu {
                let ecart = f.total / 3600 - v
                Text(ecart > 0 ? "+\(heures(ecart * 3600))" : "−\(heures(-ecart * 3600))")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ecart > 0 ? Color.signal : Color.texteDiscret)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill((ecart > 0 ? Color.orange : Color.primary).opacity(0.12)))
            }
            Text(heuresOuRien(etat.secondesFenetre[c.cle])).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.texteDiscret)
                .frame(width: 52, alignment: .trailing)
        }
    }


    /// Sur une mission datée : « depuis le … », un clic change la date. Le même choix s'ouvre depuis le clic droit.
    @ViewBuilder func dateDeMission(_ c: Categorie) -> some View {
        let debut = etat.debutMission(c)
        Group {
            if let debut {
                Button { dateOuverte = c.cle } label: {
                    Text(L("depuis le %@", debut.formatted(.dateTime.day().month(.abbreviated))))
                        .font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(dateOuverte == c.cle ? 0.12 : 0.06)))
                }
                .buttonStyle(StyleTouche(forme: .capsule))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .popover(isPresented: Binding(get: { dateOuverte == c.cle }, set: { if !$0 { dateOuverte = nil } }), arrowEdge: .bottom) {
            DatePicker("", selection: Binding(get: { debut ?? Date() }, set: { d in
                dateOuverte = nil
                Task { await etat.dater(c, d) }
            }), displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(12)
        }
    }

    static let jour: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

    func ligne(_ c: Categorie, retrait: Bool, niveau: Int = 0) -> some View {
        let g = groupeCouleur(cle: c.cle, nom: c.nom)
        return AvecSurvol { survol in HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Color.texteDiscret).frame(width: 10)
                .opacity(survol ? 1 : 0)
            pastille(cle: retrait ? c.cle : g, titre: retrait ? c.nom : g, groupe: retrait ? g : nil,
                     couleur: couleurSerie(serie(cle: c.cle, nom: c.nom, famille: c.famille)), famille: c.famille)
            NomModifiable(cle: c.cle, nom: c.nom, affiche: retrait ? (c.nom.components(separatedBy: " / ").last ?? c.nom) : c.nom)
                .opacity(c.archivee ? 0.55 : 1)
                .font(.system(size: 13))
            if niveau >= 2 { dateDeMission(c) }
            Spacer()
            resumeListe(c)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 12)
        .padding(.leading, retrait ? 14 + CGFloat(Swift.max(niveau - 1, 0)) * 18 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(cible == c.cle ? Color.selection
            : etat.projetChoisi == c.cle ? Color.selection : Color.primary.opacity(survol ? 0.05 : 0)))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { etat.projetChoisi = c.cle })
        .popover(isPresented: Binding(get: { fusionDe == c.cle }, set: { if !$0 { fusionDe = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Fusionner « %@ » dans…", c.nom)).font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 12)
                ChoixCategorie { cible in
                    fusionDe = nil
                    guard cible != c.cle else { return }
                    Task { await etat.fusionner(c, dans: cible) }
                }
            }
            .environmentObject(etat)
        }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cible == c.cle ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .draggable(c.cle) {
            Text(c.nom).font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
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
                if !retrait { Button("Couleur…") { couleurOuverte = g } }
                if etat.projetDeMission(c) != nil {
                    if etat.debutMission(c) == nil {
                        Button(L("Démarrer à une date…")) { dateOuverte = c.cle }
                    } else {
                        Button(L("Changer la date de départ…")) { dateOuverte = c.cle }
                        Button(L("Retirer la date")) { Task { await etat.dater(c, nil) } }
                    }
                }
                if c.archivee {
                    Button("Désarchiver") { Task { await etat.retirer("archives", c.cle, ancien: true, message: L("« %@ » ressorti des archives", c.nom)) } }
                } else {
                    Button("Archiver") { Task { await etat.poser("archives", c.cle, true, message: L("« %@ » archivé", c.nom)) } }
                }
            }
            Divider()
            Button(L("Fusionner dans…")) { fusionDe = c.cle }
            Button("Supprimer", role: .destructive) { Task { await etat.supprimer(c) } }
        }
    }

    var body: some View {
        corpsFenetre
    }

    /// Dans la fenêtre : Domaine › Projet › Mission, en une seule liste construite au fil du défilement.
    /// Tout se crée, se renomme, se glisse et se supprime sur place.
    /// Une rangée de la liste : la zone de son domaine se dessine rangée par rangée, pour que la liste reste paresseuse.
    enum Rangee: Identifiable {
        case entete(NoeudDomaine, Int)
        case projet(NoeudProjet, NoeudDomaine)
        case champMission(NoeudProjet, NoeudDomaine)
        case mission(Categorie, NoeudDomaine)
        case vide(NoeudDomaine)
        case nouveauProjet(NoeudDomaine)
        var id: String {
            switch self {
            case .entete(let n, _): "d:" + n.id
            case .projet(let p, let n): "p:" + n.id + ":" + p.id
            case .champMission(let p, _): "cm:" + p.id
            case .mission(let c, let n): "m:" + n.id + ":" + c.cle
            case .vide(let n): "v:" + n.id
            case .nouveauProjet(let n): "np:" + n.id
            }
        }
    }

    func rangees(_ arbre: [NoeudDomaine]) -> [(Rangee, haut: Bool, bas: Bool)] {
        var out: [(Rangee, haut: Bool, bas: Bool)] = []
        let r = replies
        for (i, n) in arbre.enumerated() {
            var l: [Rangee] = [.entete(n, i)]
            for p in n.projets {
                l.append(.projet(p, n))
                if saisie == "mission:" + p.prefixe { l.append(.champMission(p, n)) }
                if p.seul == nil && !r.contains(p.prefixe) {
                    l += p.cats.filter { $0.nom != p.prefixe }.map { .mission($0, n) }
                }
            }
            if n.projets.isEmpty { l.append(.vide(n)) }
            l.append(.nouveauProjet(n))
            out += l.enumerated().map { ($0.element, haut: $0.offset == 0, bas: $0.offset == l.count - 1) }
        }
        return out
    }

    @ViewBuilder func vue(_ r: Rangee) -> some View {
        switch r {
        case .entete(let n, let i): enteteDomaine(n, rang: i, total: etat.domaines.count)
        case .projet(let p, let n): ligneProjet(p, domaine: n)
        case .champMission(let p, let n):
            champ(L("Nom de la mission")) { t in Task { await etat.creer("\(p.prefixe) / \(t)", famille: n.domaine.famille) } }
                .padding(.leading, 32)
        case .mission(let c, _): ligne(c, retrait: true, niveau: 2)
        case .vide:
            Text("Glisse un projet ici.").font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
                .padding(.horizontal, 32).padding(.vertical, 4)
        case .nouveauProjet(let n):
            if saisie == "projet:" + n.domaine.nom {
                champ(L("Nom du projet")) { t in Task { await etat.creerProjet(t, dans: n.domaine) } }.padding(.leading, 24)
            } else {
                boutonAjout(L("Nouveau projet")) { saisie = "projet:" + n.domaine.nom }.padding(.leading, 32)
            }
        }
    }

    /// « + Nouveau … » en bas d'une liste : discret, en couleur d'accent.
    func boutonAjout(_ texte: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(texte, systemImage: "plus").font(.system(size: 13, weight: .medium))
                .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(StyleLien())
    }

    /// Dans la fenêtre : Domaine › Projet › Mission, en une seule liste construite au fil du défilement.
    /// Tout se crée, se renomme, se glisse et se supprime sur place.
    var corpsFenetre: some View {
        let arbre = etat.arbre
        let archivees = etat.categories.filter(\.archivee).sorted { $0.nom.lowercased() < $1.nom.lowercased() }
        let fond = Color.voile
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Etiquette(texte: "Domaines", compte: arbre.count)
                    .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                ForEach(rangees(arbre), id: \.0.id) { r, haut, bas in
                    vue(r)
                        .padding(.horizontal, 4).padding(.top, haut ? 8 : 0).padding(.bottom, bas ? 8 : 0)
                        .background(UnevenRoundedRectangle(topLeadingRadius: haut ? 12 : 0, bottomLeadingRadius: bas ? 12 : 0,
                                                           bottomTrailingRadius: bas ? 12 : 0, topTrailingRadius: haut ? 12 : 0).fill(fond))
                        .padding(.top, haut ? 12 : 0)
                }
                Group {
                    if saisie == "domaine" {
                        champ(L("Nom du domaine")) { n in Task { await etat.creerDomaine(n) } }
                    } else {
                        boutonAjout(L("Nouveau domaine")) { saisie = "domaine" }.padding(.horizontal, 12)
                    }
                }
                .padding(.top, 12)
                if !archivees.isEmpty {
                    Divider().padding(.horizontal, 12).padding(.top, 12)
                    Button {
                        withAnimation(mouvement(.easeOut(duration: 0.16))) { archivesOuvertes.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "archivebox").font(.system(size: 11))
                            Text("Archivés").font(.system(size: 11, weight: .semibold))
                            Text("\(archivees.count)").font(.system(size: 10)).monospacedDigit()
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(archivesOuvertes ? 90 : 0))
                        }
                        .foregroundStyle(Color.texteDiscret)
                        .padding(.vertical, 4).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StyleTouche())
                    .padding(.top, 8)
                    if archivesOuvertes {
                        ForEach(archivees) { ligne($0, retrait: false).opacity(0.7) }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
    }

    /// Un champ de saisie sous un en-tête : Entrée valide, Échap renonce.
    func champ(_ invite: String, valider: @escaping (String) -> Void) -> some View {
        TextField(invite, text: Binding(get: { nouvelles["_"] ?? "" }, set: { nouvelles["_"] = $0 }))
            .textFieldStyle(.roundedBorder).focused($champ)
            .onAppear { nouvelles["_"] = ""; champ = true }
            .onSubmit {
                let t = (nouvelles["_"] ?? "").trimmingCharacters(in: .whitespaces)
                saisie = nil
                if !t.isEmpty { valider(t) }
            }
            .onExitCommand { saisie = nil }
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// L'en-tête d'un domaine : son nom (double-clic pour le renommer), sa nature si ce n'est pas du projet,
    /// « + Projet ». Clic droit : renommer, nature, monter, descendre, supprimer. On y dépose un projet pour l'y ranger.
    func enteteDomaine(_ n: NoeudDomaine, rang: Int, total: Int) -> some View {
        let d = n.domaine
        let cle = "dom:" + d.nom
        let totalDomaine = n.projets.flatMap(\.cats).reduce(0) { $0 + (etat.secondesFenetre[$1.cle] ?? 0) }
        return HStack(spacing: 8) {
            if n.estGroupe, let c0 = n.projets.first?.cats.first {
                pastille(cle: d.nom, titre: d.nom, groupe: nil,
                         couleur: couleurSerie(serie(cle: c0.cle.components(separatedBy: " / ")[0], nom: d.nom, famille: d.famille)), famille: d.famille)
            }
            if renommeDomaine == d.nom {
                TextField("", text: Binding(get: { nouvelles["dom"] ?? d.nom }, set: { nouvelles["dom"] = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).focused($champ)
                    .onAppear { nouvelles["dom"] = d.nom; champ = true }
                    .onSubmit { let t = nouvelles["dom"] ?? d.nom; renommeDomaine = nil; Task { await etat.renommerDomaine(d.nom, en: t) } }
                    .onExitCommand { renommeDomaine = nil }
            } else {
                Text(d.nom).font(.system(size: 13, weight: .semibold))
                    .onTapGesture(count: 2) { renommeDomaine = d.nom }
            }
            Text("\(n.projets.count)").font(.system(size: 11)).foregroundStyle(Color.texteDiscret)
            if d.nature != "projets" {
                Text(L(d.famille)).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.texteDiscret)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Capsule().fill(Color.fondPastille))
            }
            Spacer()
            Text(heuresOuRien(totalDomaine)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Color.texteDiscret)
                .frame(width: 52, alignment: .trailing)
        }
        .simultaneousGesture(TapGesture().onEnded { if n.estGroupe { etat.projetChoisi = "groupe:" + d.nom } })
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(cible == cle ? Color.selection : .clear))
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Nouveau projet")) { saisie = "projet:" + d.nom }
            Button(L("Renommer")) { renommeDomaine = d.nom }
            Menu(L("Nature")) {
                ForEach(["projets", "activites", "hors_travail"], id: \.self) { x in
                    Button { Task { await etat.natureDomaine(d.nom, x) } } label: {
                        if d.nature == x { Label(L(Domaine(nom: "", nature: x, projets: []).famille), systemImage: "checkmark") }
                        else { Text(L(Domaine(nom: "", nature: x, projets: []).famille)) }
                    }
                }
            }
            Button(L("Monter")) { Task { await etat.deplacerDomaine(d.nom, -1) } }.disabled(rang == 0)
            Button(L("Descendre")) { Task { await etat.deplacerDomaine(d.nom, 1) } }.disabled(rang == total - 1)
            Divider()
            Button(L("Supprimer le domaine"), role: .destructive) { Task { await etat.supprimerDomaine(d.nom) } }.disabled(total <= 1)
        }
        .dropDestination(for: String.self) { cles, _ in
            guard let k = cles.first else { return false }
            if k.hasPrefix("projet:") {
                let prefixe = String(k.dropFirst(7))
                guard !n.projets.contains(where: { $0.prefixe == prefixe }) else { return false }
                if n.estGroupe { Task { await etat.deplacerBranche(prefixe, vers: d.nom) } }
                else if !prefixe.contains(" / ") { Task { await etat.rangerProjet(prefixe, dans: d.nom) } }
                else { return false }
                return true
            }
            guard let c = trouver(k) else { return false }
            if n.estGroupe {
                guard c.nom.components(separatedBy: " / ")[0] != d.nom else { return false }
                Task { await etat.rangerSous(c, groupe: d.nom) }
            } else {
                Task { await etat.rangerProjet(c.nom.components(separatedBy: " / ")[0], dans: d.nom) }
            }
            return true
        } isTargeted: { dedans in cible = dedans ? cle : (cible == cle ? nil : cible) }
    }

    /// Une ligne de projet. Un projet sans mission est sa propre catégorie (clic droit complet) ;
    /// un projet avec missions est un en-tête : couleur, nom renommable, temps total, « + Mission » au survol.
    /// On le glisse sur un autre domaine ; on dépose une catégorie dessus pour en faire une de ses missions.
    @ViewBuilder func ligneProjet(_ p: NoeudProjet, domaine n: NoeudDomaine) -> some View {
        let d = n.domaine
        if let c = p.seul {
            AvecSurvol { survol in
                HStack(spacing: 0) {
                    ligne(c, retrait: true).fontWeight(.medium)
                    if survol { boutonMission(p) }
                }
            }
        } else {
            let total = p.cats.reduce(0) { $0 + (etat.secondesFenetre[$1.cle] ?? 0) }
            let choisi = etat.projetChoisi == "groupe:" + p.prefixe
            let replie = replies.contains(p.prefixe)
            AvecSurvol { survol in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.texteDiscret)
                        .rotationEffect(.degrees(replie ? 0 : 90)).frame(width: 10)
                        .padding(4).touchable(rayon: Rayon.petit).padding(-4)
                        .onTapGesture { withAnimation(mouvement(.easeOut(duration: 0.15))) { basculer(p.prefixe) } }
                    Circle().fill(couleurSerie(serie(cle: p.prefixe, nom: p.prefixe, famille: d.famille))).frame(width: 8, height: 8)
                    if renommeBranche == p.prefixe {
                        TextField("", text: Binding(get: { nouvelles["br"] ?? p.nom }, set: { nouvelles["br"] = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).focused($champ)
                            .onAppear { nouvelles["br"] = p.nom; champ = true }
                            .onSubmit {
                                let t = (nouvelles["br"] ?? p.nom).trimmingCharacters(in: .whitespaces)
                                renommeBranche = nil
                                if !t.isEmpty, t != p.nom { Task { await etat.renommerBranche(p.prefixe, en: t) } }
                            }
                            .onExitCommand { renommeBranche = nil }
                    } else {
                        Text(p.nom).font(.system(size: 13, weight: .medium))
                            .onTapGesture(count: 2) { renommeBranche = p.prefixe }
                    }
                    Spacer()
                    if survol { boutonMission(p) }
                    Text(heuresOuRien(total)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.texteDiscret)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .padding(.leading, 16)
                .background(RoundedRectangle(cornerRadius: 8).fill(cible == "proj:" + p.prefixe ? Color.selection
                    : choisi ? Color.selection : Color.primary.opacity(survol ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .simultaneousGesture(TapGesture().onEnded { etat.projetChoisi = "groupe:" + p.prefixe })
            .draggable("projet:" + p.prefixe) {
                Text(p.nom).font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .dropDestination(for: String.self) { cles, _ in
                guard let k = cles.first, !k.hasPrefix("projet:"), let source = trouver(k), !p.cats.contains(where: { $0.cle == k }) else { return false }
                Task { await etat.rangerSous(source, groupe: p.prefixe) }
                return true
            } isTargeted: { dedans in cible = dedans ? "proj:" + p.prefixe : (cible == "proj:" + p.prefixe ? nil : cible) }
            .contextMenu {
                Button(L("Nouvelle mission")) { saisie = "mission:" + p.prefixe }
                Button(L("Renommer")) { renommeBranche = p.prefixe }
                Menu(L("Ranger dans")) {
                    ForEach(etat.domaines.filter { $0.nom != d.nom }) { x in
                        Button(x.nom) {
                            Task {
                                if x.projets.contains(x.nom) { await etat.deplacerBranche(p.prefixe, vers: x.nom) }
                                else if !p.prefixe.contains(" / ") { await etat.rangerProjet(p.prefixe, dans: x.nom) }
                            }
                        }
                    }
                }
            }
        }
    }

    func boutonMission(_ p: NoeudProjet) -> some View {
        Button { saisie = "mission:" + p.prefixe } label: {
            Label(L("Mission"), systemImage: "plus").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(StyleLien())
        .padding(.horizontal, 8)
    }

}

/// Un état de survol propre à une ligne : survoler une ligne ne redessine qu'elle, pas toute la liste.
struct AvecSurvol<Contenu: View>: View {
    @ViewBuilder let contenu: (Bool) -> Contenu
    @State private var survol = false
    var body: some View { contenu(survol).onHover { survol = $0 } }
}

/// Met Temps au premier plan, sauf en aperçu (captures) : une fenêtre d'aperçu ne prend jamais le clavier.
@MainActor func activer() {
    guard !CommandLine.arguments.contains("--apercu") else { return }
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Fenêtre

struct Fenetre: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var fermer

    /// Ouvre la fenêtre de Temps et referme le panneau de la barre des menus.
    func ouvrirTemps() {
        openWindow(id: "fenetre")
        activer()
        fermer()
    }

    /// Au plus sept lignes : le reste passe dans « Autres », dépliable.
    /// (Pas de ScrollView : dans la fenêtre de la barre des menus, il s'effondre à une hauteur nulle.)
    static func resserrer(_ postes: [Poste], max: Int = 7) -> [Poste] {
        guard postes.count > max else { return postes }
        let reste = postes.dropFirst(max - 1)
        let detail = reste.flatMap { $0.detail }.sorted { $0.secondes > $1.secondes }
        return Array(postes.prefix(max - 1)) + [Poste(cle: "autres", nom: "Autres", secondes: reste.reduce(0) { $0 + $1.secondes }, detail: detail)]
    }

    func famille(_ nom: String) -> Famille? { etat.familles.first { $0.nom == nom } }

    /// Les postes de travail de la période (projets et activités), du plus long au plus court.
    var travailTries: [(poste: Poste, famille: String)] {
        ((famille(projets)?.postes ?? []).map { ($0, projets) } + (famille(activites)?.postes ?? []).map { ($0, activites) })
            .sorted { $0.0.secondes > $1.0.secondes }
    }
    var travailTotal: Int { travailTries.count }
    /// Change quand les données d'une autre période arrivent : la liste se renouvelle d'un seul fondu.
    var cleDonnees: String { "\(etat.depuis?.timeIntervalSince1970 ?? 0)-\(etat.jours)-\(etat.jourChoisi ?? 0)" }

    struct GroupePanneau {
        let domaine: String
        var total: Double
        var postes: [Poste]
        var familles: [String: String]
        /// Le nom sans son domaine : « Dupont » plutôt que « Studio / Dupont ».
        func court(_ p: Poste) -> String {
            p.nom.hasPrefix(domaine + " / ") ? String(p.nom.dropFirst(domaine.count + 3)) : L(p.nom)
        }
        @MainActor func couleur(_ p: Poste) -> Color { couleurSerie(serie(cle: p.cle, nom: p.nom, famille: familles[p.cle] ?? projets)) }
    }

    /// Les six postes les plus longs, rangés sous leur domaine ; les domaines du plus chargé au moins chargé.
    func groupesDuPanneau() -> [GroupePanneau] {
        var totaux: [String: Double] = [:]
        for (p, f) in travailTries { totaux[etat.placer(p.nom, famille: f).domaine, default: 0] += p.secondes }
        var groupes: [String: GroupePanneau] = [:]
        for (p, f) in travailTries.prefix(6) {
            let d = etat.placer(p.nom, famille: f).domaine
            groupes[d, default: GroupePanneau(domaine: d, total: totaux[d] ?? 0, postes: [], familles: [:])].postes.append(p)
            groupes[d]?.familles[p.cle] = f
        }
        return groupes.values.sorted { $0.total > $1.total }
    }

    /// Le panneau montre un seul jour (aujourd'hui ou un jour choisi) : ruban plutôt qu'histogramme.
    var unJour: Bool { etat.jours == 0 || etat.jourChoisi != nil }

    var periode: String {
        guard let d = etat.depuis else { return "" }
        let jour = formatJourLong.string(from: d)
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
            case .classer(let d):
                // le panneau ne défile pas de lui-même : l'écran Classer tient dans la hauteur de l'écran
                ScrollView { EcranClasser(d: d) }
                    .frame(height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let r = etat.rangement {
                HStack {
                    Text(r.message).lineLimit(1)
                    Spacer()
                    Button("Annuler") { Task { await etat.annuler() } }
                        .buttonStyle(StyleLien()).fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.appui))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .padding(12)
                .transition(glissement(.bottom))
            }
        }
        .task { await etat.charger() }
    }

    var tableau: some View {
        let echelle = max(famille(projets)?.postes.first?.secondes ?? 0, famille(nonClasse)?.secondes ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            // les actions en haut : pas besoin de descendre sous une longue liste de projets
            HStack(spacing: 6) {
                BoutonPlage(pastille: true)
                Spacer()
                Button { ouvrirTemps() } label: { Label(L("Ouvrir Temps"), systemImage: "macwindow") }
                    .buttonStyle(StylePastille())
                Menu {
                    SettingsLink { Text("Réglages…") }
                    Divider()
                    Button("Quitter Temps") { etat.moteur.arreter(); NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .menuStyle(.button).buttonStyle(StylePastille()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("Plus"))
                .foregroundStyle(Color.texteDiscret)
            }

            CarteAcces()

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(duree(etat.travail))
                        .font(.affichage).tracking(-0.6)
                        .contentTransition(.numericText())
                    HStack(spacing: 2) {
                        if unJour {
                            Button { etat.decalerJour(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                                .accessibilityLabel(L("Jour précédent"))
                                .buttonStyle(StyleTouche(forme: .cercle))
                        }
                        Text(periode).font(.secondaire).foregroundStyle(Color.texteDiscret).lineLimit(1)
                        if unJour && etat.jourChoisi != nil {
                            Button { etat.decalerJour(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                                .accessibilityLabel(L("Jour suivant"))
                                .buttonStyle(StyleTouche(forme: .cercle))
                        }
                    }
                    .font(.legende).foregroundStyle(Color.texteDiscret)
                    .frame(height: 18)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // la zone graphique garde sa hauteur : passer d'un jour à 7 ou 30 jours ne déplace rien dessous
            ZStack {
                if unJour {
                    RubanPanneau { d in withAnimation(mouvement(.snappy(duration: 0.18))) { etat.ecran = .classer(d) } }
                        .transition(.opacity)
                } else if etat.jours >= 29 {
                    CalendrierMois { j in etat.ouvrirJour(j) }
                        .transition(.opacity)
                } else {
                    Histogramme(hauteur: 52) { j in etat.ouvrirJour(j) }
                        .transition(.opacity)
                }
            }
            .frame(height: 72, alignment: .top)
            .padding(.horizontal, 4)
            .animation(mouvement(.easeInOut(duration: 0.18)), value: unJour ? 0 : etat.jours)

            SelecteurPeriode()

            if let e = etat.erreur, !erreurDAcces(e) {
                BanniereErreur(texte: e)
            }

            if !etat.reperes.isEmpty {
                Carte {
                    Etiquette(texte: "Cette semaine")
                    ForEach(etat.reperes) { LigneRepere(r: $0) }
                }
            }

            // tout ce qui dépend de la période (non classé, travail, hors travail) change d'un seul fondu :
            // rien ne glisse quand on passe d'aujourd'hui à 7 jours
            let groupes = groupesDuPanneau()
            let affiches = groupes.reduce(0) { $0 + $1.postes.count }
            ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                if let n = famille(nonClasse), let poste = n.postes.first {
                    CarteNonClasse(poste: poste, max: echelle) {
                        etat.rubriqueDemandee = "À classer"
                        ouvrirTemps()
                    }
                }

                // le travail : six projets au plus, rangés sous leur domaine ; la suite dans la fenêtre
                if !groupes.isEmpty {
                    Carte {
                        ForEach(groupes, id: \.domaine) { g in
                            HStack(spacing: 6) {
                                Text(g.domaine).font(.corpsFort)
                                Spacer()
                                Text(duree(g.total)).font(.secondaire).monospacedDigit().foregroundStyle(Color.texteDiscret)
                            }
                            .padding(.horizontal, 8).padding(.top, g.domaine == groupes.first?.domaine ? 2 : 8)
                            ForEach(g.postes) { p in
                                LignePoste(poste: p, max: echelle, affiche: g.court(p), pastille: g.couleur(p), barre: g.couleur(p))
                            }
                        }
                        if travailTotal > affiches {
                            Button(L("+ %d autres", travailTotal - affiches)) { ouvrirTemps() }
                                .buttonStyle(StyleLien()).font(.secondaire)
                                .padding(.horizontal, 4).padding(.top, 2)
                        }
                    }
                }

                if let h = famille(horsTravail) {
                    LignePoste(poste: ligneHors(h), max: max(h.secondes, echelle), discret: true)
                        .padding(.horizontal, 4)
                }
            }
            .id(cleDonnees)
            .transition(.opacity)
            }
            .animation(mouvement(.easeInOut(duration: 0.15)), value: cleDonnees)
        }
    }
}


/// Le total du jour dans la barre des menus. Créée au lancement : c'est elle qui donne à l'état de quoi ouvrir la fenêtre.
struct EtiquetteBarre: View {
    @EnvironmentObject var etat: Etat
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: etat.vif ? "timer" : "pause.circle")
            if let t = etat.aujourdhui { Text(duree(t)).monospacedDigit() }
        }
        .onAppear {
            etat.ouvrirFenetre = { [openWindow] in
                openWindow(id: "fenetre")
                activer()
            }
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
            EtiquetteBarre().environmentObject(etat)
        }
        .menuBarExtraStyle(.window)

        Window("Temps", id: "fenetre") {
            FenetrePrincipale().environmentObject(etat)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 680)
        .windowToolbarStyle(.unified)

        // la saisie d'une plage depuis le panneau : une petite fenêtre à elle
        Window(L("Nouvelle plage"), id: "plage") {
            FenetrePlage().environmentObject(etat)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            Reglages().environmentObject(etat)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Exporter le mois en cours…") {
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM"
                    Task { await etat.exporter(f.string(from: Date())) }
                }
                .keyboardShortcut("e")
            }
            CommandGroup(before: .sidebar) {
                // ⌘1 Vue d'ensemble, ⌘2 Projets, ⌘3 Bilan ; ⌘0 À classer
                ForEach(Array(Rubrique.allCases.filter { $0 != .aClasser }.enumerated()), id: \.offset) { i, r in
                    Button(L(r.rawValue)) { etat.rubriqueDemandee = r.rawValue }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button(L(Rubrique.aClasser.rawValue)) { etat.rubriqueDemandee = Rubrique.aClasser.rawValue }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quitter Temps") { etat.moteur.arreter(); NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}


/// Dans le panneau : « + Plage » ouvre la saisie dans sa propre fenêtre (projet, heures, note).
struct BoutonPlage: View {
    @Environment(\.openWindow) private var openWindow
    var pastille = false
    var body: some View {
        let b = Button { openWindow(id: "plage"); activer() } label: { Label(L("Plage"), systemImage: "plus") }
            .help(L("Ajouter une plage hors du Mac : réunion, rendez-vous, croquis"))
        if pastille { b.buttonStyle(StylePastille()) } else { b.buttonStyle(StyleLien(couleur: Color.texteDiscret)) }
    }
}

struct FenetrePlage: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var essai = 0
    var body: some View {
        // un formulaire neuf à chaque ouverture
        FormulairePlage { essai += 1; dismissWindow(id: "plage") }.id(essai)
    }
}


/// Le ruban du jour affiché dans le panneau : sa propre frise, rechargée quand le total change.
struct RubanPanneau: View {
    @EnvironmentObject var etat: Etat
    let ouvrir: (Detail) -> Void
    @State private var frise: Frise?

    var jour: Date {
        Calendar.current.startOfDay(for: etat.jourChoisi.map { Date(timeIntervalSince1970: $0) } ?? Date())
    }

    var body: some View {
        RubanJour(friseLocale: frise, jourLocal: jour, compact: true, ouvrirSur: ouvrir)
            .task(id: "\(jour.timeIntervalSince1970)-\(Int(etat.travail / 60))") {
                guard let url = URL(string: "http://127.0.0.1:8230/frise?jour=\(jour.timeIntervalSince1970)"),
                      let (d, _) = try? await URLSession.shared.data(from: url) else { return }
                frise = try? JSONDecoder().decode(Frise.self, from: d)
            }
    }
}


/// Les 30 derniers jours en calendrier : une ligne par semaine (lundi → dimanche), chaque case plus ou moins
/// foncée selon le travail du jour ; aujourd'hui cerclé ; un clic ouvre le jour.
struct CalendrierMois: View {
    @EnvironmentObject var etat: Etat
    let ouvrir: (Jour) -> Void

    /// Les semaines, complétées par des cases vides avant le premier jour et après aujourd'hui.
    var semaines: [[Jour?]] {
        guard let premier = etat.mois.first else { return [] }
        let cal = Calendar.current
        let decalage = (cal.component(.weekday, from: Date(timeIntervalSince1970: premier.jour)) + 5) % 7   // lundi = 0
        var cases: [Jour?] = Array(repeating: nil, count: decalage) + etat.mois.map { Optional($0) }
        while cases.count % 7 != 0 { cases.append(nil) }
        return stride(from: 0, to: cases.count, by: 7).map { Array(cases[$0..<$0 + 7]) }
    }

    var body: some View {
        let lignes = semaines
        let hauteur = Swift.max(6, (58 - CGFloat(lignes.count - 1) * 3) / CGFloat(Swift.max(lignes.count, 1)))
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Text(Histogramme.initiales[(i + 1) % 7]).font(.legende).foregroundStyle(Color.texteDiscret).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(lignes.enumerated()), id: \.offset) { _, semaine in
                HStack(spacing: 3) {
                    ForEach(Array(semaine.enumerated()), id: \.offset) { _, j in
                        if let j {
                            let aujourdhui = j.id == etat.mois.last?.id
                            Button { ouvrir(j) } label: {
                                RoundedRectangle(cornerRadius: Rayon.petit)
                                    .fill(Color.primary.opacity(j.travail > 0 ? 0.1 + 0.72 * Swift.min(1, j.travail / (8 * 3600)) : 0.035))
                                    .overlay(RoundedRectangle(cornerRadius: Rayon.petit)
                                        .strokeBorder(aujourdhui ? Color.lien : .clear, lineWidth: 1.5))
                                    .frame(height: hauteur)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(StyleTouche(forme: .rectangle(Rayon.petit)))
                            .help("\(formatJourLong.string(from: Date(timeIntervalSince1970: j.jour))) · \(duree(j.travail))")
                            .accessibilityLabel("\(formatJourLong.string(from: Date(timeIntervalSince1970: j.jour))), \(duree(j.travail))")
                        } else {
                            Color.clear.frame(height: hauteur)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}


/// Aujourd'hui (ou le jour choisi) / 7 jours / 30 jours, sur toute la largeur du panneau.
struct SelecteurPeriode: View {
    @EnvironmentObject var etat: Etat
    @Namespace private var espace

    var body: some View {
        let choix: [(Int, String)] = [(0, etat.jourChoisi.map { jourCourt($0) } ?? L("Aujourd'hui")), (6, L("7 jours")), (29, L("30 jours"))]
        HStack(spacing: 2) {
            ForEach(choix, id: \.0) { valeur, libelle in
                let actif = valeur == 0 ? (etat.jours == 0 || etat.jourChoisi != nil) : (etat.jours == valeur && etat.jourChoisi == nil)
                Button {
                    if valeur == 0 { if etat.jours != 0 { etat.jours = 0 } } else { etat.jours = valeur }
                } label: {
                    Text(libelle).font(.system(size: 11, weight: actif ? .semibold : .regular)).lineLimit(1)
                        .foregroundStyle(actif ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.texteDiscret))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if actif {
                                RoundedRectangle(cornerRadius: 6).fill(Color.appui)
                                    .matchedGeometryEffect(id: "periode", in: espace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(StyleTouche(forme: .rectangle(6)))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Rayon.moyen).fill(Color.voile))
        .animation(mouvement(.snappy(duration: 0.2)), value: etat.jours)
        .animation(mouvement(.snappy(duration: 0.2)), value: etat.jourChoisi)
    }
}


/// Une erreur liée à un accès macOS : la carte des accès la montre déjà, avec son bouton.
func erreurDAcces(_ e: String) -> Bool {
    e.contains("Réglages Système") || e.contains("System Settings")
}

/// Une erreur, en orange, avec l'action qui répare quand il y en a une (le journal, si le moteur ne répond pas).
struct BanniereErreur: View {
    let texte: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.secondaire)
            Text(texte.components(separatedBy: " Journal").first ?? texte).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if texte.contains("8230") {
                Button(L("Journal")) { NSWorkspace.shared.open(Moteur.donnees.appendingPathComponent("journal.log")) }
                    .buttonStyle(StylePastille())
            }
        }
        .font(.corps).foregroundStyle(Color.signal)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: Rayon.grand).fill(Color.fondSignal))
    }
}
