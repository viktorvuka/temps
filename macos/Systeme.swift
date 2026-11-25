import SwiftUI

// Le système visuel de Temps : cinq tailles de texte, quatre rayons, une grille de 4 pt,
// trois styles de bouton (plein, lien, pastille) et la ligne de liste. Un écran n'invente
// ni taille, ni rayon, ni bouton : il prend ici.

extension Font {
    /// 28 semibold, chiffres tabulaires : le grand total d'une vue, un seul par vue.
    static let affichage = Font.system(size: 28, weight: .semibold).monospacedDigit()
    /// 17 semibold : nom d'un projet en tête de fiche, ce qu'on range dans Classer.
    static let titre = Font.system(size: 17, weight: .semibold)
    /// 13 : listes, valeurs, champs, liens.
    static let corps = Font.system(size: 13)
    /// 13 semibold : en-têtes de domaine, élément actif, bouton plein.
    static let corpsFort = Font.system(size: 13, weight: .semibold)
    /// 11 : sous-titres, durées en marge, pastilles, raisons.
    static let secondaire = Font.system(size: 11)
    /// 10 medium : axes, familles au-dessus d'une liste, compteurs.
    static let legende = Font.system(size: 10, weight: .medium)
}

enum Rayon {
    static let petit: CGFloat = 4
    static let moyen: CGFloat = 8
    static let grand: CGFloat = 12
}

enum Espace {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s6: CGFloat = 24, s8: CGFloat = 32
}

extension Color {
    /// Texte secondaire lisible (AA, ≥ 4,5:1) : celui de macOS en sombre, un noir à 58 % en clair
    /// (le gris secondaire du système tombe à 3,95:1 en clair, le tertiaire à 1,9:1).
    static let texteDiscret = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .secondaryLabelColor : NSColor.black.withAlphaComponent(0.58)
    })
    /// L'orange du signal, pour du texte : assombri en clair pour rester lisible (5,6:1).
    static let signal = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemOrange : NSColor.systemOrange.blended(withFraction: 0.45, of: .black) ?? .systemOrange
    })
    /// Fond des cartes posées sur le verre.
    static let voile = Color.primary.opacity(0.045)
    static let survol = Color.primary.opacity(0.06)
    static let appui = Color.primary.opacity(0.12)
    static let selection = Color.accentColor.opacity(0.16)
    /// Fond d'une petite capsule d'information (nature d'un domaine, autre nom, date de départ).
    static let fondPastille = Color.primary.opacity(0.07)
    /// Bord et fond de ce qui signale (carte Non classé, carte des accès, ligne choisie d'À classer).
    static let bordSignal = Color.orange.opacity(0.35)
    static let fondSignal = Color.orange.opacity(0.14)
}

/// L'ombre unique de ce qui flotte au-dessus du contenu (calques, fiches au survol, barre Annuler).
extension View {
    func ombreFlottante() -> some View { shadow(color: .black.opacity(0.25), radius: 18, y: 6) }
}

// MARK: - Boutons

/// Bouton plein : un seul par vue, pour le geste le plus probable, sur Entrée.
struct StylePlein: ButtonStyle {
    @Environment(\.isEnabled) private var actif
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.corpsFort)
            .foregroundStyle(.white)
            .padding(.vertical, 6).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: Rayon.moyen)
                .fill(Color.accentColor.opacity(!actif ? 0.4 : configuration.isPressed ? 0.8 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: Rayon.moyen))
    }
}

/// Lien : texte en couleur de lien, un fond discret au survol, plus marqué à l'appui.
struct StyleLien: ButtonStyle {
    var couleur: Color = .lien
    func makeBody(configuration: Configuration) -> some View {
        AvecSurvolStyle { survol in
            configuration.label
                .foregroundStyle(couleur)
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: Rayon.petit)
                    .fill(configuration.isPressed ? Color.appui : survol ? Color.survol : .clear))
                .contentShape(Rectangle())
        }
    }
}

/// Pastille : capsule en 11 medium, fond voile ; choisie, fond accent et texte blanc.
struct StylePastille: ButtonStyle {
    var choisie = false
    func makeBody(configuration: Configuration) -> some View {
        AvecSurvolStyle { survol in
            configuration.label
                .font(.system(size: 11, weight: choisie ? .semibold : .medium))
                .foregroundStyle(choisie ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.texteDiscret))
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(Capsule().fill(choisie
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                    : configuration.isPressed ? Color.appui : survol ? Color.primary.opacity(0.1) : Color.voile))
                .contentShape(Capsule())
        }
    }
}

/// L'état de survol propre à un style de bouton (un ButtonStyle n'a pas d'état à lui).
struct AvecSurvolStyle<Contenu: View>: View {
    @ViewBuilder let contenu: (Bool) -> Contenu
    @State private var survol = false
    var body: some View { contenu(survol).onHover { survol = $0 } }
}

// MARK: - Lignes

/// Une ligne de liste cliquable sur toute sa largeur : rien au repos, teinte au survol, plus forte à l'appui.
struct StyleLigne: ButtonStyle {
    var choisie = false
    func makeBody(configuration: Configuration) -> some View {
        AvecSurvolStyle { survol in
            configuration.label
                .padding(.vertical, 4).padding(.horizontal, 8)
                .frame(minHeight: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Rayon.moyen).fill(
                    configuration.isPressed ? Color.appui : choisie ? Color.selection : survol ? Color.survol : .clear))
                .contentShape(Rectangle())
        }
    }
}

/// Survol et appui pour une vue cliquable qui n'est pas un bouton (en-tête repliable, carte, barre).
struct Touchable: ViewModifier {
    var rayon: CGFloat = Rayon.moyen
    @State private var survol = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: rayon).fill(survol ? Color.survol : .clear))
            .contentShape(Rectangle())
            .onHover { survol = $0 }
    }
}

extension View {
    func touchable(rayon: CGFloat = Rayon.moyen) -> some View { modifier(Touchable(rayon: rayon)) }
}

/// Survol et appui pour un bouton qui garde son propre dessin (onglet, chevron, barre, icône) :
/// un fond discret derrière lui, de la forme donnée.
struct StyleTouche: ButtonStyle {
    enum Forme { case rectangle(CGFloat), capsule, cercle }
    var forme: Forme = .rectangle(Rayon.moyen)
    func makeBody(configuration: Configuration) -> some View {
        AvecSurvolStyle { survol in
            let teinte = configuration.isPressed ? Color.appui : survol ? Color.survol : Color.clear
            configuration.label
                .background {
                    switch forme {
                    case .rectangle(let r): RoundedRectangle(cornerRadius: r).fill(teinte)
                    case .capsule: Capsule().fill(teinte)
                    case .cercle: Circle().fill(teinte)
                    }
                }
                .brightness(configuration.isPressed ? -0.04 : 0)
        }
    }
}

// MARK: - Mouvement

/// Réduire les animations (réglage d'accessibilité de macOS) : plus aucun déplacement, des fondus courts seulement.
func mouvement(_ a: Animation) -> Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.12) : a
}

/// Ce qui glisse en temps normal ne fait plus qu'apparaître quand les animations sont réduites.
func glissement(_ bord: Edge) -> AnyTransition {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .opacity : .move(edge: bord).combined(with: .opacity)
}
