"""Rapport du temps par projet : Mac (fichiers, sites, sessions Claude) + iPhone/iPad (apps).

    python3 rapport.py          aujourd'hui
    python3 rapport.py 7        sept derniers jours
"""
import bisect, json, os, re, sqlite3, sys, time, tomllib, unicodedata
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse

import biome
import claude
from recorder import BASE, DONNEES

ICI = Path(__file__).resolve().parent
KNOWLEDGE = Path.home() / "Library/Application Support/Knowledge/knowledgeC.db"
JOURS = DONNEES / "jours"
LANGUE = os.environ.get("TEMPS_LANGUE", "fr")[:2]


def tr(fr, en):
    """Message dans la langue de l'app (passée par Temps.app)."""
    return fr if LANGUE == "fr" else en
JOUR = 86400


def fichier_regles():
    """regles.toml à côté du code ; créé au premier lancement depuis l'exemple de la langue de l'app."""
    f = Path(os.environ["TEMPS_REGLES"]) if os.environ.get("TEMPS_REGLES") else ICI / "rules.toml"
    if os.environ.get("TEMPS_DEMO") and not os.environ.get("TEMPS_REGLES"):
        f = DONNEES / "demo" / "rules.toml"  # la démo ne touche jamais à tes règles
    if not f.exists() and os.environ.get("TEMPS_DEMO"):
        import demo
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(demo.REGLES_FR if LANGUE == "fr" else demo.REGLES_EN)
    if not f.exists():
        exemple = ICI / ("rules.example.fr.toml" if LANGUE == "fr" else "rules.example.toml")
        f.write_text(exemple.read_text())
    return f


def recharger():
    """Relit regles.toml (au démarrage, puis après chaque règle posée depuis l'app)."""
    global REGLES, CHEMINS, ALIAS, NOMS, ACTIVITES, HORS_TRAVAIL, IGNORER, RACINES, INTERMEDIAIRES, RACINE_NOM
    REGLES = tomllib.loads(fichier_regles().read_text())
    d = REGLES.get("dossiers", {})
    RACINES = [Path(r).expanduser() for r in d.get("racines", [])]
    INTERMEDIAIRES = set(d.get("intermediaires", []))
    RACINE_NOM = d.get("racine_nom", "")
    CHEMINS = {str(Path(k).expanduser()): v for k, v in REGLES["chemins"].items()}
    ALIAS = {str(Path(k).expanduser()): str(Path(v).expanduser()) for k, v in REGLES.get("alias", {}).items()}
    NOMS = REGLES.get("noms", {})
    ACTIVITES = set(REGLES.get("familles", {}).get("activites", []))
    HORS_TRAVAIL = set(REGLES.get("familles", {}).get("hors_travail", []))
    IGNORER = set(REGLES["ignorer"]["bundles"])


recharger()
NAVIGATEURS = {"com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"}
CLAUDE = "com.anthropic.claudefordesktop"
NON_CLASSE = "Non classé"
PROJETS, ACTIVITE, HORS = "Projets", "Activités", "Hors travail"


def categories(c):
    """Toutes les catégories connues (règles et période affichée), pour le menu de classement."""
    cles = set(c.tot) | set(REGLES["titres"].values()) | set(REGLES["apps"].values()) | set(REGLES["chemins"].values()) | set(REGLES.get("projets", {}))
    cles -= {NON_CLASSE} | set(biome.PLATEFORMES.values())
    return sorted(({"cle": k, "nom": NOMS.get(k, k), "famille": famille(k)} for k in cles), key=lambda x: (x["famille"] != PROJETS, x["nom"].lower()))


def famille(cle):
    if cle == NON_CLASSE:
        return NON_CLASSE
    if cle in ACTIVITES:
        return ACTIVITE
    if cle in HORS_TRAVAIL or cle in biome.PLATEFORMES.values():
        return HORS
    return PROJETS


def realias(doc):
    for ancien, nouveau in ALIAS.items():
        if doc.startswith(ancien):
            return nouveau + doc[len(ancien):]
    return doc


def projet_dossier(doc):
    """Catégorie d'office d'un fichier rangé sous une racine de projets : « Groupe / Projet ».
    Le dossier de premier niveau est le groupe, le suivant le projet ; un dossier « intermédiaire »
    (Clients, par exemple) est sauté : Studio/Clients/Dupont/… donne « Studio / Dupont »."""
    for racine in RACINES:
        try:
            parties = Path(doc).relative_to(racine).parts
        except ValueError:
            continue
        if len(parties) < 2:
            return RACINE_NOM or None
        groupe = parties[0]
        if parties[1] in INTERMEDIAIRES and len(parties) > 3:
            return f"{groupe} / {parties[2]}"
        return f"{groupe} / {parties[1]}" if len(parties) > 2 else groupe
    return None


def classer(bundle, titre="", doc=""):
    """Clé de catégorie (stable). Le nom affiché vient de [noms]."""
    if doc and not doc.startswith(("mailto:", "http")):
        doc = realias(doc)
        p = projet_dossier(doc)
        if p:
            return p
        for prefixe, libelle in CHEMINS.items():
            if doc.startswith(prefixe):
                return libelle
    texte = f"{titre} {doc}".lower()
    for motif, libelle in REGLES["titres"].items():
        if motif.lower() in texte:
            return libelle
    return REGLES["apps"].get(bundle, NON_CLASSE)


def nom_app(bundle):
    return bundle.split(".")[-1] or "?"


def contexte(bundle, titre, doc):
    """Ce qu'on montre sous une catégorie : site, fichier, session ou fenêtre."""
    if bundle == CLAUDE:
        return titre
    if doc.startswith("mailto:"):
        compte = titre.split(" / ")[0]
        return f"{doc[7:]} · {compte}" if compte else doc[7:]
    if doc.startswith("http"):
        return urlparse(doc).hostname or doc
    if doc:
        p = Path(doc)
        return p.name or p.parent.name
    return titre or ""


class Collecte:
    """Une seule liste tous appareils confondus : {clé: secondes} et le détail par (appareil, app, contexte).

    Ce qui vient d'un iPhone ou d'un iPad sans règle passe en hors travail, sous le nom de l'appareil.
    """

    def __init__(self):
        self.tot = defaultdict(float)
        self.detail = defaultdict(lambda: defaultdict(float))

    def ajouter(self, appareil, bundle, secondes, titre="", doc="", secours=None):
        """`secours` : la catégorie à prendre si aucune règle ne range la ligne."""
        if not bundle or bundle in IGNORER or secondes <= 0:
            return
        cle = classer(bundle, titre, doc)
        if cle == NON_CLASSE and secours:
            cle = secours
        if cle == NON_CLASSE and appareil != "Mac":
            cle = appareil
        self.tot[cle] += secondes
        self.detail[cle][(appareil, bundle, contexte(bundle, titre, doc))] += secondes

    def fusionner(self, autre):
        for cle, sec in autre.tot.items():
            self.tot[cle] += sec
        for cle, d in autre.detail.items():
            for k, sec in d.items():
                self.detail[cle][k] += sec

    def vers_json(self):
        return {"tot": self.tot, "detail": {cle: [[*k, sec] for k, sec in d.items()] for cle, d in self.detail.items()}}

    @classmethod
    def depuis_json(cls, j):
        c = cls()
        c.tot.update(j["tot"])
        for cle, lignes in j["detail"].items():
            for ap, b, ctx, sec in lignes:
                c.detail[cle][(ap, b, ctx)] = sec
        return c

    def familles(self):
        """{famille: [(clé, secondes)]} triées par durée."""
        f = defaultdict(list)
        for cle, s in sorted(self.tot.items(), key=lambda x: -x[1]):
            f[famille(cle)].append((cle, s))
        return f


class ParJour:
    """Répartit chaque ajout dans la collecte de son jour (selon l'heure de début)."""

    def __init__(self):
        self.jours = defaultdict(Collecte)

    def ajouter(self, t, *args, **kw):
        self.jours[minuit(t)].ajouter(*args, **kw)


def minuit(t):
    return time.mktime(time.localtime(t)[:3] + (0, 0, 0, 0, 0, -1))


def debut_releves():
    if not BASE.exists():
        return float("inf")
    con = sqlite3.connect(f"file:{BASE}?mode=ro", uri=True)
    return con.execute("select min(t) from releves").fetchone()[0] or float("inf")


def avec_session(idx, bundle, t, titre, doc):
    """Pour Claude, la fenêtre s'appelle toujours « Claude » : on lui substitue la session active."""
    if bundle == CLAUDE:
        s = idx.session(t)
        if s:
            cwd = s[1] or ""
            return s[0], "" if any(cwd.rstrip("/") == str(r) for r in RACINES) else cwd
    return titre, doc


def mac(depuis, c, idx):
    if not BASE.exists():
        return
    con = sqlite3.connect(f"file:{BASE}?mode=ro", uri=True)
    for t, bundle, titre, doc, duree in con.execute(
            "select t, bundle, titre, doc, duree from releves where t >= ? and inactif = 0", (depuis,)):
        titre, doc = avec_session(idx, bundle, t, titre, doc)
        c.ajouter(t, "Mac", bundle, duree, titre, doc)


def safari_historique(depuis, avant):
    """Domaines visités avant le premier relevé, d'après le temps d'écran du Mac."""
    try:
        con = sqlite3.connect(f"file:{KNOWLEDGE}?mode=ro", uri=True)
        lignes = con.execute(
            "select o.ZVALUESTRING, m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN, o.ZSTARTDATE + 978307200, o.ZENDDATE + 978307200 "
            "from ZOBJECT o join ZSTRUCTUREDMETADATA m on o.ZSTRUCTUREDMETADATA = m.Z_PK "
            "where o.ZSTREAMNAME = '/app/webUsage' and o.ZSTARTDATE + 978307200 >= ?", (depuis,)).fetchall()
    except sqlite3.Error:
        return []
    return [(b, d, t0, min(t1, avant)) for b, d, t0, t1 in lignes if t0 < avant and d]


def domaine_a(web, debuts, t):
    """Le domaine ouvert le plus récemment parmi ceux qui couvrent l'instant t."""
    i = bisect.bisect_right(debuts, t) - 1
    for j in range(i, max(-1, i - 200), -1):
        if web[j][1] >= t:
            return web[j][2]
    return None


def appareils(depuis, c, idx, sessions=None, mac_couvert_depuis=float("inf")):
    """Apps des iPhone/iPad, et du Mac avant le premier relevé de l'enregistreur.

    L'historique du Mac ne connaît que l'app au premier plan : on le découpe par minute
    pour y retrouver le site (navigateurs) ou la session (Claude) de chaque instant.
    """
    avant = debut_releves()
    web = defaultdict(list)
    for bundle, domaine, t0, t1 in safari_historique(depuis, avant):
        web[bundle].append((t0, t1, domaine))
    for l in web.values():
        l.sort()
    debuts = {b: [x[0] for x in l] for b, l in web.items()}
    for appareil, bundle, t0, t1 in (sessions if sessions is not None else biome.sessions(depuis)):
        if appareil == "Mac":
            if t0 >= avant or t0 >= mac_couvert_depuis:
                continue
            t1 = min(t1, avant)
            if bundle == CLAUDE or bundle in web:
                t = t0
                while t < t1:
                    pas = min(60, t1 - t)
                    if bundle == CLAUDE:
                        titre, doc = avec_session(idx, bundle, t, "", "")
                    else:
                        d = domaine_a(web[bundle], debuts[bundle], t + pas / 2)
                        titre, doc = "", f"https://{d}/" if d else ""
                    c.ajouter(t, "Mac", bundle, pas, titre, doc)
                    t += pas
                continue
        c.ajouter(t0, appareil, bundle, t1 - t0)


def hm(s):
    m = round(s / 60)
    return f"{m // 60} h {m % 60:02d}" if m >= 60 else f"{m} min"


def signature():
    """Change dès qu'une règle ou le code de calcul change : les jours en cache sont alors recalculés."""
    fichiers = [fichier_regles()] + [ICI / f for f in ("report.py", "biome.py", "claude.py")]
    return "-".join(str(f.stat().st_mtime_ns) for f in fichiers)




def lire_jour(j, sig):
    try:
        d = json.loads((JOURS / f"{time.strftime('%Y-%m-%d', time.localtime(j))}.json").read_text())
        return Collecte.depuis_json(d) if d.get("signature") == sig else None
    except (OSError, ValueError, KeyError):
        return None


def ecrire_jour(j, c, sig):
    try:
        JOURS.mkdir(parents=True, exist_ok=True)
        (JOURS / f"{time.strftime('%Y-%m-%d', time.localtime(j))}.json").write_text(json.dumps({"signature": sig, **c.vers_json()}))
    except OSError:
        pass


def par_jour(debut):
    """{minuit: Collecte} depuis debut.

    En mode démo (TEMPS_DEMO=1), des données fictives remplacent toutes les sources.

    Les jours clos depuis plus de 48 h (synchro iPhone comprise) viennent du cache ;
    le reste est recalculé en une passe depuis le premier jour manquant.
    """
    if os.environ.get("TEMPS_DEMO"):
        import demo
        return demo.jours(debut)
    aujourdhui = minuit(time.time())
    sig = signature()
    jours = {}
    jour, clos = debut, minuit(aujourdhui - JOUR + 3600)
    while jour < clos:
        dj = lire_jour(jour, sig)
        if dj is None:
            break
        jours[jour] = dj
        jour = minuit(jour + JOUR + 3600)
    p = ParJour()
    idx = claude.Index(jour)
    mac(jour, p, idx)
    sessions = biome.sessions(jour)
    mac_couvert = float("inf")
    appareils(jour, p, idx, sessions, mac_couvert)
    for j, dj in p.jours.items():
        if j >= jour:
            jours[j] = dj
    # tous les jours clos vont au cache, même vides : sinon on recalcule depuis le premier trou
    while jour < clos:
        ecrire_jour(jour, jours.get(jour, Collecte()), sig)
        jour = minuit(jour + JOUR + 3600)
    return jours


def fusion(jours, debut, fin=float("inf")):
    c = Collecte()
    for j, dj in jours.items():
        if debut <= j < fin:
            c.fusionner(dj)
    return c


def travail(c):
    return sum(s for cle, s in c.tot.items() if famille(cle) != HORS)


def totaux(jours):
    """Début de période et collecte fusionnée sur les `jours` derniers jours (0 = aujourd'hui)."""
    debut = minuit(minuit(time.time()) - jours * JOUR + 3600)
    return debut, fusion(par_jour(debut), debut)


TEINTES_AUTO = ["bleu", "turquoise", "violet", "jaune", "rose", "vert", "rouge", "ciel"]


def groupes_dossiers():
    """Dossiers de premier niveau des racines de projets (les groupes), triés par nom."""
    g = []
    for r in RACINES:
        if r.is_dir():
            g += [d for d in r.iterdir() if d.is_dir() and not d.name.startswith((".", "00"))]
    return sorted(g, key=lambda d: d.name.lower())


def couleurs():
    """Couleur de chaque groupe : celle choisie dans [couleurs], sinon une teinte donnée d'office
    aux huit premiers groupes de dossiers, dans un ordre fixe. Les suivants restent gris."""
    choix = REGLES.get("couleurs", {})
    auto = [d.name for d in groupes_dossiers() if d.name not in choix]
    libres = [t for t in TEINTES_AUTO if t not in choix.values()]
    eff = {g: t for g, t in zip(auto, libres)}
    eff.update(choix)
    return eff


def ordre_series():
    """Ordre fixe des séries, de bas en haut : groupes, chacun suivi de ses sous-projets colorés, puis le reste."""
    eff = couleurs()
    groupes = [g for g in eff if " / " not in g]
    sous = sorted(k for k in eff if " / " in k)
    ordre = [x for g in groupes for x in [g] + [s for s in sous if s.startswith(g + " / ")]]
    ordre += [s for s in sous if s not in ordre]
    return ordre + ["Autres projets", ACTIVITE, NON_CLASSE]


def serie(cle):
    """Série de couleur d'une catégorie de travail : sa workstation, « Autres projets », « Activités » ou « Non classé »."""
    f = famille(cle)
    if f in (NON_CLASSE, ACTIVITE):
        return f
    eff = couleurs()
    if cle in eff and " / " in cle:
        return cle  # sous-projet avec sa propre couleur
    groupe = NOMS.get(cle, cle).split(" / ")[0]
    if groupe in eff:
        return groupe
    ws = cle.split(" / ")[0].split(" (")[0]
    return ws if ws in eff else "Autres projets"


def parts(c):
    p = defaultdict(float)
    for cle, sec in c.tot.items():
        if famille(cle) != HORS:
            p[serie(cle)] += sec
    return {k: round(v) for k, v in p.items() if v >= 60}


def histogramme(jours, n=7):
    """Travail des n derniers jours, du plus ancien à aujourd'hui, réparti par série."""
    aujourdhui = minuit(time.time())
    dates = [minuit(aujourdhui - k * JOUR + 3600) for k in range(n - 1, -1, -1)]
    return [{"jour": d, "travail": round(travail(c := jours.get(d, Collecte()))), "parts": parts(c)} for d in dates]


def facturable(c):
    return sum(sec for cle, sec in c.tot.items() if fiche(cle).get("facturable", famille(cle) == PROJETS))


def debut_semaine():
    t = time.localtime()
    return minuit(minuit(time.time()) - t.tm_wday * JOUR + 3600)


def reperes(jours):
    """Repères de la semaine en cours (depuis lundi).

    Un repère porte sur une catégorie, ou sur un groupe : « Studio » compte aussi
    « Studio / Dupont ». `heures` est un objectif, `plafond` une limite.
    """
    c = fusion(jours, debut_semaine())
    sortie = []
    for nom, r in REGLES.get("reperes", {}).items():
        s = sum(sec for cle, sec in c.tot.items()
                if (n := NOMS.get(cle, cle)) == nom or n.startswith(nom + " / ") or cle == nom)
        sortie.append({"nom": nom, "secondes": round(s),
                       "objectif": round(3600 * r["heures"]) if "heures" in r else None,
                       "plafond": round(3600 * r["plafond"]) if "plafond" in r else None})
    return sortie


HISTORIQUE = 730  # jours lus pour les bilans et l'export


def historique():
    return par_jour(minuit(minuit(time.time()) - HISTORIQUE * JOUR + 3600))


def par_app(c):
    """Temps par app et appareil, avec la catégorie où l'app passe le plus de temps."""
    tot, ou = defaultdict(float), defaultdict(lambda: defaultdict(float))
    for cle, d in c.detail.items():
        for (ap, b, _), sec in d.items():
            tot[(ap, b)] += sec
            ou[(ap, b)][cle] += sec
    return [{"appareil": ap, "app": b, "secondes": round(sec),
             "surtout": NOMS.get(m := max(ou[(ap, b)], key=ou[(ap, b)].get), m)}
            for (ap, b), sec in sorted(tot.items(), key=lambda x: -x[1]) if sec >= 60]


def fiche(cle):
    return REGLES.get("projets", {}).get(cle, {})


def projets(tous):
    """Chaque catégorie de travail : fiche, temps du mois, temps total, et bilan face au devis."""
    debut_mois = minuit(time.mktime(time.localtime()[:2] + (1, 0, 0, 0, 0, 0, -1)) + 3600)
    total, mois = fusion(tous, 0), fusion(tous, debut_mois)
    cles = (set(total.tot) | set(REGLES.get("projets", {}))) - {NON_CLASSE} - set(biome.PLATEFORMES.values())
    sortie = []
    for cle in cles:
        f, reel = fiche(cle), total.tot.get(cle, 0)
        sortie.append({
            "cle": cle, "nom": NOMS.get(cle, cle), "famille": famille(cle),
            "total": round(reel), "mois": round(mois.tot.get(cle, 0)),
            "premier": min((j for j, c in tous.items() if c.tot.get(cle)), default=None),
            "vendu": f.get("vendu"), "montant": f.get("montant"), "facturable": f.get("facturable", famille(cle) == PROJETS),
            "taux": round(f["montant"] / (reel / 3600)) if f.get("montant") and reel >= 600 else None,
        })
    return sorted(sortie, key=lambda p: (p["famille"] != PROJETS, -p["total"]))


def mois_disponibles(tous):
    return sorted({time.strftime("%Y-%m", time.localtime(j)) for j, c in tous.items() if c.tot}, reverse=True)


def export_csv(tous, mois):
    """CSV du mois (AAAA-MM) : une ligne par catégorie, séparateur ; et virgule décimale (Numbers, Excel FR)."""
    c = Collecte()
    for j, dj in tous.items():
        if time.strftime("%Y-%m", time.localtime(j)) == mois:
            c.fusionner(dj)
    lignes = [tr("Mois;Famille;Catégorie;Heures;Facturable;Heures vendues;Montant HT",
                 "Month;Family;Category;Hours;Billable;Hours sold;Amount excl. tax")]
    noms_familles = {PROJETS: tr(PROJETS, "Projects"), ACTIVITE: tr(ACTIVITE, "Activities"),
                     HORS: tr(HORS, "Off work"), NON_CLASSE: tr(NON_CLASSE, "Unsorted")}
    for cle, sec in sorted(c.tot.items(), key=lambda x: (famille(x[0]), -x[1])):
        if sec < 60:
            continue
        f = fiche(cle)
        fact = f.get("facturable", famille(cle) == PROJETS)
        h = f"{sec / 3600:.2f}"
        lignes.append(";".join([mois, noms_familles[famille(cle)], NOMS.get(cle, cle), h.replace(".", ",") if LANGUE == "fr" else h,
                                tr("oui", "yes") if fact else tr("non", "no"), str(f.get("vendu", "")), str(f.get("montant", ""))]))
    return "\n".join(lignes) + "\n"


def _norme(t):
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", t)


def vocabulaire():
    """{forme normalisée: clé} : dossiers de projets et catégories nommées dans les règles."""
    voc = {}
    for ws in groupes_dossiers():
        for d in ws.iterdir():
            if not d.is_dir() or d.name.startswith((".", "00")) or d.name in ("Archives", "Ressources"):
                continue
            if d.name in INTERMEDIAIRES:
                for sd in d.iterdir():
                    if sd.is_dir() and not sd.name.startswith((".", "00")):
                        voc[_norme(sd.name)] = f"{ws.name} / {sd.name}"
            else:
                voc[_norme(d.name)] = f"{ws.name} / {d.name}"
    for cle in set(REGLES["titres"].values()) | set(REGLES["apps"].values()) | set(NOMS):
        voc.setdefault(_norme(cle.split(" / ")[-1]), cle)
        voc.setdefault(_norme(cle.split(" / ")[0]), cle)
        voc.setdefault(_norme(NOMS.get(cle, cle).split(" / ")[-1]), cle)
    return {k: v for k, v in voc.items() if len(k) >= 4}


MOTS_VIDES = {"claude", "code", "safari", "finder", "https", "http", "www", "html", "index", "avec", "pour", "dans",
              "sans", "plus", "une", "des", "les", "sur", "par", "aux", "nouveau", "nouvelle", "copie", "image",
              "fichier", "document", "sans titre", "untitled", "google", "messages", "mail", "boite", "reception"}


def _mots(t):
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
    return {m for m in re.split(r"[^a-z0-9]+", t) if len(m) >= 4 and not m.isdigit() and m not in MOTS_VIDES}


class Apprenti:
    """Ce que tes classements apprennent : quels mots (de titres, sites, fichiers, sessions, correspondants)
    mènent à quelle catégorie, pondérés par le temps passé."""

    def __init__(self, c):
        self.mots = defaultdict(lambda: defaultdict(float))
        self.exact = defaultdict(lambda: defaultdict(float))
        for cle, d in c.detail.items():
            if cle == NON_CLASSE or cle in biome.PLATEFORMES.values():
                continue
            for (_, _, ctx), sec in d.items():
                if not ctx:
                    continue
                self.exact[ctx.lower()][cle] += sec
                for m in _mots(ctx):
                    self.mots[m][cle] += sec

    def suggerer(self, ctx):
        if not ctx:
            return None
        e = self.exact.get(ctx.lower())
        if e:
            cle, sec = max(e.items(), key=lambda x: x[1])
            if sec >= 0.8 * sum(e.values()):
                return cle
        score = defaultdict(float)
        for m in _mots(ctx):
            d = self.mots.get(m)
            if not d:
                continue
            total = sum(d.values())
            cle, sec = max(d.items(), key=lambda x: x[1])
            if total >= 120 and sec / total >= 0.75:
                score[cle] += (sec / total) * (1 + total / 3600) ** 0.5
        if not score:
            return None
        rang = sorted(score.items(), key=lambda x: -x[1])
        if rang[0][1] >= 1.2 and (len(rang) == 1 or rang[0][1] >= 2 * rang[1][1]):
            return rang[0][0]
        return None


_apprenti = {}


def apprenti(tous):
    """Modèle en mémoire, refait quand les règles ou les données changent."""
    sig = signature() + str(len(tous))
    if sig not in _apprenti:
        _apprenti.clear()
        _apprenti[sig] = Apprenti(fusion(tous, 0))
    return _apprenti[sig]


def suggerer(voc, *textes):
    """La catégorie dont le nom apparaît dans le contexte (le plus long gagne), ou None."""
    t = _norme(" ".join(x for x in textes if x))
    trouves = [k for k in voc if k in t]
    return voc[max(trouves, key=len)] if trouves else None


def main():
    jours = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    debut, c = totaux(jours)
    print(f"Depuis le {time.strftime('%d/%m/%Y', time.localtime(debut))}")
    for fam, postes in c.familles().items():
        print(f"\n{fam} — {hm(sum(s for _, s in postes))}")
        for cle, s in postes:
            if s < 60:
                continue
            print(f"  {hm(s):>9}  {NOMS.get(cle, cle)}")
            for (app, bundle, ctx), ss in sorted(c.detail[cle].items(), key=lambda x: -x[1])[:4]:
                if ss >= 60:
                    print(f"  {'':>9}    {hm(ss):>8}  {nom_app(bundle)} · {ctx}  ({app})")


if __name__ == "__main__":
    main()
