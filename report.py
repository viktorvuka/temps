"""Rapport du temps par projet : Mac (fichiers, sites, sessions Claude) + iPhone/iPad (apps).

    python3 rapport.py          aujourd'hui
    python3 rapport.py 7        sept derniers jours
"""
import bisect, csv, io, json, os, re, sqlite3, sys, threading, time, tomllib, unicodedata
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


# Le serveur répond sur plusieurs fils : un seul à la fois lit les sources et touche aux caches.
_VERROU = threading.RLock()


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
    regles = tomllib.loads(fichier_regles().read_text())
    # un fichier de règles où il manque une section reste lisible
    for section in ("chemins", "titres", "apps"):
        regles.setdefault(section, {})
    regles.setdefault("ignorer", {}).setdefault("bundles", [])
    with _VERROU:
        _recharger(regles)


def _recharger(regles):
    global REGLES, CHEMINS, ALIAS, NOMS, ACTIVITES, HORS_TRAVAIL, IGNORER, RACINES, INTERMEDIAIRES, RACINE_NOM, EXCLUS
    REGLES = regles
    d = REGLES.get("dossiers", {})
    RACINES = [Path(r).expanduser() for r in d.get("racines", [])]
    INTERMEDIAIRES = set(d.get("intermediaires", []))
    RACINE_NOM = d.get("racine_nom", "")
    EXCLUS = set(d.get("exclus", []))
    CHEMINS = {str(Path(k).expanduser()): v for k, v in REGLES["chemins"].items()}
    ALIAS = {str(Path(k).expanduser()): str(Path(v).expanduser()) for k, v in REGLES.get("alias", {}).items()}
    NOMS = REGLES.get("noms", {})
    ACTIVITES = set(REGLES.get("familles", {}).get("activites", []))
    HORS_TRAVAIL = set(REGLES.get("familles", {}).get("hors_travail", []))
    IGNORER = set(REGLES["ignorer"]["bundles"])
    if "lire_missions" in globals():
        lire_missions()


NAVIGATEURS = {"com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"}
CLAUDE = "com.anthropic.claudefordesktop"
NON_CLASSE = "Non classé"
PROJETS, ACTIVITE, HORS = "Projets", "Activités", "Hors travail"


# --- Missions datées : une mission (« Projet / Mission ») peut démarrer à une date. Le temps du projet
# va alors à la mission en cours ce jour-là (la dernière démarrée) ; avant la première, il reste sur le projet.
MISSIONS = {}   # {clé du projet: [(début, clé de la mission)] triés}
PARENT = {}     # {clé de mission à l'ancienne : clé du client}


def cle_mission(client, nom):
    return f"{client} · {nom}"


def lire_missions():
    """[missions] "Studio / Dupont" = { "Studio / Dupont / Site" = "2026-10-01" } : la clé de la mission
    (une catégorie « Projet / Mission ») et sa date de départ. Ancien format, toujours lu : un simple nom
    (« Site ») crée une mission « Studio / Dupont · Site », affichée « Studio / Dupont / Site »."""
    MISSIONS.clear()
    PARENT.clear()
    for client, table in REGLES.get("missions", {}).items():
        liste = []
        parent = NOMS.get(client, client)
        for nom, debut in table.items():
            try:
                t = time.mktime(time.strptime(str(debut)[:10], "%Y-%m-%d"))
            except ValueError:
                continue
            if " / " in nom:
                liste.append((t, nom))
            else:
                cle = cle_mission(client, nom)
                PARENT[cle] = client
                NOMS.setdefault(cle, f"{parent} / {nom}")
                liste.append((t, cle))
        if liste:
            MISSIONS[client] = sorted(liste)


def mission_du_jour(client, jour):
    """La mission en cours ce jour-là, ou le client lui-même avant la première."""
    cle = client
    for debut, m in MISSIONS[client]:
        if debut <= jour + 3600:
            cle = m
    return cle


def fusion_de(cle):
    """La catégorie où une catégorie fusionnée a été intégrée ([fusions], en suivant les chaînes)."""
    f = REGLES.get("fusions", {})
    for _ in range(10):
        if cle not in f:
            break
        cle = f[cle]
    return cle


def en_fusions(c):
    """Verse le temps des catégories fusionnées dans celle qui les a absorbées."""
    for k in [k for k in c.tot if k in REGLES.get("fusions", {})]:
        cible = fusion_de(k)
        c.tot[cible] += c.tot.pop(k)
        for x, sec in c.detail.pop(k, {}).items():
            c.detail[cible][x] += sec
    return c


def en_missions(c, jour):
    """Remplace, dans la collecte d'un jour, chaque client découpé par sa mission de ce jour-là."""
    for client in [k for k in c.tot if k in MISSIONS]:
        m = mission_du_jour(client, jour)
        if m == client:
            continue
        c.tot[m] += c.tot.pop(client)
        for k, sec in c.detail.pop(client, {}).items():
            c.detail[m][k] += sec
    return c


recharger()


def categories(c):
    """Toutes les catégories connues (règles et période affichée), pour le menu de classement."""
    cles = set(c.tot) | set(REGLES.get("forcer", {}).values()) | set(REGLES["titres"].values()) | set(REGLES["apps"].values()) | set(REGLES["chemins"].values()) | set(REGLES.get("projets", {}))
    cles = {fusion_de(k) for k in cles}
    cles -= {NON_CLASSE, biome.INCONNU} | set(biome.PLATEFORMES.values())
    cles |= set(MISSIONS) | {m for l in MISSIONS.values() for _, m in l}
    archives = REGLES.get("archives", {})
    return sorted(({"cle": k, "nom": NOMS.get(k, k), "famille": famille(PARENT.get(k, k)), "archive": bool(archives.get(k)),
                    "mission_de": PARENT.get(k), "missions": k in MISSIONS} for k in cles), key=lambda x: (x["famille"] != PROJETS, x["nom"].lower()))


NATURES = {"projets": "Projets", "activites": "Activités", "hors_travail": "Hors travail"}


def domaines():
    """Les domaines, dans leur ordre : [{nom, nature, projets}]. Sans section [domaines], les trois familles
    d'origine tiennent lieu de domaines (sans projets attribués : chaque projet y va selon sa famille)."""
    d = REGLES.get("domaines", {})
    if d:
        return [{"nom": n, "nature": v.get("nature", "projets"), "projets": list(v.get("projets", []))} for n, v in d.items()]
    return [{"nom": tr("Projets", "Projects"), "nature": "projets", "projets": []},
            {"nom": tr("Activités", "Activities"), "nature": "activites", "projets": []},
            {"nom": tr("Hors travail", "Off work"), "nature": "hors_travail", "projets": []}]


def famille(cle):
    cle = PARENT.get(cle, cle)
    if cle == NON_CLASSE:
        return NON_CLASSE
    # un projet rangé dans un domaine prend la nature de ce domaine
    projet = NOMS.get(cle, cle).split(" / ")[0]
    for d in REGLES.get("domaines", {}).values():
        if projet in d.get("projets", []):
            return NATURES.get(d.get("nature", "projets"), PROJETS)
    if cle in ACTIVITES:
        return ACTIVITE
    if cle in HORS_TRAVAIL or cle in biome.PLATEFORMES.values() or cle == biome.INCONNU:
        return HORS
    return PROJETS


def chemin_fichier(doc):
    """Certaines apps (Numbers, Pages…) donnent leur document en adresse file:// encodée : on en refait un chemin
    pour l'affichage. Le classement garde l'adresse telle quelle (ses règles ont été posées dessus)."""
    if doc.startswith("file://"):
        from urllib.parse import unquote
        return unicodedata.normalize("NFC", unquote(urlparse(doc).path))
    return doc


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
            cle = f"{groupe} / {parties[2]}"
        else:
            cle = f"{groupe} / {parties[1]}" if len(parties) > 2 else groupe
        # un dossier « supprimé » depuis l'app ne se range plus d'office (ni ses sous-dossiers)
        return None if cle in EXCLUS or groupe in EXCLUS else cle
    return None


def classer(bundle, titre="", doc=""):
    """Clé de catégorie (stable). Le nom affiché vient de [noms].
    Ordre : règles forcées (un déplacement fait à la main), dossier de projets, chemins, titres, app."""
    texte = f"{titre} {doc}".lower()
    for motif, libelle in REGLES.get("forcer", {}).items():
        if motif.lower() in texte:
            return libelle
    if doc and not doc.startswith(("mailto:", "http")):
        doc = realias(doc)
        p = projet_dossier(doc)
        if p:
            return p
        for prefixe, libelle in CHEMINS.items():
            if doc.startswith(prefixe):
                return libelle
    for motif, libelle in REGLES["titres"].items():
        if motif.lower() in texte:
            return libelle
    return REGLES["apps"].get(bundle, NON_CLASSE)


def nom_app(bundle):
    if bundle == "manuel":
        return tr("Saisie à la main", "Entered by hand")
    return bundle.split(".")[-1] or "?"


def contexte(bundle, titre, doc):
    """Ce qu'on montre sous une catégorie : site, fichier, session ou fenêtre."""
    if bundle == CLAUDE:
        return titre
    if doc.startswith("mailto:"):
        compte = titre.split(" / ")[0]
        return f"{doc[7:]} · {compte}" if compte else doc[7:]
    if doc.startswith("http"):
        u = urlparse(doc)
        if u.hostname in ("localhost", "127.0.0.1") or (u.hostname or "").endswith((".localhost", ".test")):
            # un serveur de développement : le port distingue les projets, le titre de l'onglet les nomme
            return f"{titre} — {u.netloc}" if titre else u.netloc
        return u.hostname or doc
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

    def ajouter(self, appareil, bundle, secondes, titre="", doc="", secours=None, tranches=None, plages=()):
        """`secours` : la catégorie à prendre si aucune règle ne range la ligne.
        `tranches` ({début: secondes}) et `plages` ([(début, fin, clé)]) : une ligne du Mac que rien ne
        range prend la catégorie de la plage horaire qui couvre chacune de ses tranches."""
        if not bundle or bundle in IGNORER or secondes <= 0:
            return
        if bundle == CLAUDE and doc and any(doc.rstrip("/") == str(r) for r in RACINES):
            doc = ""
        cle = classer_memo(bundle, titre, doc)
        ctx = contexte(bundle, titre, chemin_fichier(doc))
        if cle == NON_CLASSE and plages and tranches:
            for t, sec in tranches.items():
                p = next((c for a, b, c in plages if a <= t < b), None)
                if p:
                    self.tot[p] += sec
                    self.detail[p][(appareil, bundle, ctx)] += sec
                    secondes -= sec
            if secondes <= 0.5:
                return
        secours = resoudre_secours(secours)
        if cle == NON_CLASSE and secours:
            cle = secours
        if cle == NON_CLASSE and appareil != "Mac":
            cle = appareil
        self.tot[cle] += secondes
        self.detail[cle][(appareil, bundle, ctx)] += secondes

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


TRANCHE = 300  # secondes : finesse des plages horaires

# Plages saisies à la main (réunion, rendez-vous, croquis) : [{id, debut, fin, cle, note}].
MANUEL = DONNEES / "manuel.json"


def manuels():
    try:
        return json.loads(MANUEL.read_text())
    except (OSError, ValueError):
        return []


def ajouter_manuel(debut, fin, cle, note=""):
    if not cle or fin <= debut:
        raise ValueError(tr("une plage demande un projet, et une fin après le début.", "a time block needs a project and an end after its start."))
    l = manuels()
    m = {"id": f"{int(time.time() * 1000):x}", "debut": float(debut), "fin": float(fin), "cle": cle, "note": note.strip()}
    MANUEL.parent.mkdir(parents=True, exist_ok=True)
    MANUEL.write_text(json.dumps(l + [m], ensure_ascii=False, indent=1))
    return m


def retirer_manuel(ident):
    l = manuels()
    reste = [m for m in l if m["id"] != ident]
    MANUEL.write_text(json.dumps(reste, ensure_ascii=False, indent=1))
    return next((m for m in l if m["id"] == ident), None)


def etiquette_manuelle():
    return tr("Plage saisie", "Manual block")


def manuel_a(t, liste):
    """La plage saisie qui couvre l'instant t (la plus récente l'emporte), ou None."""
    return next((m for m in reversed(liste) if m["debut"] <= t < m["fin"]), None)


class Brut:
    """Les relevés d'un jour avant classement : {(appareil, app, titre, doc, secours): [secondes, {tranche: secondes}]}.
    C'est ce qui va au cache : une règle posée ne fait que reclasser, sans relire les sources."""

    def __init__(self):
        self.lignes = {}

    def ajouter(self, t, appareil, bundle, secondes, titre="", doc="", secours=None):
        if not bundle or secondes <= 0:
            return
        l = self.lignes.setdefault((appareil, bundle, titre or "", doc or "", secours or ""), [0.0, {}])
        l[0] += secondes
        if appareil == "Mac":
            k = int(t // TRANCHE * TRANCHE)
            l[1][k] = l[1].get(k, 0.0) + secondes

    def classer(self, plages=(), saisies=()):
        """Classe le jour. Les petits moments du Mac que rien ne range (moins de `lissage` minutes dans la journée)
        prennent la catégorie de travail qui domine dans le quart d'heure autour d'eux.
        Une plage saisie à la main l'emporte : ce que le Mac a relevé pendant ce temps passe dans son projet
        (le détail reste), sauf ce qui est déjà rangé dans un autre projet, qui reste tel quel ;
        le reste de la plage compte comme temps « Manuel »."""
        c = Collecte()
        seuil = float(REGLES.get("reglages", {}).get("lissage", 10)) * 60
        voisins = defaultdict(lambda: defaultdict(float))   # {tranche: {clé: secondes}}
        petits = []
        couvert = defaultdict(float)   # {id de plage: secondes du Mac dedans}
        for (ap, b, titre, doc, sec_), (sec, tr) in self.lignes.items():
            if saisies and ap == "Mac" and tr and b not in IGNORER:
                reste = {}
                cle0 = cle_simple(b, titre, doc, sec_)
                autre_projet = cle0 != NON_CLASSE and famille(cle0) == PROJETS
                for t, v in tr.items():
                    m = manuel_a(t, saisies)
                    if m and autre_projet and fusion_de(cle0) != m["cle"]:
                        couvert[m["id"]] += v   # déjà rangé dans un autre projet : reste tel quel
                        reste[t] = v
                    elif m:
                        c.tot[m["cle"]] += v
                        c.detail[m["cle"]][(ap, b, contexte(b, titre, chemin_fichier(doc)))] += v
                        couvert[m["id"]] += v
                        sec -= v
                    else:
                        reste[t] = v
                if sec <= 0.5:
                    continue
                tr = reste
            if seuil and ap == "Mac" and tr and b not in IGNORER:
                cle = cle_simple(b, titre, doc, sec_)
                if cle == NON_CLASSE and sec <= seuil:
                    petits.append(((ap, b, titre, doc, sec_), sec, tr))
                    continue
                if cle != NON_CLASSE and famille(cle) != HORS:
                    for t, v in tr.items():
                        voisins[t][cle] += v
            c.ajouter(ap, b, sec, titre, doc, sec_ or None, tr, plages)
        for (ap, b, titre, doc, sec_), sec, tr in petits:
            ctx = contexte(b, titre, chemin_fichier(doc))
            for t, v in tr.items():
                autour = defaultdict(float)
                for k in range(-3, 4):
                    for cle, x in voisins.get(t + k * TRANCHE, {}).items():
                        autour[cle] += x
                cle = max(autour.items(), key=lambda kv: kv[1])[0] if autour else NON_CLASSE
                c.tot[cle] += v
                c.detail[cle][(ap, b, ctx)] += v
        for m in saisies:
            hors_mac = (m["fin"] - m["debut"]) - couvert.get(m["id"], 0)
            if hors_mac > 0.5:
                c.tot[m["cle"]] += hors_mac
                c.detail[m["cle"]][("Manuel", "manuel", m.get("note") or etiquette_manuelle())] += hors_mac
        return c

    def vers_json(self):
        return [[*k, sec, tr] for k, (sec, tr) in self.lignes.items()]

    @classmethod
    def depuis_json(cls, lignes):
        b = cls()
        for ap, bundle, titre, doc, sec_, sec, tr in lignes:
            b.lignes[(ap, bundle, titre, doc, sec_)] = [sec, {int(k): v for k, v in tr.items()}]
        return b


class ParJour:
    """Répartit chaque relevé dans le brut de son jour (selon l'heure de début)."""

    def __init__(self):
        self.jours = defaultdict(Brut)

    def ajouter(self, t, *args, **kw):
        self.jours[minuit(t)].ajouter(t, *args, **kw)


def frise(j):
    """La journée du Mac par tranches de 5 min : [{t, secondes, cle, nom, famille, serie, contexte}], et ses plages."""
    j = minuit(j + 3600)
    par_jour(j)
    b = _BRUTS.get(j) or _OUVERTS.get(j) or Brut()
    saisies = [m for m in manuels() if m["debut"] < j + JOUR + 3600 and m["fin"] > j]
    pl = [x for x in plages() if x[0] < j + JOUR + 3600 and x[1] > j]
    tranches = defaultdict(lambda: defaultdict(float))
    ctx = defaultdict(lambda: defaultdict(float))
    for (ap, bundle, titre, doc, sec_), (_, tr) in b.lignes.items():
        if ap != "Mac" or bundle in IGNORER:
            continue
        d = "" if bundle == CLAUDE and any(doc.rstrip("/") == str(r) for r in RACINES) else doc
        cle0 = classer_memo(bundle, titre, d)
        x = contexte(bundle, titre, chemin_fichier(d)) or nom_app(bundle)
        for t, sec in tr.items():
            cle = cle0
            m = manuel_a(t, saisies)
            if m and not (cle0 != NON_CLASSE and famille(cle0) == PROJETS):
                cle = m["cle"]
            elif cle == NON_CLASSE:
                cle = next((c for a, z, c in pl if a <= t < z), None) or resoudre_secours(sec_) or NON_CLASSE
            tranches[t][cle] += sec
            ctx[t][x] += sec
    for m in saisies:
        t = int(m["debut"] // TRANCHE * TRANCHE)
        while t < m["fin"]:
            if t not in tranches:
                tranches[t][m["cle"]] += min(TRANCHE, m["fin"] - t)
                ctx[t][m.get("note") or etiquette_manuelle()] += 1
            t += TRANCHE
    sortie = []
    for t in sorted(tranches):
        cle, _ = max(tranches[t].items(), key=lambda x: x[1])
        sortie.append({"t": t, "secondes": round(sum(tranches[t].values())), "cle": cle, "nom": NOMS.get(cle, cle),
                       "famille": famille(cle), "serie": serie(cle) if famille(cle) != HORS else HORS,
                       "contexte": max(ctx[t].items(), key=lambda x: x[1])[0]})
    return {"jour": j, "tranches": sortie,
            "plages": [{"motif": m, "cle": c, "nom": NOMS.get(c, c), "debut": a, "fin": z}
                       for m, a, z, c in plages(True) if a < j + JOUR + 3600 and z > j]}


def cle_simple(bundle, titre, doc, secours):
    """La catégorie d'une ligne du Mac par ses règles (sans plage horaire)."""
    if bundle == CLAUDE and doc and any(doc.rstrip("/") == str(r) for r in RACINES):
        doc = ""
    cle = classer_memo(bundle, titre, doc)
    if cle == NON_CLASSE:
        cle = resoudre_secours(secours or None) or NON_CLASSE
    return cle


def resoudre_secours(s):
    """La catégorie de secours d'une ligne brute (None si aucune)."""
    if not s:
        return None
    return s


_MEMO = {}


def classer_memo(bundle, titre, doc):
    k = (bundle, titre, doc)
    if k not in _MEMO:
        _MEMO[k] = classer(bundle, titre, doc)
    return _MEMO[k]


def plages(motifs=False):
    """[(début, fin, clé)] depuis [plages] : "2026-11-10 14:00-17:00" = "Studio / Dupont" (avec le motif en tête si `motifs`)."""
    sortie = []
    for motif, cle in REGLES.get("plages", {}).items():
        m = re.fullmatch(r"\s*(\d{4}-\d{2}-\d{2})\s+(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*", motif)
        if not m:
            continue
        j = time.mktime(time.strptime(m.group(1), "%Y-%m-%d"))
        a = j + int(m.group(2)) * 3600 + int(m.group(3)) * 60
        b = j + int(m.group(4)) * 3600 + int(m.group(5)) * 60
        if b > a:
            sortie.append((motif, a, b, cle) if motifs else (a, b, cle))
    return sortie


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
            return s[0], s[1] or ""
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
    """Change dès que le code de lecture change : les relevés bruts en cache sont alors relus.
    Les règles n'y entrent pas : le classement se refait à la lecture."""
    fichiers = [ICI / f for f in ("report.py", "biome.py", "claude.py")]
    return "-".join(str(f.stat().st_mtime_ns) for f in fichiers)




def _fichier_jour(j):
    return JOURS / f"{time.strftime('%Y-%m-%d', time.localtime(j))}.json"


def lire_jour(j, sig):
    try:
        d = json.loads(_fichier_jour(j).read_text())
        return Brut.depuis_json(d["brut"]) if d.get("signature") == sig else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def ecrire_jour(j, b, sig):
    try:
        JOURS.mkdir(parents=True, exist_ok=True)
        _fichier_jour(j).write_text(json.dumps({"signature": sig, "brut": b.vers_json()}))
    except OSError:
        pass


SECTIONS_QUI_RANGENT = ["fusions", "forcer", "titres", "apps", "chemins", "alias", "ignorer", "dossiers", "plages", "missions", "reglages"]
_BRUTS = {}     # {minuit: Brut} des jours clos, gardés en mémoire
_CLASSES = {}   # {minuit: Collecte} des jours clos, pour les règles en vigueur
_SIG = {"sources": None, "regles": None}
_OUVERTS = {}   # {minuit: Brut} des jours encore ouverts, du dernier calcul


def par_jour(debut):
    """{minuit: Collecte} depuis debut.

    En mode démo (TEMPS_DEMO=1), des données fictives remplacent toutes les sources.

    Les relevés bruts des jours clos depuis plus de 48 h (synchro iPhone comprise) viennent
    de la mémoire, sinon du cache disque ; le reste est relu en une passe depuis le premier
    jour manquant. Le classement se fait à la lecture : une règle posée ne relit aucune source.
    """
    if os.environ.get("TEMPS_DEMO"):
        import demo
        return demo.jours(debut)
    with _VERROU:
        return _par_jour(debut)


_DERNIER = {"cle": None, "t": 0.0, "jours": None}


def _par_jour(debut):
    aujourdhui = minuit(time.time())
    sig = signature()
    # seules les sections qui rangent comptent : une fiche, un nom ou une couleur ne relancent pas le classement
    saisies = manuels()
    regles = sig + json.dumps({k: REGLES.get(k) for k in SECTIONS_QUI_RANGENT}, sort_keys=True, ensure_ascii=False, default=str) + json.dumps(saisies)
    if _SIG["sources"] != sig:
        _BRUTS.clear()
    if _SIG["regles"] != regles:
        _CLASSES.clear()
        _MEMO.clear()
    _SIG.update(sources=sig, regles=regles)
    # l'app demande souvent deux ou trois vues à la fois : la même période, dans les deux secondes, ne se relit pas
    if _DERNIER["cle"] == (debut, regles) and time.time() - _DERNIER["t"] < 2:
        return _DERNIER["jours"]
    pl = plages()
    bruts = {}
    jour, clos = debut, minuit(aujourdhui - JOUR + 3600)
    while jour < clos:
        b = _BRUTS.get(jour) or lire_jour(jour, sig)
        if b is None:
            break
        bruts[jour] = _BRUTS[jour] = b
        jour = minuit(jour + JOUR + 3600)
    p = ParJour()
    idx = claude.Index(jour)
    mac(jour, p, idx)
    sessions = biome.sessions(jour)
    mac_couvert = float("inf")
    appareils(jour, p, idx, sessions, mac_couvert)
    for j, b in p.jours.items():
        if j >= jour:
            bruts[j] = b
    # tous les jours clos vont au cache, même vides : sinon on relit depuis le premier trou
    while jour < clos:
        bruts.setdefault(jour, Brut())
        _BRUTS[jour] = bruts[jour]
        ecrire_jour(jour, bruts[jour], sig)
        jour = minuit(jour + JOUR + 3600)
    _OUVERTS.clear()
    _OUVERTS.update({j: b for j, b in bruts.items() if j >= clos})
    jours = {}
    for j, b in bruts.items():
        du_jour = [x for x in pl if x[0] < j + JOUR + 3600 and x[1] > j]
        # une plage à cheval sur minuit est coupée à chaque jour
        s_jour = [dict(m, debut=max(m["debut"], j), fin=min(m["fin"], minuit(j + JOUR + 3600))) for m in saisies
                  if m["debut"] < minuit(j + JOUR + 3600) and m["fin"] > j]
        if j < clos:
            if j not in _CLASSES:
                _CLASSES[j] = en_missions(en_fusions(b.classer(du_jour, s_jour)), j)
            jours[j] = _CLASSES[j]
        else:
            jours[j] = en_missions(en_fusions(b.classer(du_jour, s_jour)), j)
    _DERNIER.update(cle=(debut, regles), t=time.time(), jours=jours)
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


# Nuances données d'office aux projets d'un groupe, dans l'ordre alphabétique (la couleur pleine reste au groupe).
NUANCES = 8  # pas de nuance, de 1 à 8 ; l'app les dessine en OKLCH
_CACHE_COULEURS = (None, 0, None)


def projets_connus():
    """Projets de chaque groupe (deuxième segment des noms), d'après les dossiers, les noms et les règles."""
    noms = set(NOMS) | set(NOMS.values()) | set(REGLES.get("projets", {}))
    for s in ("forcer", "titres", "apps", "chemins"):
        noms |= set(REGLES.get(s, {}).values())
    for g in groupes_dossiers():
        for d in g.iterdir():
            if not d.is_dir() or d.name.startswith((".", "00")):
                continue
            if d.name in INTERMEDIAIRES:
                noms |= {f"{g.name} / {x.name}" for x in d.iterdir() if x.is_dir() and not x.name.startswith(".")}
            else:
                noms.add(f"{g.name} / {d.name}")
    par = defaultdict(set)
    for n in noms:
        s = NOMS.get(n, n).split(" / ")
        if len(s) >= 2 and fusion_de(n) == n and n not in EXCLUS:
            par[s[0]].add(s[1].split(" · ")[0])
    return {g: sorted(p, key=str.lower) for g, p in par.items()}


def couleurs():
    """Couleur de chaque groupe : celle choisie dans [couleurs], sinon une teinte donnée d'office
    aux huit premiers groupes de dossiers, dans un ordre fixe. Les suivants restent gris.
    Chaque projet d'un groupe coloré reçoit d'office une nuance de sa couleur (« nuance:teinte:k »),
    sauf s'il a sa propre couleur dans [couleurs]."""
    global _CACHE_COULEURS
    r, t, v = _CACHE_COULEURS
    if r is REGLES and v is not None and time.time() - t < 60:
        return v
    choix = REGLES.get("couleurs", {})
    auto = [d.name for d in groupes_dossiers() if d.name not in choix]
    libres = [t for t in TEINTES_AUTO if t not in choix.values()]
    eff = {g: t for g, t in zip(auto, libres)}
    eff.update({g: c for g, c in choix.items() if " / " not in g})
    for g, liste in projets_connus().items():
        if g in eff:
            for i, p in enumerate(liste):
                eff[f"{g} / {p}"] = f"nuance:{eff[g]}:{1 + i % NUANCES}"
    eff.update(choix)
    _CACHE_COULEURS = (REGLES, time.time(), eff)
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
    segs = NOMS.get(PARENT.get(cle, cle), PARENT.get(cle, cle)).split(" / ")
    if len(segs) >= 2 and f"{segs[0]} / {segs[1]}" in eff:
        return f"{segs[0]} / {segs[1]}"  # projet d'un groupe : sa nuance
    groupe = segs[0]
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


def histogramme(jours, n=7, fin=None):
    """Travail des n jours qui finissent aujourd'hui (ou le jour `fin`), du plus ancien au plus récent, réparti par série."""
    aujourdhui = minuit(fin + 3600) if fin else minuit(time.time())
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
    sortie = io.StringIO()
    ecrire = csv.writer(sortie, delimiter=";", lineterminator="\n").writerow
    ecrire(tr("Mois;Famille;Catégorie;Heures;Facturable;Heures vendues;Montant HT",
              "Month;Family;Category;Hours;Billable;Hours sold;Amount excl. tax").split(";"))
    noms_familles = {PROJETS: tr(PROJETS, "Projects"), ACTIVITE: tr(ACTIVITE, "Activities"),
                     HORS: tr(HORS, "Off work"), NON_CLASSE: tr(NON_CLASSE, "Unsorted")}
    for cle, sec in sorted(c.tot.items(), key=lambda x: (famille(x[0]), -x[1])):
        if sec < 60:
            continue
        f = fiche(cle)
        fact = f.get("facturable", famille(cle) == PROJETS)
        h = f"{sec / 3600:.2f}"
        ecrire([mois, noms_familles[famille(cle)], NOMS.get(cle, cle), h.replace(".", ",") if LANGUE == "fr" else h,
                tr("oui", "yes") if fact else tr("non", "no"), f.get("vendu", ""), f.get("montant", "")])
    return sortie.getvalue()


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
    sig = f"{hash(_SIG['regles'])}-{len(tous)}"
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
