"""Tests du classement : python3 -m unittest discover tests (depuis le dossier du code)."""
import os, sys, tempfile, time, unittest
from pathlib import Path

ICI = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ICI))
DOSSIER = Path(tempfile.mkdtemp())
REGLES = DOSSIER / "rules.toml"
REGLES.write_text(f"""
[dossiers]
racines = ["{DOSSIER}/Projets"]
intermediaires = ["Clients"]
racine_nom = "Racine"

[familles]
activites = ["Mail"]
hors_travail = ["Perso"]

[noms]

[titres]
"exemple.fr" = "Studio / Dupont"
"localhost:8463" = "Studio / Durand"

[apps]
"com.apple.mail" = "Mail"

[chemins]
"{DOSSIER}/Divers" = "Divers"

[projets]

[reperes]

[couleurs]

[ignorer]
bundles = ["com.apple.loginwindow"]

[plages]
"2026-11-10 14:00-17:00" = "Studio / Martin"
""")
os.environ["TEMPS_REGLES"] = str(REGLES)
os.environ.pop("TEMPS_DEMO", None)

import report as r  # noqa: E402
import rules  # noqa: E402
import biome  # noqa: E402


def heure(h, m=0):
    return time.mktime(time.strptime(f"2026-11-10 {h:02d}:{m:02d}", "%Y-%m-%d %H:%M"))


class Classement(unittest.TestCase):
    def test_dossier_de_projet(self):
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Projets/Studio/Clients/Dupont/a.indd"), "Studio / Dupont")
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Projets/Studio/Logo/a.ai"), "Studio / Logo")
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Projets/notes.md"), "Racine")

    def test_chemin_puis_titre_puis_app(self):
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Divers/a.txt"), "Divers")
        self.assertEqual(r.classer("com.apple.Safari", "", "https://www.exemple.fr/page"), "Studio / Dupont")
        self.assertEqual(r.classer("com.apple.mail", "", ""), "Mail")
        self.assertEqual(r.classer("com.inconnue", "", ""), r.NON_CLASSE)

    def test_regle_forcee_avant_le_dossier(self):
        f = f"{DOSSIER}/Projets/Studio/Clients/Dupont/fiche.indd"
        self.assertEqual(r.classer("x", "", f), "Studio / Dupont")
        r.REGLES["forcer"] = {"fiche.indd": "Studio / Logo"}
        try:
            self.assertEqual(r.classer("x", "", f), "Studio / Logo")
        finally:
            r.REGLES.pop("forcer")

    def test_familles(self):
        self.assertEqual(r.famille("Mail"), r.ACTIVITE)
        self.assertEqual(r.famille("Perso"), r.HORS)
        self.assertEqual(r.famille("Studio / Dupont"), r.PROJETS)
        self.assertEqual(r.famille(biome.INCONNU), r.HORS)  # la montre ne compte jamais comme du travail
        self.assertEqual(r.famille("iPhone"), r.HORS)


class Contexte(unittest.TestCase):
    def test_site_local_garde_port_et_titre(self):
        self.assertEqual(r.contexte("com.apple.Safari", "Admin", "http://localhost:8463/a"), "Admin — localhost:8463")
        self.assertEqual(r.contexte("com.apple.Safari", "", "http://localhost:8463/"), "localhost:8463")
        self.assertEqual(r.contexte("com.apple.Safari", "Titre", "https://www.exemple.fr/a"), "www.exemple.fr")

    def test_regle_sur_le_port(self):
        self.assertEqual(r.classer("com.apple.Safari", "", "http://localhost:8463/"), "Studio / Durand")

    def test_adresse_fichier_decodee_pour_l_affichage(self):
        self.assertEqual(r.chemin_fichier("file:///tmp/x/Donne%CC%81es%20A.numbers"), "/tmp/x/Données A.numbers")
        self.assertEqual(r.chemin_fichier("/tmp/x/a"), "/tmp/x/a")


class Plages(unittest.TestCase):
    def test_lecture(self):
        self.assertEqual(r.plages(), [(heure(14), heure(17), "Studio / Martin")])

    def test_plage_ne_range_que_le_non_classe(self):
        b = r.Brut()
        b.ajouter(heure(15), "Mac", "com.inconnue", 600)                 # non classé, dans la plage
        b.ajouter(heure(18), "Mac", "com.inconnue", 300)                 # non classé, hors plage
        b.ajouter(heure(15), "Mac", "com.apple.mail", 300)               # déjà rangé : la règle gagne
        b.ajouter(heure(15), "iPhone", "com.inconnue", 300)              # pas le Mac : la plage ne s'applique pas
        c = b.classer(r.plages())
        self.assertEqual(c.tot["Studio / Martin"], 600)
        self.assertEqual(c.tot[r.NON_CLASSE], 300)
        self.assertEqual(c.tot["Mail"], 300)
        self.assertEqual(c.tot["iPhone"], 300)

    def test_ignorer(self):
        b = r.Brut()
        b.ajouter(heure(10), "Mac", "com.apple.loginwindow", 600)
        self.assertEqual(dict(b.classer().tot), {})


class PlagesSaisies(unittest.TestCase):
    def test_la_plage_saisie_l_emporte_et_complete(self):
        b = r.Brut()
        t0 = 1_700_000_400
        b.ajouter(t0, "Mac", "com.apple.mail", 600)              # 10 min de Mail pendant la réunion
        b.ajouter(t0 + 7200, "Mac", "com.apple.mail", 300)       # 5 min après : reste dans Mail
        saisie = [{"id": "a", "debut": t0, "fin": t0 + 3600, "cle": "Studio / Dupont", "note": "Réunion"}]
        c = b.classer((), saisie)
        self.assertAlmostEqual(c.tot["Studio / Dupont"], 3600)  # la plage entière, sans double compte
        self.assertAlmostEqual(c.tot["Mail"], 300)
        self.assertIn(("Mac", "com.apple.mail", ""), {k[:2] + ("",) for k in c.detail["Studio / Dupont"]})
        self.assertAlmostEqual(c.detail["Studio / Dupont"][("Manuel", "manuel", "Réunion")], 3000)

    def test_un_autre_projet_reste_tel_quel(self):
        b = r.Brut()
        t0 = 1_700_000_400
        b.ajouter(t0, "Mac", "com.app", 600, titre="exemple.fr")   # rangé dans Studio / Dupont par son titre
        saisie = [{"id": "a", "debut": t0, "fin": t0 + 3600, "cle": "Studio / Martin", "note": ""}]
        c = b.classer((), saisie)
        self.assertAlmostEqual(c.tot["Studio / Dupont"], 600)
        self.assertAlmostEqual(c.tot["Studio / Martin"], 3000)    # pas de double compte


class Domaines(unittest.TestCase):
    def test_la_nature_du_domaine_donne_la_famille(self):
        self.assertEqual(r.famille("Studio / Dupont"), r.PROJETS)
        r.REGLES["domaines"] = {"Perso": {"nature": "hors_travail", "projets": ["Studio"]}}
        try:
            self.assertEqual(r.famille("Studio / Dupont"), r.HORS)
        finally:
            r.REGLES.pop("domaines")

    def test_ecriture_des_domaines(self):
        avant = REGLES.read_text()
        rules.ecrire_domaines([{"nom": "Studio", "nature": "projets", "projets": ["Logo", "Dupont"]},
                               {"nom": "Perso", "nature": "hors_travail", "projets": []}])
        import tomllib
        d = tomllib.loads(REGLES.read_text())["domaines"]
        self.assertEqual(list(d), ["Studio", "Perso"])
        self.assertEqual(d["Studio"]["projets"], ["Logo", "Dupont"])
        rules.restaurer(avant)


class Fusions(unittest.TestCase):
    def test_le_temps_fusionne_va_dans_la_cible(self):
        r.REGLES["fusions"] = {"Studio / Logo": "Studio / Dupont"}
        try:
            c = r.Collecte()
            c.ajouter("Mac", "x", 60, "", f"{DOSSIER}/Projets/Studio/Logo/a.ai")
            c.ajouter("Mac", "x", 30, "", f"{DOSSIER}/Projets/Studio/Clients/Dupont/b.indd")
            self.assertEqual(dict(r.en_fusions(c).tot), {"Studio / Dupont": 90})
        finally:
            r.REGLES.pop("fusions")


class Missions(unittest.TestCase):
    def test_le_temps_du_client_va_a_la_mission_du_jour(self):
        r.REGLES["missions"] = {"Studio / Dupont": {"Identité": "2026-01-01", "Site web": "2026-11-01"}}
        r.lire_missions()
        try:
            def jour(d):
                c = r.Collecte()
                c.ajouter("Mac", "com.apple.Safari", 60, "", "https://www.exemple.fr/")
                return dict(r.en_missions(c, time.mktime(time.strptime(d, "%Y-%m-%d"))).tot)
            self.assertEqual(jour("2026-11-10"), {"Studio / Dupont · Site web": 60})
            self.assertEqual(jour("2026-03-10"), {"Studio / Dupont · Identité": 60})
            self.assertEqual(jour("2025-12-31"), {"Studio / Dupont": 60})  # avant la première mission
            self.assertEqual(r.NOMS["Studio / Dupont · Site web"], "Studio / Dupont / Site web")
            self.assertEqual(r.famille("Studio / Dupont · Site web"), r.PROJETS)
        finally:
            r.REGLES.pop("missions")
            r.recharger()

    def test_une_mission_datee_prend_le_temps_du_projet(self):
        r.REGLES["missions"] = {"Studio / Dupont": {"Studio / Dupont / Site": "2026-11-01"}}
        r.lire_missions()
        try:
            c = r.Collecte()
            c.ajouter("Mac", "com.apple.Safari", 60, "", "https://www.exemple.fr/")
            self.assertEqual(dict(r.en_missions(c, time.mktime(time.strptime("2026-11-10", "%Y-%m-%d"))).tot), {"Studio / Dupont / Site": 60})
            c = r.Collecte()
            c.ajouter("Mac", "com.apple.Safari", 60, "", "https://www.exemple.fr/")
            self.assertEqual(dict(r.en_missions(c, time.mktime(time.strptime("2026-10-10", "%Y-%m-%d"))).tot), {"Studio / Dupont": 60})
        finally:
            r.REGLES.pop("missions")
            r.recharger()

    def test_ecriture_d_une_table_de_missions(self):
        rules.poser("missions", "Studio / Dupont", {"Site web": "2026-11-01", "Identité": "2026-01-01"})
        self.assertIn('"Site web" = "2026-11-01"', REGLES.read_text())
        rules.retirer("missions", "Studio / Dupont")


class Regles(unittest.TestCase):
    def test_poser_remplacer_retirer(self):
        self.assertIsNone(rules.poser("titres", "essai.fr", "Studio / Essai"))
        self.assertEqual(rules.remplacer("titres", "essai.fr", "essai.com", "Studio / Autre"), "Studio / Essai")
        texte = REGLES.read_text()
        self.assertIn('"essai.com" = "Studio / Autre"', texte)
        self.assertNotIn("essai.fr", texte)
        rules.retirer("titres", "essai.com")
        self.assertNotIn("essai.com", REGLES.read_text())

    def test_dossier_supprime_exclu(self):
        avant = REGLES.read_text()
        rules.supprimer("Studio / Logo")
        r.recharger()
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Projets/Studio/Logo/a.ai"), r.NON_CLASSE)
        self.assertEqual(r.classer("x", "", f"{DOSSIER}/Projets/Studio/Clients/Dupont/a.indd"), "Studio / Dupont")
        rules.restaurer(avant)
        r.recharger()

    def test_section_creee_au_besoin(self):
        rules.poser("archives", "Studio / Dupont", True)
        self.assertIn("[archives]", REGLES.read_text())
        rules.retirer("archives", "Studio / Dupont")


class Moteur(unittest.TestCase):
    def test_export_csv_garde_les_colonnes(self):
        c = r.Collecte()
        c.ajouter("Mac", "x", 7200, titre="exemple.fr")
        r.NOMS["Studio / Dupont"] = 'Dupont ; "affiche"'
        try:
            lignes = r.export_csv({heure(0): c}, "2026-11").splitlines()
        finally:
            del r.NOMS["Studio / Dupont"]
        self.assertEqual(len(lignes), 2)
        self.assertEqual(lignes[1].count(";"), 7)  # six séparateurs, plus celui du nom, resté entre guillemets
        self.assertIn('"Dupont ; ""affiche"""', lignes[1])

    def test_regles_sans_section_restent_lisibles(self):
        avant = REGLES.read_text()
        REGLES.write_text("[noms]\n")
        try:
            r.recharger()
            self.assertEqual(r.classer("com.apple.mail", "exemple.fr"), r.NON_CLASSE)
        finally:
            REGLES.write_text(avant)
            r.recharger()

    def test_la_demo_ecrit_dans_le_fichier_qu_elle_lit(self):
        import subprocess
        code = "import report, rules; print(report.fichier_regles() == rules.FICHIER)"
        env = {k: v for k, v in os.environ.items() if k != "TEMPS_REGLES"} | {"TEMPS_DEMO": "1", "HOME": str(DOSSIER)}
        sortie = subprocess.run([sys.executable, "-c", code], cwd=ICI, env=env, capture_output=True, text=True)
        self.assertEqual(sortie.stdout.strip(), "True", sortie.stderr)

    def test_le_serveur_ne_repond_qu_a_temps(self):
        import server

        class Requete:
            local = server.Gestion.local

            def __init__(self, **entetes):
                self.headers, self.refus = entetes, None

            def send_error(self, code):
                self.refus = code

        self.assertTrue(Requete(Host="127.0.0.1:8230").local())
        self.assertTrue(Requete(Host="localhost:8230", Origin="http://localhost:8230").local())
        self.assertFalse(Requete(Host="127.0.0.1:8230", Origin="https://exemple.fr").local())
        self.assertFalse(Requete(Host="exemple.fr:8230").local())


if __name__ == "__main__":
    unittest.main()
