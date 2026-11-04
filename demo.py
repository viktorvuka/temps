"""Données fictives pour le mode démo (captures d'écran, essais) : TEMPS_DEMO=1.

Un studio de graphisme imaginaire, trois clients, un cours, une association. Les jours sont
générés de façon déterministe, pour que deux captures se ressemblent.
"""
import random
import time

REGLES_FR = """
[dossiers]
racines = []
[familles]
activites = ["Mail", "Admin", "Organisation"]
hors_travail = ["Perso", "Réseaux sociaux"]
[noms]
[alias]
[reperes]
"Studio" = { heures = 25 }
"Réseaux sociaux" = { plafond = 5 }
[projets]
"Studio / Atelier Nord" = { vendu = 100, montant = 7500, facturable = true }
"Studio / Maison Lumen" = { vendu = 60, montant = 4800, facturable = true }
"Studio / Café Brume" = { vendu = 50, montant = 2200, facturable = true }
[couleurs]
"Studio" = "bleu"
"Enseignement" = "jaune"
"Association" = "violet"
"Studio / Maison Lumen" = "ciel"
[chemins]
[titres]
[apps]
[ignorer]
bundles = []
"""
REGLES_EN = (REGLES_FR.replace('"Organisation"', '"Planning"').replace('"Perso"', '"Personal"')
             .replace('"Réseaux sociaux"', '"Social media"').replace('"Enseignement"', '"Teaching"')
             .replace('"Association"', '"Non-profit"'))

import report as rapport  # noqa: E402 (après les règles, que rapport lit au premier lancement)

FR = rapport.LANGUE == "fr"

# (catégorie, poids, [(appareil, app, contexte), …])
PROJETS = [
    ("Studio / Atelier Nord", 5, [("Mac", "com.adobe.InDesign", "Nord-catalogue-v4.indd"),
                                  ("Mac", "com.figma.Desktop", "Atelier Nord — site"),
                                  ("Mac", "com.apple.Safari", "ateliernord.fr")]),
    ("Studio / Maison Lumen", 4, [("Mac", "com.adobe.Illustrator", "Lumen-logo-pistes.ai"),
                                  ("Mac", "com.anthropic.claudefordesktop", "Charte Maison Lumen")]),
    ("Studio / Café Brume", 2, [("Mac", "com.adobe.Photoshop", "Brume-menu-hiver.psd"),
                                ("Mac", "com.apple.Safari", "cafebrume.com")]),
    ("Studio / Typographie" if FR else "Studio / Type foundry", 2, [("Mac", "com.glyphsapp.glyphs3", "Lumen Sans.glyphs")]),
    ("Enseignement / Typographie L3" if FR else "Teaching / Type design L3", 2,
     [("Mac", "com.apple.iWork.Keynote", "Cours 6 — la lettre.key" if FR else "Lesson 6 — letterforms.key")]),
    ("Association / Site web" if FR else "Non-profit / Website", 1, [("Mac", "com.microsoft.VSCode", "site-association")]),
]
ACTIVITES = [
    ("Mail", 2, [("Mac", "com.apple.mail", "contact@ateliernord.fr · Studio")]),
    ("Admin", 1, [("Mac", "com.apple.Safari", "impots.gouv.fr" if FR else "irs.gov")]),
    ("Organisation" if FR else "Planning", 1, [("Mac", "com.apple.iCal", "Calendrier" if FR else "Calendar")]),
]
HORS = [
    ("Réseaux sociaux" if FR else "Social media", 2, [("iPhone", "com.burbn.instagram", "")]),
    ("Perso" if FR else "Personal", 1, [("iPhone", "com.apple.MobileSMS", "")]),
]
NON_CLASSES = [
    ("Mac", "com.apple.Safari", "fonts.google.com"),
    ("Mac", "com.apple.finder", "Nord — livraison" if FR else "Nord — delivery"),
    ("Mac", "com.apple.Safari", "maisonlumen.com"),
    ("Mac", "com.anthropic.claudefordesktop", "Devis Café Brume" if FR else "Café Brume quote"),
    ("Mac", "com.apple.Preview", "Lumen-retours.pdf" if FR else "Lumen-feedback.pdf"),
]


def jours(debut):
    sortie = {}
    fin = time.time()
    j = rapport.minuit(max(debut, fin - 90 * rapport.JOUR))  # trois mois d'historique fictif
    while j < fin:
        rnd = random.Random(int(j))
        semaine = time.localtime(j).tm_wday < 5
        c = rapport.Collecte()
        heures_travail = rnd.uniform(4.5, 7.5) if semaine else rnd.uniform(0, 1.2)
        if j == rapport.minuit(fin):
            heures_travail *= min(1, (fin - j) / 3600 / 18)
        familles = [(PROJETS, 0.68), (ACTIVITES, 0.14)]
        for liste, part in familles:
            total = sum(p for _, p, _ in liste)
            for cle, poids, contextes in liste:
                sec = heures_travail * 3600 * part * poids / total * rnd.uniform(0.3, 1.7)
                for k, (ap, app, ctx) in enumerate(contextes):
                    c.tot[cle] += sec / len(contextes)
                    c.detail[cle][(ap, app, ctx)] += sec / len(contextes)
        for ap, app, ctx in NON_CLASSES:
            sec = heures_travail * 3600 * 0.18 / len(NON_CLASSES) * rnd.uniform(0.4, 1.6)
            c.tot[rapport.NON_CLASSE] += sec
            c.detail[rapport.NON_CLASSE][(ap, app, ctx)] += sec
        for cle, poids, contextes in HORS:
            sec = rnd.uniform(0.5, 1.5) * 3600 * poids / 2
            ap, app, ctx = contextes[0]
            c.tot[cle] += sec
            c.detail[cle][(ap, app, ctx)] += sec
        sortie[j] = c
        j = rapport.minuit(j + rapport.JOUR + 3600)
    return sortie
