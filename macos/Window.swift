import SwiftUI
import UniformTypeIdentifiers

// La vraie fenêtre de Temps : vue d'ensemble sur une période longue, projets et leurs fiches,
// temps par app, bilan face au devis, export CSV par mois.

// MARK: - Données

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
    let projets: [Fiche]?
    let reperes: [Repere]?
    let mois: [String]?
    let histogramme: [Jour]?
    let facturable: Double?
    let erreur: String?
}

enum Rubrique: String, CaseIterable, Identifiable {
    case aClasser = "À classer", ensemble = "Vue d'ensemble", projets = "Projets", bilan = "Bilan"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .ensemble: "chart.bar.xaxis"
        case .aClasser: "tray"
        case .projets: "folder"
        case .bilan: "scalemass"
        }
    }
}

/// Les formats de nombre, créés une fois : une liste en demande un par ligne à chaque dessin.
private func formatNombre(decimales: Int, devise: Bool = false) -> NumberFormatter {
    let f = NumberFormatter()
    if devise { f.numberStyle = .currency }  // devise de la région du Mac (€, $, £…)
    f.maximumFractionDigits = decimales
    f.minimumFractionDigits = decimales
    return f
}
private let formatHeures = [formatNombre(decimales: 0), formatNombre(decimales: 1)]
private let formatMontant = formatNombre(decimales: 0, devise: true)
private let formatHeureMinute = formatPlage("HH:mm")

func heures(_ s: Double) -> String {
    let h = s / 3600
    return (formatHeures[h >= 10 ? 0 : 1].string(from: NSNumber(value: h)) ?? "\(h)") + " h"
}

/// Un montant dans la devise de la région du Mac.
func euros(_ v: Double) -> String {
    formatMontant.string(from: NSNumber(value: v)) ?? "\(Int(v)) €"
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

// MARK: - Journée

struct Tranche: Decodable, Identifiable {
    let t: Double
    let secondes: Double
    let cle: String
    let nom: String
    let famille: String
    let serie: String
    let contexte: String
    var id: Double { t }
}

struct Frise: Decodable {
    let jour: Double
    let tranches: [Tranche]
}

@MainActor func couleurTranche(_ t: Tranche) -> Color {
    t.famille == horsTravail ? Color.primary.opacity(0.14) : couleurSerie(t.serie)
}

/// « 14:05 » en heure locale, quelle que soit la langue : c'est aussi le format des plages dans les règles.
func heureMinute(_ t: Double) -> String { formatHeureMinute.string(from: Date(timeIntervalSince1970: t)) }

func formatPlage(_ f: String) -> DateFormatter {
    let d = DateFormatter()
    d.locale = Locale(identifier: "en_US_POSIX")
    d.dateFormat = f
    return d
}

/// Jour, 7, 30 ou 90 jours, ou des dates libres ; avec le jour ou les dates à choisir.
/// La période : ‹ un libellé clair › (Aujourd'hui, Cette semaine, Octobre 2026…). Les flèches avancent ou reculent
/// d'une période entière ; un clic sur le libellé ouvre les raccourcis et un calendrier où l'on choisit un jour
/// ou une plage (premier clic, deuxième clic).
struct ChoixPeriode: View {
    @EnvironmentObject var etat: Etat
    @State private var ouvert = false

    var libelle: String {
        let cal = Calendar.current, (a, b) = etat.bornesUnite
        let ici = cal.startOfDay(for: Date())
        func en(_ c: Calendar.Component) -> Bool { cal.isDate(a, equalTo: ici, toGranularity: c) }
        let court = Date.FormatStyle().day().month(.abbreviated)
        switch etat.unite {
        case .jour:
            if cal.isDateInToday(a) { return L("Aujourd'hui") }
            if cal.isDateInYesterday(a) { return L("Hier") }
            return a.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .semaine:
            if en(.weekOfYear) { return L("Cette semaine") }
            if let s = cal.date(byAdding: .weekOfYear, value: -1, to: ici), cal.isDate(a, equalTo: s, toGranularity: .weekOfYear) { return L("Semaine dernière") }
            let fin = cal.date(byAdding: .day, value: 6, to: a)!
            return "\(a.formatted(.dateTime.day())) – \(fin.formatted(court))"
        case .mois:
            if en(.month) { return L("Ce mois") }
            let m = a.formatted(.dateTime.month(.wide).year())
            return m.prefix(1).uppercased() + m.dropFirst()
        case .trimestre:
            let t = (cal.component(.month, from: a) - 1) / 3 + 1
            return cal.isDate(a, equalTo: ici, toGranularity: .year) && cal.component(.month, from: ici) >= t * 3 - 2 && cal.component(.month, from: ici) <= t * 3
                ? L("Ce trimestre") : "T\(t) \(cal.component(.year, from: a))"
        case .annee:
            return en(.year) ? L("Cette année") : "\(cal.component(.year, from: a))"
        case .plage:
            return "\(a.formatted(court)) – \(b.formatted(court))"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { etat.decalerPeriode(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            Button { ouvert.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    Text(libelle).monospacedDigit().lineLimit(1)
                }
                .frame(width: 150).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(etat.bornesUnite.0 == etat.bornesUnite.1 ? etat.bornesUnite.0.formatted(date: .complete, time: .omitted)
                  : "\(etat.bornesUnite.0.formatted(date: .long, time: .omitted)) – \(etat.bornesUnite.1.formatted(date: .long, time: .omitted))")
            .popover(isPresented: $ouvert, arrowEdge: .bottom) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        raccourci("Aujourd'hui", .jour)
                        raccourci("Hier", .jour, recul: 1)
                        Divider().padding(.vertical, 3)
                        raccourci("Cette semaine", .semaine)
                        raccourci("Semaine dernière", .semaine, recul: 1)
                        Divider().padding(.vertical, 3)
                        raccourci("Ce mois", .mois)
                        raccourci("Mois dernier", .mois, recul: 1)
                        Divider().padding(.vertical, 3)
                        raccourci("Ce trimestre", .trimestre)
                        raccourci("Cette année", .annee)
                    }
                    .frame(width: 160)
                    Divider()
                    CalendrierPlage { a, b in etat.choisirPlage(a, b); ouvert = false }
                }
                .padding(12)
            }
            Button { etat.decalerPeriode(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(etat.periodeFinitAujourdhui)
                .opacity(etat.periodeFinitAujourdhui ? 0.3 : 1)
        }
        .padding(.horizontal, 4)
    }

    func raccourci(_ titre: String, _ u: Etat.Unite, recul: Int = 0) -> some View {
        LigneChoix(texte: L(titre)) { etat.raccourci(u, recul: recul); ouvert = false }
    }
}

/// Un mois en grille : un clic choisit le début, un deuxième la fin (le même jour deux fois : ce jour seul).
/// La période en cours y est surlignée.
struct CalendrierPlage: View {
    @EnvironmentObject var etat: Etat
    let choisir: (Date, Date) -> Void
    @State private var mois = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var debut: Date?
    @State private var survol: Date?

    var cal: Calendar { Calendar.current }
    var jours: [Date?] {
        let premier = mois
        let decalage = (cal.component(.weekday, from: premier) - cal.firstWeekday + 7) % 7
        let n = cal.range(of: .day, in: .month, for: premier)!.count
        return Array(repeating: nil, count: decalage) + (0..<n).map { cal.date(byAdding: .day, value: $0, to: premier) }
    }
    var entetes: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    func dansPlage(_ d: Date) -> Bool {
        if let a = debut {
            let b = survol ?? a
            return d >= min(a, b) && d <= max(a, b)
        }
        let (a, b) = etat.bornesUnite
        return d >= a && d <= b
    }

    var body: some View {
        let aujourdhui = cal.startOfDay(for: Date())
        VStack(spacing: 8) {
            HStack {
                Button { mois = cal.date(byAdding: .month, value: -1, to: mois)! } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text({ let m = mois.formatted(.dateTime.month(.wide).year()); return m.prefix(1).uppercased() + m.dropFirst() }())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { mois = cal.date(byAdding: .month, value: 1, to: mois)! } label: { Image(systemName: "chevron.right") }
                    .disabled(mois >= cal.dateInterval(of: .month, for: aujourdhui)!.start)
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(entetes.enumerated()), id: \.offset) { _, e in
                    Text(e).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                ForEach(Array(jours.enumerated()), id: \.offset) { _, j in
                    if let j {
                        let futur = j > aujourdhui
                        let dedans = dansPlage(j)
                        Text("\(cal.component(.day, from: j))")
                            .font(.system(size: 12, weight: cal.isDateInToday(j) ? .bold : .regular)).monospacedDigit()
                            .frame(width: 30, height: 26)
                            .foregroundStyle(futur ? AnyShapeStyle(.quaternary) : dedans ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                            .background(RoundedRectangle(cornerRadius: 6).fill(dedans ? Color.accentColor : .clear))
                            .contentShape(Rectangle())
                            .onHover { if $0 && !futur { survol = j } }
                            .onTapGesture {
                                guard !futur else { return }
                                if let a = debut { debut = nil; choisir(a, j) } else { debut = j }
                            }
                    } else {
                        Color.clear.frame(width: 30, height: 26)
                    }
                }
            }
        }
        .frame(width: 230)
        .onAppear { mois = cal.dateInterval(of: .month, for: etat.bornesUnite.1)!.start }
    }
}

/// Un morceau continu du ruban : des tranches qui se suivent dans la même catégorie.
struct Segment: Identifiable {
    let debut: Double
    var fin: Double
    let tranche: Tranche
    var secondes: Double
    var contextes: [String: Double]
    var id: Double { debut }
}

/// La journée du Mac en un ruban horizontal, coloré par projet, dessiné d'un seul bloc ; le survol donne le détail.
struct RubanJour: View {
    @EnvironmentObject var etat: Etat
    @State private var survol: Double?
    static let pas = 300.0

    var bornes: (Double, Double) {
        let j = etat.jourFrise.timeIntervalSince1970
        let ts = etat.frise?.tranches.map(\.t) ?? []
        let a = ts.min().map { floor(($0 - j) / 3600) * 3600 + j } ?? j + 8 * 3600
        let b = ts.max().map { ceil(($0 + RubanJour.pas - j) / 3600) * 3600 + j } ?? j + 19 * 3600
        return (Swift.min(a, j + 8 * 3600), Swift.max(b, j + 20 * 3600))
    }

    var segments: [Segment] {
        var out: [Segment] = []
        for t in (etat.frise?.tranches ?? []).sorted(by: { $0.t < $1.t }) {
            if var d = out.last, d.tranche.cle == t.cle, abs(d.fin - t.t) < 1 {
                d.fin = t.t + RubanJour.pas
                d.secondes += t.secondes
                d.contextes[t.contexte, default: 0] += t.secondes
                out[out.count - 1] = d
            } else {
                out.append(Segment(debut: t.t, fin: t.t + RubanJour.pas, tranche: t, secondes: t.secondes, contextes: [t.contexte: t.secondes]))
            }
        }
        return out
    }

    func resume(_ d: Segment) -> String {
        let nom = d.tranche.famille == nonClasse ? L(nonClasse) : d.tranche.nom
        let ctx = d.contextes.max { $0.value < $1.value }?.key ?? ""
        return "\(heureMinute(d.debut))–\(heureMinute(d.fin)) · \(nom) · \(duree(d.secondes))" + (ctx.isEmpty ? "" : " · \(ctx)")
    }

    var body: some View {
        let segs = segments
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { etat.decalerPeriode(-1) } label: { Image(systemName: "chevron.left") }
                Text(etat.jourFrise.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                Button { etat.decalerPeriode(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(Calendar.current.isDateInToday(etat.jourFrise))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)

            ruban(segs).padding(.horizontal, 8)

            Text(survol.flatMap { t in segs.first { $0.debut <= t && t < $0.fin } }.map(resume) ?? " ")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                .padding(.horizontal, 8)
        }
        .task(id: etat.jourFrise) { await etat.chargerFrise() }
    }

    func ruban(_ segs: [Segment]) -> some View {
        let (a, b) = bornes
        let couleurs = segs.map { couleurTranche($0.tranche) }
        let fond = Color.primary.opacity(0.05)
        let trait = Color.primary.opacity(0.15)
        let pointe = survol
        return GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) in CGFloat((t - a) / (b - a)) * w }
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 2, width: w, height: 28), cornerRadius: 4), with: .color(fond))
                for (i, d) in segs.enumerated() {
                    let dedans = pointe.map { d.debut <= $0 && $0 < d.fin } ?? false
                    let r = CGRect(x: x(d.debut), y: dedans ? 0 : 2, width: Swift.max(1, x(d.fin) - x(d.debut) - 1), height: dedans ? 32 : 28)
                    ctx.fill(Path(r), with: .color(couleurs[i]))
                }
                var h = a
                while h <= b {
                    ctx.fill(Path(CGRect(x: x(h), y: 33, width: 1, height: 5)), with: .color(trait))
                    if Int((h - a) / 3600) % 2 == 0 {
                        ctx.draw(Text(heureMinute(h)).font(.system(size: 10)).foregroundStyle(.tertiary), at: CGPoint(x: x(h), y: 47))
                    }
                    h += 3600
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let pt) = phase { survol = a + Double(pt.x / w) * (b - a) } else { survol = nil }
            }
        }
        .frame(height: 54)
    }
}

/// Une ligne de la file : l'icône de l'app, ce qu'on range, la suggestion en pastille de la couleur de son projet, la durée.
struct LigneAClasser: View {
    @EnvironmentObject var etat: Etat
    let d: Detail
    let choisie: Bool
    let choisir: () -> Void
    @State private var survol = false

    var suggestion: (nom: String, couleur: Color)? {
        guard let s = d.suggestion, let c = etat.categories.first(where: { $0.cle == s }) else { return nil }
        return (c.feuille, couleurSerie(serie(cle: c.cle, nom: c.nom, famille: c.famille)))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icone = Apps.partage.icone(d.app) {
                    Image(nsImage: icone).resizable()
                } else {
                    Image(systemName: iconeAppareil(d.appareil)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.contexte.isEmpty ? d.nomApp : d.contexte).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(duree(d.secondes)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text([d.contexte.isEmpty ? nil : d.nomApp, d.appareil == "Mac" ? nil : d.appareil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if let s = suggestion {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkle").font(.system(size: 8))
                            Text(s.nom).lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(s.couleur)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(s.couleur.opacity(0.15)))
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            choisie ? Color.orange.opacity(0.16) : Color.primary.opacity(survol ? 0.05 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(choisie ? Color.orange.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture(perform: choisir)
    }
}

/// La file de rattrapage : les lignes non classées, de la plus longue à la plus courte, et l'écran Classer à côté.
struct VueAClasser: View {
    @EnvironmentObject var etat: Etat

    var body: some View {
        let file = etat.aRattraper
        let total = file.reduce(0) { $0 + $1.secondes }
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(duree(total)).font(.system(size: 34, weight: .semibold)).tracking(-0.6).monospacedDigit()
                        .foregroundStyle(total > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    Text(L("non classées, en %d lignes", file.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                let suggerees = file.filter { $0.suggestion != nil }
                if !suggerees.isEmpty {
                    Button { Task { await etat.accepterSuggestions(suggerees) } } label: {
                        Label(L("Accepter les %d suggestions", suggerees.count), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Carte {
                    Etiquette(texte: "À classer", compte: file.count)
                    ScrollViewReader { lecteur in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(file) { d in
                                    LigneAClasser(d: d, choisie: d.id == etat.aClasserCourant?.id) { etat.rattraper(depuis: d) }
                                        .id(d.id)
                                }
                            }
                        }
                        .onChange(of: etat.aClasserCourant?.id) { _, id in
                            if let id { withAnimation { lecteur.scrollTo(id, anchor: .center) } }
                        }
                    }
                }
                .frame(width: 340)
                Carte {
                    if let d = etat.aClasserCourant {
                        ScrollView { EcranClasser(d: d, enFile: true).padding(.horizontal, 8) }.id(d.id)
                    } else {
                        Text(file.isEmpty ? L("Tout est classé.") : L("Choisis une ligne."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .onAppear { if etat.aClasserCourant == nil { etat.rattraper() } }
        .onChange(of: etat.famillesFenetre.count) { if etat.aClasserCourant == nil { etat.rattraper() } }
    }
}

// MARK: - État de la fenêtre

extension Etat {
    func chargerFrise() async {
        do {
            let url = URL(string: "http://127.0.0.1:8230/frise?jour=\(jourFrise.timeIntervalSince1970)")!
            let (d, _) = try await URLSession.shared.data(from: url)
            frise = try JSONDecoder().decode(Frise.self, from: d)
        } catch {
            erreurFenetre = L("Serveur injoignable sur le port 8230. Journal : ~/Library/Application Support/Temps/journal.log")
        }
    }

    /// Le premier et le dernier jour de la période (unité autour de l'ancre, ou plage libre) ; la fin ne dépasse pas aujourd'hui.
    var bornesUnite: (Date, Date) {
        let cal = Calendar.current, aujourdhui = cal.startOfDay(for: Date())
        func intervalle(_ c: Calendar.Component) -> (Date, Date) {
            let i = cal.dateInterval(of: c, for: ancre)!
            return (i.start, min(cal.date(byAdding: .day, value: -1, to: i.end)!, aujourdhui))
        }
        switch unite {
        case .jour: return (ancre, ancre)
        case .semaine: return intervalle(.weekOfYear)
        case .mois: return intervalle(.month)
        case .annee: return intervalle(.year)
        case .trimestre:
            let m = cal.component(.month, from: ancre), y = cal.component(.year, from: ancre)
            let debut = cal.date(from: DateComponents(year: y, month: (m - 1) / 3 * 3 + 1, day: 1))!
            let fin = cal.date(byAdding: DateComponents(month: 3, day: -1), to: debut)!
            return (debut, min(fin, aujourdhui))
        case .plage: return (plageDebut, min(plageFin, aujourdhui))
        }
    }

    var periodeFinitAujourdhui: Bool { bornesUnite.1 >= Calendar.current.startOfDay(for: Date()) }

    /// Règle la période d'après l'unité et l'ancre, en un seul chargement.
    func appliquerPeriode() {
        let (a, b) = bornesUnite
        enLot = true
        if a == b {
            jourFrise = a
            periodeFenetre = Etat.jourSeul
        } else {
            debutLibre = a
            finLibre = b
            periodeFenetre = Etat.datesLibres
        }
        enLot = false
        Task { await chargerFenetre() }
    }

    /// Recule (-1) ou avance (+1) d'une période entière : jour, semaine, mois, trimestre, année, ou la même durée.
    func decalerPeriode(_ sens: Int) {
        let cal = Calendar.current, aujourdhui = cal.startOfDay(for: Date())
        if unite == .plage {
            let n = (cal.dateComponents([.day], from: plageDebut, to: plageFin).day ?? 0) + 1
            plageDebut = cal.date(byAdding: .day, value: sens * n, to: plageDebut)!
            plageFin = min(cal.date(byAdding: .day, value: sens * n, to: plageFin)!, aujourdhui)
        } else {
            let pas: DateComponents = switch unite {
                case .jour: DateComponents(day: sens)
                case .semaine: DateComponents(weekOfYear: sens)
                case .mois: DateComponents(month: sens)
                case .trimestre: DateComponents(month: 3 * sens)
                default: DateComponents(year: sens)
            }
            ancre = min(cal.date(byAdding: pas, to: ancre)!, aujourdhui)
        }
        appliquerPeriode()
    }

    /// Un raccourci : l'unité autour d'aujourd'hui, décalée de `recul` crans (hier, la semaine dernière…).
    func raccourci(_ u: Unite, recul: Int = 0) {
        unite = u
        ancre = Calendar.current.startOfDay(for: Date())
        if recul != 0 { decalerPeriode(-recul) } else { appliquerPeriode() }
    }

    func choisirPlage(_ a: Date, _ b: Date) {
        let cal = Calendar.current
        let (d, f) = (cal.startOfDay(for: min(a, b)), cal.startOfDay(for: max(a, b)))
        if d == f { unite = .jour; ancre = d } else { unite = .plage; plageDebut = d; plageFin = f }
        appliquerPeriode()
    }

    func allerA(_ d: Date, unite u: Unite? = nil) {
        if let u { unite = u }
        ancre = min(Calendar.current.startOfDay(for: d), Calendar.current.startOfDay(for: Date()))
        appliquerPeriode()
    }

    func chargerFenetre() async {
        chargementFenetre += 1
        let n = chargementFenetre, q = requetePeriode, p = periodeFenetre
        do {
            async let fen = URLSession.shared.data(from: URL(string: "http://127.0.0.1:8230/fenetre?\(q)")!)
            async let api = lire(p, requete: q)
            let r = try JSONDecoder().decode(ReponseFenetre.self, from: try await fen.0)
            let a = try await api
            guard n == chargementFenetre else { return }
            erreurFenetre = r.erreur
            fiches = r.projets ?? []
            reperesTous = r.reperes ?? []
            moisDispos = r.mois ?? []
            histoLong = r.histogramme ?? []
            facturableFenetre = r.facturable ?? 0
            famillesFenetre = a.familles ?? []
            aRattraper = (famillesFenetre.first { $0.nom == nonClasse }?.postes ?? []).flatMap(\.detail)
                .filter(\.classable).sorted { $0.secondes > $1.secondes }
            secondesFenetre = Dictionary((a.familles ?? []).flatMap(\.postes).map { ($0.cle, $0.secondes) }, uniquingKeysWith: +)
            if projetChoisi != nil { Task { await chargerProjet() } }
            travailFenetre = a.travail ?? 0
        } catch {
            if n == chargementFenetre { erreurFenetre = L("Serveur injoignable sur le port 8230.") }
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
    /// Toujours visible comme un champ (dans une fiche) ; sinon il ne se révèle qu'au survol (dans un tableau).
    var cadre = false
    let valider: (Double?) -> Void
    @State private var texte = ""
    @State private var survol = false
    @State private var edite = false
    @FocusState private var focus: Bool

    func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)).replacingOccurrences(of: ".", with: ",")
    }

    /// Un simple texte tant qu'on ne clique pas : un vrai champ de saisie par cellule alourdit le défilement.
    var body: some View {
        HStack(spacing: 3) {
            if edite {
                TextField("", text: $texte)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus)
                    .onSubmit { envoyer(); edite = false }
                    .onChange(of: focus) { _, f in if !f { envoyer(); edite = false } }
                    .onAppear { texte = format(valeur); focus = true }
            } else {
                Text(format(valeur)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !suffixe.isEmpty && (valeur != nil || edite) { Text(suffixe).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .padding(.vertical, cadre ? 2 : 0)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(edite ? 0.09 : survol ? 0.07 : cadre ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { survol = $0 }
        .onTapGesture { edite = true }
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
    var choisi: Double? = nil
    var choisir: ((Double) -> Void)? = nil
    @State private var survol: Double?

    /// La fiche d'un jour, au survol : date, travail, et chaque série avec sa couleur.
    func fiche(_ j: Jour) -> some View {
        let parts = (j.parts ?? [:]).filter { $0.value >= 60 }.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            Text(Date(timeIntervalSince1970: j.jour).formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                .font(.system(size: 12, weight: .semibold))
            Text(L("%@ de travail", duree(j.travail))).font(.system(size: 11)).foregroundStyle(.secondary)
            if !parts.isEmpty { Divider().padding(.vertical, 1) }
            ForEach(parts.prefix(8), id: \.key) { k, v in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(couleurSerie(k)).frame(width: 8, height: 8)
                    Text(L(libelleSerie(k))).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(duree(v)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .allowsHitTesting(false)
    }

    var body: some View {
        let max = Swift.max(jours.map(\.travail).max() ?? 0, 3600)
        let f: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM"); return f }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: jours.count > 40 ? 1 : 3) {
                ForEach(Array(jours.enumerated()), id: \.element.id) { i, j in
                    let date = Date(timeIntervalSince1970: j.jour)
                    let weekend = [1, 7].contains(Calendar.current.component(.weekday, from: date))
                    let dessus = survol == j.jour
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(dessus ? 0.1 : weekend ? 0.06 : 0.025))
                        BarreEmpilee(parts: j.parts ?? [:], hauteur: 90, max: max)
                    }
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if let c = choisi, Calendar.current.isDate(Date(timeIntervalSince1970: c), inSameDayAs: date) {
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(height: 2).offset(y: 5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { choisir?(j.jour) }
                    .onHover { dedans in survol = dedans ? j.jour : (survol == j.jour ? nil : survol) }
                    .overlay(alignment: i < jours.count / 3 ? .topLeading : i >= jours.count * 2 / 3 ? .topTrailing : .top) {
                        if dessus { fiche(j).fixedSize().offset(y: 96) }
                    }
                    .zIndex(dessus ? 1 : 0)
                }
            }
            .frame(height: 90, alignment: .bottom)
            .zIndex(1)
            HStack {
                if let a = jours.first { Text(f.string(from: Date(timeIntervalSince1970: a.jour))) }
                Spacer()
                if let b = jours.last { Text(f.string(from: Date(timeIntervalSince1970: b.jour))) }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .zIndex(1)
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
                        Text(etat.joursPeriode == 1
                             ? L("de travail ce jour-là, dont %@ facturables", duree(etat.facturableFenetre))
                             : L("de travail sur %d jours, soit %@ par jour, dont %@ facturables", etat.joursPeriode,
                                 duree(etat.travailFenetre / Double(etat.joursPeriode)), duree(etat.facturableFenetre)))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if etat.periodeFenetre == Etat.jourSeul {
                    Carte { RubanJour() }
                } else {
                    HistogrammeLong(jours: etat.histoLong, choisi: nil) { j in
                        etat.allerA(Date(timeIntervalSince1970: j), unite: .jour)
                    }
                }
                if !etat.reperesTous.isEmpty {
                    Carte {
                        Etiquette(texte: "Cette semaine")
                        ForEach(etat.reperesTous) { LigneRepere(r: $0) }
                    }
                }
                if let n = famille(nonClasse), let poste = n.postes.first {
                    CarteNonClasse(poste: poste, max: famille(projets)?.postes.first?.secondes ?? poste.secondes) {
                        etat.rubriqueDemandee = Rubrique.aClasser.rawValue
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    // une carte par domaine
                    VStack(spacing: 16) {
                        if let p = famille(projets) {
                            ForEach(etat.domainesAvec(p.postes, famille: projets), id: \.self) { d in
                                Carte { ListeDomaines(postes: p.postes, max: p.postes.first?.secondes ?? 1, domaine: d) }
                            }
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
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct VueBilan: View {
    @EnvironmentObject var etat: Etat
    func ouvrir(_ f: Fiche) {
        etat.projetChoisi = f.cle
        etat.rubriqueDemandee = Rubrique.projets.rawValue
    }
    var body: some View {
        let archives = Set(etat.categories.filter(\.archivee).map(\.cle))
        let fiches = etat.fiches.filter(\.aBilan)
        let enCours = fiches.filter { !archives.contains($0.cle) }
        let archivees = fiches.filter { archives.contains($0.cle) }
        let grille = [GridItem(.adaptive(minimum: 300), spacing: 16)]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: grille, spacing: 16) {
                    ForEach(enCours) { f in CarteBilan(f: f).onTapGesture { ouvrir(f) } }
                }
                if !archivees.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "archivebox").font(.system(size: 12))
                        Text("Archivés").font(.system(size: 12, weight: .semibold))
                        Text("\(archivees.count)").font(.system(size: 11)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    LazyVGrid(columns: grille, spacing: 16) {
                        ForEach(archivees) { f in CarteBilan(f: f).opacity(0.65).onTapGesture { ouvrir(f) } }
                    }
                }
            }
            .padding(24)
        }
    }
}

/// La fenêtre : trois vues en onglets dans la barre de titre, et À classer en pastille orange
/// tant qu'il reste quelque chose à classer.
struct FenetrePrincipale: View {
    @EnvironmentObject var etat: Etat
    @State private var rubrique: Rubrique = .ensemble
    init(rubrique r: Rubrique? = nil) { _rubrique = State(initialValue: r ?? .ensemble) }

    var onglets: [Rubrique] {
        [.ensemble, .projets] + (etat.fiches.contains(where: \.aBilan) ? [.bilan] : [])
    }

    var body: some View {
        VStack(spacing: 0) {
            if let e = etat.erreurFenetre {
                Text(e).font(.callout).foregroundStyle(.orange).padding(10)
            }
            switch rubrique {
            case .ensemble: VueEnsemble()
            case .aClasser: VueAClasser()
            case .projets: VueProjets()
            case .bilan: VueBilan()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VerreDeFenetre().ignoresSafeArea())
        .navigationTitle("Temps")
        .modifier(SansTitre())
        .toolbar {
            // un seul groupe, à droite : la période (qui vaut pour toutes les vues), les vues, et À classer
            // À classer à gauche, les vues au centre, la période à droite. Pas de fond maison :
            // la barre de titre de macOS dessine déjà la capsule de chaque contrôle.
            ToolbarItem(placement: .navigation) {
                // À classer : une simple icône ronde, là seulement quand il reste quelque chose
                if !etat.aRattraper.isEmpty {
                    let actif = rubrique == .aClasser
                    let reste = etat.aRattraper.reduce(0) { $0 + $1.secondes }
                    Button { rubrique = actif ? .ensemble : .aClasser } label: {
                        Image(systemName: actif ? "tray.full.fill" : "tray.full")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(actif ? Color.white : Color.orange)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(actif ? Color.orange : Color.orange.opacity(0.16)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("À classer : %@ en %d lignes", duree(reste), etat.aRattraper.count))
                }
            }
            .sansCapsule()
            ToolbarItem(placement: .principal) {
                // une capsule de groupe et une pastille de sélection de même forme, avec le même retrait partout
                HStack(spacing: 2) {
                    ForEach(onglets) { r in
                        let actif = rubrique == r
                        Button { rubrique = r } label: {
                            Label(L(r.rawValue), systemImage: r.icone)
                                .labelStyle(.titleAndIcon)
                                .fontWeight(actif ? .semibold : .regular)
                                .padding(.horizontal, 12).frame(height: 26)
                                .background(Capsule().fill(Color.primary.opacity(actif ? 0.1 : 0)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .modifier(CapsuleDeVerre())
                .fixedSize()
            }
            .sansCapsule()
            ToolbarItem(placement: .primaryAction) { ChoixPeriode() }
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
            if !CommandLine.arguments.contains("--apercu") { NSApp.setActivationPolicy(.regular) }
            activer()
        }
        .onDisappear {
            etat.fenetreOuverte = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: etat.aRattraper.isEmpty) { _, vide in
            if vide && rubrique == .aClasser { rubrique = .ensemble }
        }
        .onChange(of: rubrique) { _, r in if r == .aClasser && etat.aClasserCourant == nil { etat.rattraper() } }
        .onChange(of: etat.rubriqueDemandee) { _, r in
            if let r, let x = Rubrique(rawValue: r) { rubrique = x; etat.rubriqueDemandee = nil }
        }
        .onAppear { if let r = CommandLine.arguments.first(where: { $0.hasPrefix("--rubrique=") }) {
            rubrique = Rubrique.allCases.first { $0.rawValue == String(r.dropFirst(11)) } ?? .ensemble } }
    }
}

/// Le titre de la fenêtre laisse sa place à la période et aux onglets (macOS 15 et plus ; sur 14, il reste).
struct SansTitre: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}

/// La capsule du groupe d'onglets : du verre sur macOS 26, un matériau avant.
struct CapsuleDeVerre: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.regularMaterial)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

extension ToolbarItem {
    /// Sur macOS 26, les onglets se passent de la grande capsule de verre qui les englobait : seule la pastille
    /// de la vue active reste. Avant macOS 26, rien ne change.
    @ToolbarContentBuilder func sansCapsule() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}
