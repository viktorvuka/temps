"""Tableau de bord local : http://127.0.0.1:8230"""
import json, sqlite3, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import report as rapport
import rules as regles

ICI = Path(__file__).resolve().parent
PORT = 8230


ORDRE = [rapport.PROJETS, rapport.NON_CLASSE, rapport.ACTIVITE, rapport.HORS]


def familles(c, voc, appris=None):
    """Familles dans l'ordre d'affichage, chaque catégorie avec son nom et son détail.
    Les lignes non classées portent une suggestion quand un nom de projet apparaît dans leur contexte."""
    f = c.familles()
    sortie = []
    for nom in ORDRE:
        postes = [{"cle": cle, "nom": rapport.NOMS.get(cle, cle), "secondes": round(s),
                   "detail": [{"appareil": ap, "app": b, "contexte": ctx, "secondes": round(ss),
                               "suggestion": (rapport.suggerer(voc, ctx) or (appris.suggerer(ctx) if appris else None))
                               if nom == rapport.NON_CLASSE else None}
                              for (ap, b, ctx), ss in sorted(c.detail[cle].items(), key=lambda x: -x[1]) if ss >= 30]}
                  for cle, s in f.get(nom, []) if s >= 60]
        if postes:
            sortie.append({"nom": nom, "secondes": sum(p["secondes"] for p in postes), "postes": postes})
    return sortie


def dernier_releve():
    try:
        con = sqlite3.connect(f"file:{rapport.BASE}?mode=ro", uri=True)
        return con.execute("select max(t) from releves").fetchone()[0]
    except sqlite3.Error:
        return None


class Gestion(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=str(ICI / "page"), **k)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/fenetre", "/export"):
            return self.fenetre(url)
        if url.path != "/api":
            return super().do_GET()
        q = parse_qs(url.query)
        jours = int(q.get("jours", ["0"])[0])
        try:
            tous = rapport.historique()
        except PermissionError:
            return self.json({"erreur": rapport.tr("Accès complet au disque refusé : à accorder à Temps Engine (Réglages Système > Confidentialité et sécurité).",
                                                   "Full Disk Access denied: grant it to Temps Engine (System Settings > Privacy & Security).")})
        if "jour" in q:
            # un seul jour, choisi dans l'histogramme
            debut = rapport.minuit(float(q["jour"][0]) + 3600)
            c = rapport.fusion(tous, debut, rapport.minuit(debut + rapport.JOUR + 3600))
        else:
            debut = rapport.minuit(rapport.minuit(time.time()) - jours * rapport.JOUR + 3600)
            c = rapport.fusion(tous, debut)
        voc = rapport.vocabulaire()
        self.json({
            "depuis": debut,
            "maj": time.time(),
            "dernier_releve": dernier_releve(),
            "familles": (f := familles(c, voc, rapport.apprenti(tous))),
            "categories": rapport.categories(rapport.fusion(tous, rapport.minuit(rapport.minuit(time.time()) - 29 * rapport.JOUR + 3600))),
            "travail": sum(x["secondes"] for x in f if x["nom"] != rapport.HORS),
            "histogramme": rapport.histogramme(tous),
            "reperes": rapport.reperes(tous),
            "couleurs": rapport.couleurs(),
            "couleurs_posees": list(rapport.REGLES.get("couleurs", {})),
            "series": rapport.ordre_series(),
        })

    def fenetre(self, url):
        """/fenetre?jours=N : vue par app, projets et bilans ; /export?mois=AAAA-MM : CSV du mois."""
        q = parse_qs(url.query)
        try:
            tous = rapport.historique()
        except PermissionError:
            return self.json({"erreur": rapport.tr("Accès complet au disque refusé : à accorder à Temps Engine (Réglages Système > Confidentialité et sécurité).",
                                                   "Full Disk Access denied: grant it to Temps Engine (System Settings > Privacy & Security).")})
        if url.path == "/export":
            corps = rapport.export_csv(tous, q.get("mois", [time.strftime("%Y-%m")])[0]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/csv; charset=utf-8")
            self.send_header("Content-Length", str(len(corps)))
            self.end_headers()
            self.wfile.write(corps)
            return
        jours = int(q.get("jours", ["29"])[0])
        debut = rapport.minuit(rapport.minuit(time.time()) - jours * rapport.JOUR + 3600)
        c = rapport.fusion(tous, debut)
        self.json({
            "depuis": debut,
            "apps": rapport.par_app(c),
            "facturable": round(rapport.facturable(c)),
            "projets": rapport.projets(tous),
            "reperes": rapport.reperes(tous),
            "mois": rapport.mois_disponibles(tous),
            "histogramme": rapport.histogramme(tous, n=jours + 1),
        })

    def do_POST(self):
        """/regle : {section, motif, valeur} pose une règle et rend l'ancienne valeur ;
        /famille : {cle, famille} range une catégorie et rend son ancienne famille ;
        /annuler : {section, motif, avant} remet l'ancienne valeur ou retire la règle."""
        try:
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/regle":
                if not d.get("motif") or not d.get("valeur"):
                    raise ValueError("Règle incomplète : motif et catégorie sont requis.")
                avant = regles.poser(d["section"], d["motif"], d["valeur"])
                reponse = {"section": d["section"], "motif": d["motif"], "avant": avant}
            elif self.path == "/famille":
                reponse = {"avant": regles.famille(d["cle"], d["famille"])}
            elif self.path == "/lot":
                reponse = {"avant": regles.lot(d["regles"])}
            elif self.path == "/supprimer":
                reponse = {"avant": regles.supprimer(d["cle"])}
            elif self.path == "/restaurer":
                regles.restaurer(d["texte"])
                reponse = {"ok": True}
            elif self.path == "/annuler":
                if d.get("avant") is None:
                    regles.retirer(d["section"], d["motif"])
                else:
                    regles.poser(d["section"], d["motif"], d["avant"])
                reponse = {"ok": True}
            else:
                self.send_error(404)
                return
            rapport.recharger()
            self.json(reponse)
        except (ValueError, KeyError, StopIteration) as e:
            self.json({"erreur": rapport.tr("Règle non écrite : ", "Rule not written: ") + str(e)})

    def json(self, donnees):
        corps = json.dumps(donnees).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Gestion).serve_forever()
