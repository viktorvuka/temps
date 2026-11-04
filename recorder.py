"""Échantillonne l'activité du Mac toutes les 10 s dans une base SQLite locale."""
import sqlite3, subprocess, time, urllib.parse
from pathlib import Path

ICI = Path(__file__).resolve().parent
DONNEES = Path.home() / "Library/Application Support/Temps"
BASE = DONNEES / "activite.db"
PAS = 10          # secondes entre deux relevés
INACTIF = 120     # au-delà, on considère que tu n'es pas devant l'écran

ADOBE_DOC = 'tell application id "{b}" to get POSIX path of (file path of {doc} as alias)'


def inactivite():
    sortie = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    for ligne in sortie.splitlines():
        if "HIDIdleTime" in ligne:
            return int(ligne.split()[-1]) / 1e9
    return 0.0


def media_en_cours():
    """Une vidéo ou une visio en cours empêche la mise en veille de l'écran : on reste « devant l'écran » sans toucher le clavier."""
    sortie = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True).stdout
    for ligne in sortie.splitlines():
        if ligne.strip().startswith("PreventUserIdleDisplaySleep"):
            return ligne.split()[-1] != "0"
    return False


def osa(script, fichier=False):
    args = ["osascript", script] if fichier else ["osascript", "-e", script]
    r = subprocess.run(args, capture_output=True, text=True, timeout=5)
    return r.stdout.strip()


def releve():
    bundle, titre, doc = (osa(str(ICI / "capture.applescript"), True).split("|", 2) + ["", ""])[:3]
    try:
        if bundle == "com.apple.mail":
            # titre : « compte / boîte » ; doc : l'adresse du correspondant
            lieu, _, adresse = osa(str(ICI / "mail.applescript"), True).partition("|")
            titre, doc = lieu or titre, f"mailto:{adresse}" if adresse else doc
        elif bundle == "com.apple.Notes":
            titre = osa(str(ICI / "notes.applescript"), True) or titre
        elif bundle == "com.culturedcode.ThingsMac":
            titre = osa(str(ICI / "things.applescript"), True) or titre
    except subprocess.TimeoutExpired:
        pass
    if not doc and bundle.startswith("com.adobe."):
        objet = "current document" if "Photoshop" in bundle or "photoshop" in bundle else "active document"
        try:
            doc = osa(ADOBE_DOC.format(b=bundle, doc=objet))
        except subprocess.TimeoutExpired:
            pass
    if doc.startswith("file://"):
        doc = urllib.parse.unquote(doc[7:])
    return bundle, titre, doc


def main():
    BASE.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(BASE)
    con.execute("create table if not exists releves (t real, duree real, bundle text, titre text, doc text, inactif int)")
    while True:
        t = time.time()
        try:
            bundle, titre, doc = releve()
        except Exception:
            bundle, titre, doc = "", "", ""
        repos = inactivite()
        inactif = repos > INACTIF and not media_en_cours()
        if inactif:
            # toute la période sans clavier ni souris est retirée, pas seulement ce qui suit le seuil
            con.execute("update releves set inactif = 1 where t >= ? and inactif = 0", (t - repos,))
        con.execute("insert into releves values (?,?,?,?,?,?)", (t, PAS, bundle, titre, doc, int(inactif)))
        con.commit()
        time.sleep(max(1, PAS - (time.time() - t)))


if __name__ == "__main__":
    main()
