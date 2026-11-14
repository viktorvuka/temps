import SwiftUI
import ApplicationServices
import UserNotifications

// Réglages de Temps (⌘,) : état des accès macOS, démarrage, rappel du vendredi, export, règles.
// Et la rubrique Règles de la fenêtre : toutes les règles de classement, modifiables sur place.

// MARK: - Accès

/// Les apps que Temps pilote par AppleScript pour lire ce qui est ouvert : la fenêtre au premier plan
/// (Événements système), la page (Safari), le message (Mail), la tâche (Things), la note (Notes), le dossier (Finder).
let appsAutomatisees: [(nom: String, id: String)] = [
    ("Événements système", "com.apple.systemevents"), ("Safari", "com.apple.Safari"), ("Mail", "com.apple.mail"),
    ("Finder", "com.apple.finder"), ("Notes", "com.apple.Notes"), ("Things", "com.culturedcode.ThingsMac"),
]

/// true : autorisé ; false : refusé ; nil : pas encore demandé, ou app fermée (macOS ne peut pas répondre).
func automatisation(_ bundle: String) -> Bool? {
    var adresse = AEAddressDesc()
    let octets = Array(bundle.utf8)
    guard AECreateDesc(typeApplicationBundleID, octets, octets.count, &adresse) == noErr else { return nil }
    defer { AEDisposeDesc(&adresse) }
    switch AEDeterminePermissionToAutomateTarget(&adresse, typeWildCard, typeWildCard, false) {
    case noErr: return true
    case OSStatus(errAEEventNotPermitted): return false
    default: return nil
    }
}

struct EtatAcces: Decodable {
    let disque: Bool
    let titres: Bool
}

enum Volet: String {
    case disque = "Privacy_AllFiles", accessibilite = "Privacy_Accessibility", automatisation = "Privacy_Automation"
    func ouvrir() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!)
    }
}

struct LigneAcces: View {
    let titre: String
    let ok: Bool?
    let volet: Volet
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.triangle.fill" : "circle.dashed")
                .foregroundStyle(ok == true ? AnyShapeStyle(Color.green) : ok == false ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            Text(L(titre))
            Spacer()
            Button(ok == false ? L("Autoriser…") : L("Ouvrir…")) { volet.ouvrir() }
        }
    }
}

struct Reglages: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        TabView {
            ReglagesGeneral().tabItem { Label("Général", systemImage: "gearshape") }
            ReglagesExport().tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            VueRegles().tabItem { Label("Règles", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 620, height: 520)
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
            }
        }
        .onAppear { activer() }
        .task { if etat.moisDispos.isEmpty { await etat.chargerFenetre() } }
    }
}

struct ReglagesGeneral: View {
    @EnvironmentObject var etat: Etat
    @State private var acces: EtatAcces?
    @State private var accessibilite = AXIsProcessTrusted()
    @State private var auto: [String: Bool] = [:]
    @AppStorage("rappelVendredi") private var rappel = true

    var body: some View {
        Form {
            Section("Accès") {
                LigneAcces(titre: "Accès complet au disque", ok: acces?.disque, volet: .disque)
                LigneAcces(titre: "Accessibilité", ok: accessibilite || acces?.titres == true, volet: .accessibilite)
                LigneAcces(titre: "Automatisation", ok: auto.values.contains(false) ? false : (auto.values.contains(true) ? true : nil), volet: .automatisation)
            }
            Section("Général") {
                Toggle("Ouvrir au démarrage", isOn: Binding(get: { etat.auDemarrage }, set: { etat.basculerDemarrage($0) }))
                Toggle("Ranger les petits moments avec ce qui les entoure", isOn: Binding(get: { etat.lissage }, set: { oui in
                    etat.lissage = oui
                    Task { await etat.poser("reglages", "lissage", oui ? 10 : 0, message: L(oui ? "Petits moments rangés" : "Petits moments laissés à classer")) }
                }))
                Toggle("Rappel du non classé le vendredi", isOn: $rappel)
                    .onChange(of: rappel) { _, oui in if oui { Task { await etat.autoriserNotifications() } } }
                HStack {
                    Text("Dossier des données")
                    Spacer()
                    Button(L("Afficher")) { NSWorkspace.shared.open(Moteur.donnees) }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                acces = await etat.lireAcces()
                accessibilite = AXIsProcessTrusted()
                auto = await Task.detached {
                    Dictionary(uniqueKeysWithValues: appsAutomatisees.compactMap { a in automatisation(a.id).map { (a.id, $0) } })
                }.value
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Un CSV par mois : séparateur « ; », virgule décimale, prêt pour Numbers ou Excel.
struct ReglagesExport: View {
    @EnvironmentObject var etat: Etat
    var body: some View {
        Form {
            Section {
                ForEach(etat.moisDispos, id: \.self) { m in
                    HStack {
                        Text(nomMois(m))
                        Spacer()
                        Button(L("Exporter…")) { Task { await etat.exporter(m) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Rappel du vendredi

final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let partage = Notifications()
    weak var etat: Etat?

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        await MainActor.run {
            etat?.rubriqueDemandee = Rubrique.aClasser.rawValue
            etat?.ouvrirFenetre?()
        }
    }
}

extension Etat {
    func lireAcces() async -> EtatAcces? {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8230/etat")!) else { return nil }
        return try? JSONDecoder().decode(EtatAcces.self, from: d)
    }

    func autoriserNotifications() async {
        let c = UNUserNotificationCenter.current()
        Notifications.partage.etat = self
        c.delegate = Notifications.partage
        _ = try? await c.requestAuthorization(options: [.alert, .sound])
    }

    /// Le vendredi à partir de 16 h, une fois par semaine : s'il reste plus de 2 h non classées depuis lundi, une notification.
    func rappelVendredi() async {
        let d = UserDefaults.standard
        guard d.object(forKey: "rappelVendredi") as? Bool ?? true else { return }
        let cal = Calendar.current, maintenant = Date()
        guard cal.component(.weekday, from: maintenant) == 6, cal.component(.hour, from: maintenant) >= 16,
              let lundi = cal.dateInterval(of: .weekOfYear, for: maintenant)?.start else { return }
        let semaine = "\(cal.component(.yearForWeekOfYear, from: maintenant))-\(cal.component(.weekOfYear, from: maintenant))"
        guard d.string(forKey: "rappelEnvoye") != semaine,
              let r = try? await lire(0, requete: "debut=\(lundi.timeIntervalSince1970)&fin=\(maintenant.timeIntervalSince1970)") else { return }
        d.set(semaine, forKey: "rappelEnvoye")
        let nc = r.familles?.first { $0.nom == nonClasse }?.secondes ?? 0
        guard nc >= 2 * 3600 else { return }
        let contenu = UNMutableNotificationContent()
        contenu.title = "Temps"
        contenu.body = L("%@ non classées cette semaine", duree(nc))
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vendredi-\(semaine)", content: contenu, trigger: nil))
    }
}

// MARK: - Règles

struct Regle: Decodable, Identifiable {
    let section: String
    let motif: String
    let valeur: String
    let nom: String
    var id: String { section + "|" + motif }
    var libelleSection: String {
        switch section {
        case "apps": L("App")
        case "chemins": L("Dossier")
        case "plages": L("Plage")
        case "forcer": L("Forcé")
        case "fusions": L("Fusion")
        default: L("Texte")
        }
    }
}

extension Etat {
    func lireRegles() async -> [Regle] {
        struct R: Decodable { let regles: [Regle] }
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8230/regles")!),
              let r = try? JSONDecoder().decode(R.self, from: d) else { return [] }
        return r.regles
    }

    /// Change le motif ou la catégorie d'une règle, annulable.
    func remplacer(_ r: Regle, motif: String, valeur: String) async {
        let motif = motif.trimmingCharacters(in: .whitespaces)
        guard !motif.isEmpty, motif != r.motif || valeur != r.valeur else { return }
        await modifier("remplacer", ["section": r.section, "ancien": r.motif, "motif": motif, "valeur": valeur],
                       message: L("Règle modifiée")) { rep in
            ("remplacer", ["section": r.section, "ancien": motif, "motif": r.motif, "valeur": rep.avant ?? r.valeur])
        }
    }
}

/// Une règle : son motif (double-clic pour le corriger), sa catégorie (clic pour en choisir une autre), la corbeille.
/// Rien de lourd n'est construit tant qu'on ne touche pas la ligne : la liste reste fluide.
/// Une règle dans la carte de sa catégorie. Une règle de texte se corrige d'un clic sur son texte ;
/// au survol, un bouton la déplace vers un autre projet et la corbeille la retire.
struct LigneRegle: View {
    @EnvironmentObject var etat: Etat
    let r: Regle
    @State private var edite = false
    @State private var texte = ""
    @State private var choix = false
    @State private var survol = false
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(r.libelleSection).font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
            if edite {
                TextField("", text: $texte)
                    .textFieldStyle(.roundedBorder).focused($focus)
                    .onSubmit { edite = false; Task { await etat.remplacer(r, motif: texte, valeur: r.valeur) } }
                    .onExitCommand { edite = false }
                    .onChange(of: focus) { _, f in if !f { edite = false } }
                    .onAppear { texte = r.motif; focus = true }
            } else if r.section == "titres" {
                Text(r.motif).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { edite = true }
                    .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
            } else {
                Text(r.motif).lineLimit(1)
                if r.section == "apps" {
                    Text(Detail(appareil: "Mac", app: r.motif, contexte: "", secondes: 0).nomApp)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Button { choix = true } label: {
                    Label(L("Déplacer"), systemImage: "arrow.turn.up.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .popover(isPresented: $choix, arrowEdge: .bottom) {
                    ChoixCategorie { cle in
                        choix = false
                        Task { await etat.remplacer(r, motif: r.motif, valeur: cle) }
                    }
                    .environmentObject(etat)
                }
                Button { Task { await etat.retirer(r.section, r.motif, ancien: r.valeur, message: L("Règle retirée")) } } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .opacity(survol || choix ? 1 : 0)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(survol || choix ? 0.05 : 0)))
        .onHover { survol = $0 }
    }
}

/// Liste de catégories avec recherche, dans un popover.
struct ChoixCategorie: View {
    @EnvironmentObject var etat: Etat
    let choisir: (String) -> Void
    @State private var q = ""
    var body: some View {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        let cats = etat.categories.filter { t.isEmpty ? !$0.archivee : $0.nom.lowercased().contains(t) }
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Chercher ou créer un projet"), text: $q)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let c = cats.first { choisir(c.cle) } else if !t.isEmpty { choisir(q.trimmingCharacters(in: .whitespaces)) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(cats) { c in LigneChoix(texte: c.nom) { choisir(c.cle) } }
                }
            }
            .frame(height: 260)
        }
        .padding(10)
        .frame(width: 280)
    }
}

struct VueRegles: View {
    @EnvironmentObject var etat: Etat
    @State private var regles: [Regle] = []
    @State private var recherche = ""
    @State private var groupes: [(String, [Regle])] = []

    func regrouper() {
        let q = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        let f = q.isEmpty ? regles : regles.filter { $0.motif.lowercased().contains(q) || $0.nom.lowercased().contains(q) }
        groupes = Dictionary(grouping: f, by: \.nom).sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { ($0.key, $0.value.sorted { $0.motif.lowercased() < $1.motif.lowercased() }) }
    }

    func recharger() async {
        regles = await etat.lireRegles()
        regrouper()
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Chercher une règle"), text: $recherche)
                .textFieldStyle(.roundedBorder).padding(12)
                .onChange(of: recherche) { regrouper() }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groupes, id: \.0) { nom, liste in
                        Carte {
                            Etiquette(texte: nom, compte: liste.count)
                            ForEach(liste) { LigneRegle(r: $0) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .task { await recharger() }
        .onChange(of: etat.rangement?.id) { Task { await recharger() } }
    }
}
