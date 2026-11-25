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
                   "detail": [dict({"appareil": ap, "app": b, "contexte": ctx, "secondes": round(ss),
                                    "partage": rapport.est_partage(ctx)},
                                   **dict(zip(("suggestion", "raison"),
                                              rapport.suggestion(c, voc, appris, (ap, b, ctx)) if nom == rapport.NON_CLASSE
                                              else (None, None))))
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


def acces_disque():
    """Vrai si Temps lit le temps d'écran (accès complet au disque)."""
    try:
        list((rapport.biome.INFOCUS / "remote").iterdir())
        return True
    except PermissionError:
        return False
    except OSError:
        return True


def alerte_titres():
    """Si l'enregistreur ne lit plus aucun titre de fenêtre depuis dix minutes d'activité, c'est
    que Temps a perdu l'accès Accessibilité : le classement devient alors très pauvre."""
    try:
        con = sqlite3.connect(f"file:{rapport.BASE}?mode=ro", uri=True)
        n, avec = con.execute("select count(*), sum(titre <> '') from releves where inactif = 0 and t > ?",
                              (time.time() - 600,)).fetchone()
    except sqlite3.Error:
        return None
    if n and n >= 20 and (avec or 0) < n * 0.03:
        return rapport.tr("Aucun titre de fenêtre lu depuis 10 min : donne l'accès Accessibilité à Temps (Réglages Système > Confidentialité et sécurité).",
                          "No window title read for 10 min: grant Accessibility to Temps (System Settings > Privacy & Security).")
    return None


def bornes(q, defaut):
    """(début, fin exclue, nombre de jours) d'après ?debut=ts&fin=ts (jours entiers, fin comprise), ?jour=ts ou ?jours=N."""
    J = rapport.JOUR
    if "debut" in q:
        a = rapport.minuit(float(q["debut"][0]) + 3600)
        b = rapport.minuit(float(q.get("fin", q["debut"])[0]) + 3600)
        a, b = min(a, b), max(a, b)
    elif "jour" in q:
        a = b = rapport.minuit(float(q["jour"][0]) + 3600)
    else:
        b = rapport.minuit(time.time())
        a = rapport.minuit(b - int(q.get("jours", [defaut])[0]) * J + 3600)
    n = round((b - a) / J) + 1
    return a, rapport.minuit(b + J + 3600), n


LOCAUX = {f"{h}:{PORT}" for h in ("127.0.0.1", "localhost")}


class Gestion(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=str(ICI / "page"), **k)

    def local(self):
        """Seuls Temps et sa page parlent au serveur : une page web ouverte dans le navigateur ne peut
        ni lire le temps relevé (nom d'hôte détourné) ni écrire des règles (requête venue d'un autre site)."""
        origine = self.headers.get("Origin")
        if self.headers.get("Host") in LOCAUX and (origine is None or urlparse(origine).netloc in LOCAUX):
            return True
        self.send_error(403)
        return False

    def do_GET(self):
        if not self.local():
            return
        url = urlparse(self.path)
        if url.path in ("/fenetre", "/export"):
            return self.fenetre(url)
        if url.path == "/frise":
            try:
                return self.json(rapport.frise(float(parse_qs(url.query).get("jour", [time.time()])[0])))
            except PermissionError:
                return self.json({"erreur": rapport.tr("Accès complet au disque refusé.", "Full Disk Access denied.")})
        if url.path == "/projet":
            return self.projet(parse_qs(url.query))
        if url.path == "/semaine":
            try:
                tous = rapport.historique()
            except PermissionError:
                return self.json({"erreur": rapport.tr("Accès complet au disque refusé.", "Full Disk Access denied.")})
            q = parse_qs(url.query)
            return self.json(rapport.semaine(tous, float(q["debut"][0]) if "debut" in q else rapport.debut_semaine()))
        if url.path == "/manuel":
            q = parse_qs(url.query)
            cles = set(q.get("cle", []))
            l = [dict(m, nom=rapport.NOMS.get(m["cle"], m["cle"])) for m in rapport.manuels() if not cles or m["cle"] in cles]
            return self.json({"plages": sorted(l, key=lambda m: -m["debut"])})
        if url.path == "/source":
            q = parse_qs(url.query)
            un = lambda k, d="": q.get(k, [d])[0]
            return self.json(rapport.source(un("appareil", "Mac"), un("app"), un("contexte"),
                                            float(un("debut", "0")), float(un("fin", str(time.time())))))
        if url.path == "/etat":
            return self.json({"disque": acces_disque(), "titres": alerte_titres() is None})
        if url.path == "/regles":
            rapport.recharger()
            r = rapport.REGLES
            partages = rapport.tr("Sources partagées", "Shared sources")
            return self.json({"regles": [{"section": sec, "motif": m, "valeur": v, "nom": r.get("noms", {}).get(v, v)}
                                         for sec in ("fusions", "forcer", "titres", "apps", "chemins", "plages")
                                         for m, v in r.get(sec, {}).items() if isinstance(v, str)]
                              + [{"section": "partages", "motif": m, "valeur": "true", "nom": partages}
                                 for m, v in r.get("partages", {}).items() if v]})
        if url.path != "/api":
            return super().do_GET()
        q = parse_qs(url.query)
        try:
            tous = rapport.historique()
        except PermissionError:
            return self.json({"erreur": rapport.tr("Accès complet au disque refusé : à accorder à Temps (Réglages Système > Confidentialité et sécurité).",
                                                   "Full Disk Access denied: grant it to Temps (System Settings > Privacy & Security).")})
        debut, fin, _ = bornes(q, "0")
        c = rapport.fusion(tous, debut, fin)
        voc = rapport.vocabulaire()
        self.json({
            "depuis": debut,
            "maj": time.time(),
            "dernier_releve": dernier_releve(),
            "erreur": alerte_titres(),
            "familles": (f := familles(c, voc, rapport.apprenti(tous))),
            "categories": rapport.categories(rapport.fusion(tous, rapport.minuit(rapport.minuit(time.time()) - 29 * rapport.JOUR + 3600))),
            "travail": sum(x["secondes"] for x in f if x["nom"] != rapport.HORS),
            "histogramme": rapport.histogramme(tous),
            "mois": [{"jour": j["jour"], "travail": j["travail"]} for j in rapport.histogramme(tous, n=30)],
            "reperes": rapport.reperes(tous),
            "couleurs": rapport.couleurs(),
            "couleurs_posees": list(rapport.REGLES.get("couleurs", {})),
            "missions": {k: {n: str(d)[:10] for n, d in v.items()} for k, v in rapport.REGLES.get("missions", {}).items()},
            "lissage": rapport.REGLES.get("reglages", {}).get("lissage", 10),
            "domaines": rapport.domaines(),
            "series": rapport.ordre_series(),
        })

    def projet(self, q):
        """/projet?cle=…&debut=…&fin=… : le temps d'une catégorie (et de ses missions) jour par jour,
        par app, et par fichier, site ou session, sur la période."""
        try:
            tous = rapport.historique()
        except PermissionError:
            return self.json({"erreur": rapport.tr("Accès complet au disque refusé.", "Full Disk Access denied.")})
        cle = q.get("cle", [""])[0]
        debut, fin, n = bornes(q, "29")
        if cle.startswith("groupe:"):
            # un groupe (un domaine) : toutes les catégories dont le nom affiché commence par lui
            g = cle[7:]
            presentes = {k for c in tous.values() for k in c.tot}
            cles = {k for k in presentes if rapport.NOMS.get(k, k) == g or rapport.NOMS.get(k, k).startswith(g + " / ")}
        else:
            cles = {cle} | {k for k, c in rapport.PARENT.items() if c == cle} | {m for _, m in rapport.MISSIONS.get(cle, [])}
        sous = {}
        jours, apps, ctx = [], {}, {}
        j = debut
        for _ in range(n):
            c = tous.get(j)
            sec = 0.0
            if c:
                for k in cles:
                    sec += c.tot.get(k, 0)
                    sous[k] = sous.get(k, 0) + c.tot.get(k, 0)
                    for (ap, b, cx), v in c.detail.get(k, {}).items():
                        apps[(ap, b)] = apps.get((ap, b), 0) + v
                        if cx:
                            ctx[(ap, b, cx)] = ctx.get((ap, b, cx), 0) + v
            jours.append({"jour": j, "secondes": round(sec)})
            j = rapport.minuit(j + rapport.JOUR + 3600)
        trier = lambda d: sorted(d.items(), key=lambda x: -x[1])
        self.json({
            "cle": cle,
            "total": round(sum(x["secondes"] for x in jours)),
            "jours": jours,
            "apps": [{"appareil": ap, "app": b, "secondes": round(v)} for (ap, b), v in trier(apps)[:8]],
            "contextes": [{"appareil": ap, "app": b, "contexte": cx, "secondes": round(v)} for (ap, b, cx), v in trier(ctx)[:12]],
            "sous": [{"cle": k, "nom": rapport.NOMS.get(k, k), "secondes": round(v)} for k, v in trier(sous) if v >= 60] if len(cles) > 1 else [],
        })

    def fenetre(self, url):
        """/fenetre?jours=N : vue par app, projets et bilans ; /export?mois=AAAA-MM : CSV du mois."""
        q = parse_qs(url.query)
        try:
            tous = rapport.historique()
        except PermissionError:
            return self.json({"erreur": rapport.tr("Accès complet au disque refusé : à accorder à Temps (Réglages Système > Confidentialité et sécurité).",
                                                   "Full Disk Access denied: grant it to Temps (System Settings > Privacy & Security).")})
        if url.path == "/export":
            corps = rapport.export_csv(tous, q.get("mois", [time.strftime("%Y-%m")])[0]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/csv; charset=utf-8")
            self.send_header("Content-Length", str(len(corps)))
            self.end_headers()
            self.wfile.write(corps)
            return
        debut, fin, n = bornes(q, "29")
        c = rapport.fusion(tous, debut, fin)
        self.json({
            "depuis": debut,
            "facturable": round(rapport.facturable(c)),
            "projets": rapport.projets(tous),
            "reperes": rapport.reperes(tous),
            "mois": rapport.mois_disponibles(tous),
            "histogramme": rapport.histogramme(tous, n=n, fin=fin - rapport.JOUR),
        })

    def do_POST(self):
        """/regle : {section, motif, valeur} pose une règle et rend l'ancienne valeur ;
        /famille : {cle, famille} range une catégorie et rend son ancienne famille ;
        /annuler : {section, motif, avant} remet l'ancienne valeur ou retire la règle."""
        if not self.local():
            return
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
            elif self.path == "/domaines":
                reponse = {"avant": regles.ecrire_domaines(d["domaines"])}
            elif self.path == "/remplacer":
                reponse = {"avant": regles.remplacer(d["section"], d["ancien"], d["motif"], d["valeur"])}
            elif self.path == "/supprimer":
                reponse = {"avant": regles.supprimer(d["cle"])}
            elif self.path == "/manuel":
                m = rapport.ajouter_manuel(d["debut"], d["fin"], d["cle"], d.get("note", ""), bool(d.get("force")), d.get("motif", ""))
                reponse = {"avant": m["id"], "plage": m}
            elif self.path == "/manuel/retirer":
                reponse = {"avant": rapport.retirer_manuel(d["id"])}
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
        except Exception as e:  # tout échec revient à l'app en clair, jamais en connexion coupée
            self.json({"erreur": rapport.tr("Règle non écrite : ", "Rule not written: ") + (str(e) or type(e).__name__)})

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
