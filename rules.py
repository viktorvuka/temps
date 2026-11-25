"""Écriture dans regles.toml sans perdre les commentaires : une ligne par règle, insérée en tête de sa section."""
import json, os, re, tomllib
from pathlib import Path

FICHIER = (Path(os.environ["TEMPS_REGLES"]) if os.environ.get("TEMPS_REGLES")
           else Path.home() / "Library/Application Support/Temps/demo/rules.toml" if os.environ.get("TEMPS_DEMO")
           else Path(__file__).resolve().parent / "rules.toml")
LANGUE = os.environ.get("TEMPS_LANGUE", "fr")[:2]
SECTIONS = {"titres", "apps", "chemins", "noms", "projets", "reperes", "couleurs", "plages", "archives", "missions", "reglages", "forcer", "fusions", "domaines", "partages"}


def _valeur(v):
    """Valeur TOML d'une ligne : chaîne, nombre, booléen, ou table en ligne { a = 1, b = "x" }."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, dict):
        cle = lambda k: k if re.fullmatch(r"[A-Za-z0-9_-]+", k) else json.dumps(k, ensure_ascii=False)
        return "{ " + ", ".join(f"{cle(k)} = {_valeur(x)}" for k, x in v.items() if x is not None) + " }"
    return json.dumps(v, ensure_ascii=False)


def _cle(ligne):
    m = re.match(r'\s*("(?:[^"\\]|\\.)*")\s*=', ligne)
    return json.loads(m.group(1)) if m else None


def _section(lignes, nom):
    """Index de l'en-tête de section et index de fin (exclu)."""
    debut = next(i for i, l in enumerate(lignes) if re.match(rf"\[{nom}\]", l.strip()))
    fin = next((i for i in range(debut + 1, len(lignes)) if lignes[i].lstrip().startswith("[")), len(lignes))
    return debut, fin


def poser(section, motif, valeur):
    """Pose motif = valeur (remplace s'il existe). Rend l'ancienne valeur, ou None."""
    if section not in SECTIONS:
        raise ValueError(f"Section inconnue : {section}")
    lignes = FICHIER.read_text().splitlines()
    if not any(re.match(rf"\[{section}\]", l.strip()) for l in lignes):
        lignes += ["", f"[{section}]"]
    debut, fin = _section(lignes, section)
    nouvelle = f"{json.dumps(motif, ensure_ascii=False)} = {_valeur(valeur)}"
    avant = None
    for i in range(debut + 1, fin):
        if _cle(lignes[i]) == motif:
            avant = tomllib.loads(lignes[i])[motif]
            lignes[i] = nouvelle
            break
    else:
        # en tête de section : une règle posée à la main l'emporte sur les règles générales
        lignes.insert(debut + 1, nouvelle)
    _ecrire(lignes)
    return avant


def retirer(section, motif):
    lignes = FICHIER.read_text().splitlines()
    debut, fin = _section(lignes, section)
    lignes = [l for i, l in enumerate(lignes) if not (debut < i < fin and _cle(l) == motif)]
    _ecrire(lignes)


def remplacer(section, ancien, motif, valeur):
    """Change le motif ou la catégorie d'une règle, à sa place dans le fichier. Rend l'ancienne valeur."""
    if section not in SECTIONS:
        raise ValueError(f"Section inconnue : {section}")
    lignes = FICHIER.read_text().splitlines()
    debut, fin = _section(lignes, section)
    nouvelle = f"{json.dumps(motif, ensure_ascii=False)} = {_valeur(valeur)}"
    for i in range(debut + 1, fin):
        if _cle(lignes[i]) == ancien:
            avant = tomllib.loads(lignes[i])[ancien]
            lignes = [l for j, l in enumerate(lignes) if not (debut < j < fin and j != i and _cle(l) == motif)]
            i = next(j for j, l in enumerate(lignes) if debut < j and _cle(l) == ancien)
            lignes[i] = nouvelle
            _ecrire(lignes)
            return avant
    raise KeyError(ancien)


def ecrire_domaines(liste):
    """Réécrit toute la section [domaines] dans l'ordre donné : [{nom, nature, projets}]. Rend le texte d'avant."""
    avant = FICHIER.read_text()
    lignes = avant.splitlines()
    if not any(re.match(r"\[domaines\]", l.strip()) for l in lignes):
        lignes += ["", "[domaines]  # domaine = { nature (projets, activites, hors_travail), projets }"]
    debut, fin = _section(lignes, "domaines")
    garde = [l for l in lignes[debut + 1:fin] if l.strip().startswith("#") or not l.strip()]
    nouvelles = [f"{json.dumps(d['nom'], ensure_ascii=False)} = {_valeur({'nature': d['nature'], 'projets': d['projets']})}"
                 for d in liste if d.get("nom", "").strip()]
    lignes[debut + 1:fin] = [g for g in garde if g.strip().startswith("#")] + nouvelles + [""]
    _ecrire(lignes)
    return avant


def _ecrire(lignes):
    texte = "\n".join(lignes) + "\n"
    tomllib.loads(texte)  # refuse d'écrire un fichier invalide
    FICHIER.write_text(texte)


FAMILLES = {"Activités": "activites", "Hors travail": "hors_travail"}


def famille(cle, nouvelle):
    """Range une catégorie dans une famille (« Projets » = aucune liste). Rend l'ancienne famille."""
    lignes = FICHIER.read_text().splitlines()
    debut, fin = _section(lignes, "familles")
    avant = "Projets"
    for i in range(debut + 1, fin):
        m = re.match(r"\s*(\w+)\s*=", lignes[i])
        if not m or m.group(1) not in FAMILLES.values():
            continue
        liste = tomllib.loads(lignes[i])[m.group(1)]
        if cle in liste:
            avant = next(k for k, v in FAMILLES.items() if v == m.group(1))
            liste.remove(cle)
        if FAMILLES.get(nouvelle) == m.group(1):
            liste.append(cle)
        lignes[i] = f"{m.group(1)} = {json.dumps(liste, ensure_ascii=False)}"
    _ecrire(lignes)
    return avant


def supprimer(cle):
    """Retire toute règle qui mène à cette catégorie, et sa fiche, son nom, son repère, sa famille.
    Rend le texte d'avant (pour l'annulation), ou lève ValueError si aucune règle ne la porte."""
    avant = FICHIER.read_text()
    lignes = avant.splitlines()
    garde, section, retire = [], None, 0
    for l in lignes:
        m = re.match(r"\s*\[(\w+)\]", l)
        if m:
            section = m.group(1)
        elif section in ("forcer", "titres", "apps", "chemins") and _cle(l) is not None and tomllib.loads(l).get(_cle(l)) == cle:
            retire += 1
            continue
        elif section in ("noms", "projets", "reperes") and _cle(l) == cle:
            retire += 1
            continue
        garde.append(l)
    _ecrire(garde)
    if famille(cle, "Projets") != "Projets":
        retire += 1
    if not retire:
        # une catégorie qui vient d'un dossier : on exclut le dossier du classement d'office
        exclure(cle)
    return avant


def exclure(cle):
    """Ajoute une catégorie de dossier à [dossiers] exclus : ses fichiers ne se rangent plus d'office."""
    lignes = FICHIER.read_text().splitlines()
    debut, fin = _section(lignes, "dossiers")
    for i in range(debut + 1, fin):
        if re.match(r"\s*exclus\s*=", lignes[i]):
            liste = tomllib.loads(lignes[i])["exclus"]
            if cle not in liste:
                lignes[i] = "exclus = " + json.dumps(liste + [cle], ensure_ascii=False)
            break
    else:
        fin_utile = fin
        while fin_utile > debut + 1 and not lignes[fin_utile - 1].strip():
            fin_utile -= 1
        lignes.insert(fin_utile, "exclus = " + json.dumps([cle], ensure_ascii=False))
    _ecrire(lignes)


def restaurer(texte):
    tomllib.loads(texte)
    FICHIER.write_text(texte)


def lot(liste):
    """Pose plusieurs règles d'un coup. Rend le texte d'avant, pour tout annuler d'un geste."""
    avant = FICHIER.read_text()
    try:
        for r in liste:
            poser(r["section"], r["motif"], r["valeur"])
    except Exception:
        FICHIER.write_text(avant)
        raise
    return avant
