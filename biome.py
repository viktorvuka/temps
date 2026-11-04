"""Lecture des flux Biome App.InFocus (Mac local + appareils synchronisés)."""
import os, sqlite3, struct
from pathlib import Path

BIOME = Path.home() / "Library/Biome"
INFOCUS = BIOME / "streams/restricted/App.InFocus"
MAC_EPOCH = 978307200  # 2001-01-01 en temps Unix
PLATEFORMES = {1: "iPad", 2: "iPhone", 4: "Mac", 5: "Apple TV", 7: "Watch"}


def _varint(b, i):
    v = s = 0
    while True:
        c = b[i]; i += 1
        v |= (c & 0x7F) << s; s += 7
        if not c & 0x80:
            return v, i


def _protobuf(b):
    champs, i = {}, 0
    while i < len(b):
        cle, i = _varint(b, i)
        num, typ = cle >> 3, cle & 7
        if typ == 0:
            v, i = _varint(b, i)
        elif typ == 1:
            v = struct.unpack_from("<d", b, i)[0]; i += 8
        elif typ == 2:
            n, i = _varint(b, i); v = b[i:i + n]; i += n
        elif typ == 5:
            v = b[i:i + 4]; i += 4
        else:
            break
        champs.setdefault(num, v)
    return champs


def _segb(chemin):
    """Enregistrements d'un fichier SEGB v2 : (debut, est_ouverture, bundle)."""
    data = Path(chemin).read_bytes()
    if data[:4] != b"SEGB":
        return
    nb = struct.unpack_from("<I", data, 4)[0]
    debut = 0
    for k in range(nb):
        pos = len(data) - 16 * (k + 1)
        if pos < 32:
            break
        fin, etat = struct.unpack_from("<II", data, pos)
        if fin <= debut or 32 + fin > len(data):
            break
        rec = data[32 + debut + 8:32 + fin]
        debut = (fin + 3) & ~3
        if etat != 1:
            continue
        try:
            c = _protobuf(rec)
        except (IndexError, struct.error):
            continue
        if 4 in c and 6 in c:
            yield c[4] + MAC_EPOCH, bool(c.get(3)), c[6].decode("utf-8", "replace")


def appareils():
    """{dossier: nom lisible} d'après la base de synchro Biome."""
    noms = {}
    try:
        con = sqlite3.connect(f"file:{BIOME}/sync/sync.db?mode=ro", uri=True)
        for ident, moi, plat in con.execute("select device_identifier, me, platform from DevicePeer"):
            noms[ident] = "Mac" if moi else PLATEFORMES.get(plat, f"appareil {plat}")
    except sqlite3.Error:
        pass
    return noms


def sessions(depuis=0.0):
    """Liste de (appareil, bundle, debut, fin) en temps Unix."""
    noms = appareils()
    sources = [("Mac", INFOCUS / "local")]
    sources += [(noms.get(d.name, "?"), d) for d in (INFOCUS / "remote").iterdir() if d.is_dir()]  # PermissionError sans accès complet au disque
    sortie = []
    for nom, dossier in sources:
        evts = []
        for f in dossier.iterdir():
            if f.is_file() and f.stat().st_mtime >= depuis:
                evts.extend(_segb(f))
        evts.sort()
        ouvert = {}
        for t, ouverture, bundle in evts:
            if ouverture:
                ouvert[bundle] = t
            elif bundle in ouvert:
                t0 = ouvert.pop(bundle)
                if 0 < t - t0 < 4 * 3600 and t >= depuis:
                    sortie.append((nom, bundle, t0, t))
    return sortie
