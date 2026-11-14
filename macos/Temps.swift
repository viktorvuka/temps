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
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5))
    }
}

/// Un format de date localisé, créé une fois (en créer un par ligne et par dessin coûte cher).
func formatDate(_ gabarit: String) -> DateFormatter {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(gabarit)
    return f
}
let formatJourLong = formatDate("EEEEdMMMM"), formatJourCourt = formatDate("EEEdMMM")

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
    var id: String { appareil + "|" + app + "|" + contexte }

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
        if app.isEmpty { return p }
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

// MARK: - Moteur (scripts Python)

/// Temps lance lui-même l'enregistreur et le serveur Python, rangés à côté de Temps.app, et les
/// relance s'ils s'arrêtent. Les accès macOS (disque, Accessibilité, Automatisation) sont ceux de
/// Temps.app : macOS les attribue à l'app qui a lancé les scripts.
/// `open Temps.app --args --demo` lance seulement le serveur, sur les données de démonstration.
final class Moteur {
    static let dossier = Bundle.main.bundleURL.deletingLastPathComponent()
    static let donnees = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Temps")
    /// Python 3.11 ou plus récent (tomllib) : Homebrew, python.org, puis celui du système.
    static let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
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
    @Published var histogramme: [Jour] = []
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
            if UserDefaults.standard.object(forKey: "rappelVendredi") as? Bool ?? true { await autoriserNotifications() }
            try? await Task.sleep(for: .seconds(2))
            while true {
                await charger()
                await rappelVendredi()
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
            reperes = r.reperes ?? []
            aujourdhui = jours == 0 && jourChoisi == nil ? travail : histogramme.last?.travail
        } catch {
            if periode == jours, jour == jourChoisi { erreur = L("Serveur injoignable sur le port 8230. Journal : ~/Library/Application Support/Temps/journal.log") }
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
            if CommandLine.arguments.contains("--clair") { NSApp.appearance = NSAppearance(named: .aqua) }
            if CommandLine.arguments.contains("--semaine") { etat.jours = 6 }
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
            withAnimation(.snappy) { rangement = fait }
            await rechargerTout()
            // la barre reste 8 s, sans retenir ce qui suit (une seconde écriture, une liste à relire)
            Task {
                try? await Task.sleep(for: .seconds(8))
                if rangement?.id == fait.id { withAnimation(.snappy) { rangement = nil } }
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
        if enFile, let d = aClasserCourant {
            rattrapage?.faits += 1
            rattrapage?.ecartes.insert(d.id)
            suivant()
        } else {
            withAnimation(.snappy) { ecran = .tableau }
        }
        classerFenetre = nil
        await poser(p.section, p.motif, cle, message: L("Rangé dans %@", nom))
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
        withAnimation(.snappy(duration: 0.18)) {
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
            guard let s = d.suggestion, let p = d.portees.first else { return nil }
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
        withAnimation(.snappy) { rangement = nil }
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
    @Environment(\.dansFenetre) private var dansFenetre
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { contenu }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // dans la fenêtre translucide : une plaque de verre ; dans le panneau (déjà en verre) : un voile léger
                if dansFenetre {
                    RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045))
                } else {
                    RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: dansFenetre ? 14 : 11).strokeBorder(Color.primary.opacity(dansFenetre ? 0.06 : 0.07)))
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

    var classable: Bool { d.classable }

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
    @State private var ouvert: Bool
    @State private var survol = false
    @State private var tout = false
    @Environment(\.dansFenetre) private var dansFenetre

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
                let suggerees = poste.detail.filter { $0.suggestion != nil && $0.classable }
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

/// Le temps non classé, à part et en tête : c'est le seul endroit où il y a quelque chose à faire.
struct CarteNonClasse: View {
    let poste: Poste
    let max: Double
    let classer: () -> Void
    var body: some View {
        Carte {
            LignePoste(poste: poste, max: max, teinte: .orange)
            LigneChoix(texte: L("Classer une à une (%d)", poste.detail.count), icone: "list.bullet", action: classer)
        }
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.35)))
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
    var enFile = false
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
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button { etat.passer() } label: {
                        Label("Passer", systemImage: "chevron.right").labelStyle(.titleAndIcon).font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("⌘→")
                }
            }

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
                        if recherche.trimmingCharacters(in: .whitespaces).isEmpty { if let s = suggeree { choisir(s.cle) } }
                        else if let n = nouveau, trouvees.isEmpty { choisir(n) } else if let c = trouvees.first { choisir(c.cle) }
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

    /// Dans la liste de la fenêtre : le temps de la période et, s'il y a un devis, l'écart en couleur.
    @ViewBuilder func resumeListe(_ c: Categorie) -> some View {
        HStack(spacing: 8) {
            if let f = etat.fiches.first(where: { $0.cle == c.cle }), let v = f.vendu {
                let ecart = f.total / 3600 - v
                Text(ecart > 0 ? "+\(heures(ecart * 3600))" : "−\(heures(-ecart * 3600))")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ecart > 0 ? Color.orange : Color.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((ecart > 0 ? Color.orange : Color.primary).opacity(0.12)))
            }
            Text(heuresOuRien(etat.secondesFenetre[c.cle])).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(dateOuverte == c.cle ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
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
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
                .opacity(survol ? 1 : 0)
            pastille(cle: retrait ? c.cle : g, titre: retrait ? c.nom : g, groupe: retrait ? g : nil,
                     couleur: couleurSerie(serie(cle: c.cle, nom: c.nom, famille: c.famille)), famille: c.famille)
            NomModifiable(cle: c.cle, nom: c.nom, affiche: retrait ? (c.nom.components(separatedBy: " / ").last ?? c.nom) : c.nom)
                .opacity(c.archivee ? 0.55 : 1)
                .font(.system(size: niveau >= 2 ? 12 : 13))
            if niveau >= 2 { dateDeMission(c) }
            Spacer()
            resumeListe(c)
        }
        .font(.system(size: 13))
        .padding(.vertical, 5).padding(.horizontal, 12)
        .padding(.leading, retrait ? 14 + CGFloat(Swift.max(niveau - 1, 0)) * 18 : 0)
        .background(RoundedRectangle(cornerRadius: 7).fill(cible == c.cle ? Color.accentColor.opacity(0.18)
            : etat.projetChoisi == c.cle ? Color.accentColor.opacity(0.16) : Color.primary.opacity(survol ? 0.05 : 0)))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { etat.projetChoisi = c.cle })
        .popover(isPresented: Binding(get: { fusionDe == c.cle }, set: { if !$0 { fusionDe = nil } }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Fusionner « %@ » dans…", c.nom)).font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 10)
                ChoixCategorie { cible in
                    fusionDe = nil
                    guard cible != c.cle else { return }
                    Task { await etat.fusionner(c, dans: cible) }
                }
            }
            .environmentObject(etat)
        }
        }
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
            Text("Glisse un projet ici.").font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 30).padding(.vertical, 4)
        case .nouveauProjet(let n):
            if saisie == "projet:" + n.domaine.nom {
                champ(L("Nom du projet")) { t in Task { await etat.creerProjet(t, dans: n.domaine) } }.padding(.leading, 22)
            } else {
                boutonAjout(L("Nouveau projet")) { saisie = "projet:" + n.domaine.nom }.padding(.leading, 32)
            }
        }
    }

    /// « + Nouveau … » en bas d'une liste : discret, en couleur d'accent.
    func boutonAjout(_ texte: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(texte, systemImage: "plus").font(.system(size: 12, weight: .medium))
                .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
    }

    /// Dans la fenêtre : Domaine › Projet › Mission, en une seule liste construite au fil du défilement.
    /// Tout se crée, se renomme, se glisse et se supprime sur place.
    var corpsFenetre: some View {
        let arbre = etat.arbre
        let archivees = etat.categories.filter(\.archivee).sorted { $0.nom.lowercased() < $1.nom.lowercased() }
        let fond = Color.primary.opacity(0.04)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Etiquette(texte: "Domaines", compte: arbre.count)
                    .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
                ForEach(rangees(arbre), id: \.0.id) { r, haut, bas in
                    vue(r)
                        .padding(.horizontal, 4).padding(.top, haut ? 6 : 0).padding(.bottom, bas ? 6 : 0)
                        .background(UnevenRoundedRectangle(topLeadingRadius: haut ? 12 : 0, bottomLeadingRadius: bas ? 12 : 0,
                                                           bottomTrailingRadius: bas ? 12 : 0, topTrailingRadius: haut ? 12 : 0).fill(fond))
                        .padding(.top, haut ? 10 : 0)
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
                    Divider().padding(.horizontal, 12).padding(.top, 10)
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { archivesOuvertes.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "archivebox").font(.system(size: 11))
                            Text("Archivés").font(.system(size: 11, weight: .semibold))
                            Text("\(archivees.count)").font(.system(size: 10)).monospacedDigit()
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(archivesOuvertes ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).focused($champ)
                    .onAppear { nouvelles["dom"] = d.nom; champ = true }
                    .onSubmit { let t = nouvelles["dom"] ?? d.nom; renommeDomaine = nil; Task { await etat.renommerDomaine(d.nom, en: t) } }
                    .onExitCommand { renommeDomaine = nil }
            } else {
                Text(d.nom).font(.system(size: 15, weight: .semibold))
                    .onTapGesture(count: 2) { renommeDomaine = d.nom }
            }
            Text("\(n.projets.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            if d.nature != "projets" {
                Text(L(d.famille)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer()
            Text(heuresOuRien(totalDomaine)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .simultaneousGesture(TapGesture().onEnded { if n.estGroupe { etat.projetChoisi = "groupe:" + d.nom } })
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(cible == cle ? Color.accentColor.opacity(0.18) : .clear))
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
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(replie ? 0 : 90)).frame(width: 10)
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { basculer(p.prefixe) } }
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
                    Text(heuresOuRien(total)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .padding(.leading, 14)
                .background(RoundedRectangle(cornerRadius: 7).fill(cible == "proj:" + p.prefixe ? Color.accentColor.opacity(0.18)
                    : choisi ? Color.accentColor.opacity(0.16) : Color.primary.opacity(survol ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .simultaneousGesture(TapGesture().onEnded { etat.projetChoisi = "groupe:" + p.prefixe })
            .draggable("projet:" + p.prefixe) {
                Text(p.nom).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
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
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
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

            if let n = famille(nonClasse), let poste = n.postes.first {
                CarteNonClasse(poste: poste, max: echelle) {
                    etat.rubriqueDemandee = "À classer"
                    openWindow(id: "fenetre")
                    activer()
                }
            }

            Carte {
                if let p = famille(projets) {
                    ListeDomaines(postes: p.postes, max: echelle)
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
                BoutonPlage()
                Spacer()
                Button("Ouvrir Temps") {
                    openWindow(id: "fenetre")
                    activer()
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Menu {
                    SettingsLink { Text("Réglages…") }
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


/// Dans le panneau : « + Plage » ouvre la saisie dans sa propre fenêtre (projet, heures, note).
struct BoutonPlage: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "plage"); activer() } label: { Label(L("Plage"), systemImage: "plus") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(L("Ajouter une plage hors du Mac : réunion, rendez-vous, croquis"))
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
