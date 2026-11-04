"""Sessions Claude Code (app de bureau) : titre, dossier et instants d'activité, d'après ~/.claude/projects."""
import bisect, json, re, time
from datetime import datetime
from pathlib import Path

PROJETS = Path.home() / ".claude/projects"
CACHE = Path.home() / "Library/Application Support/Temps/sessions-claude.json"
FENETRE = 10 * 60  # un relevé se rattache au dernier message des 10 minutes précédentes

_HORODATE = re.compile(r'"timestamp":"([^"]+)"')
_TITRE = re.compile(r'"(?:customTitle|agentName)":"((?:[^"\\]|\\.)*)"')
_CWD = re.compile(r'"cwd":"((?:[^"\\]|\\.)*)"')


def _lire(f):
    instants, titre, cwd = [], None, None
    with open(f, encoding="utf-8", errors="replace") as fh:
        for ligne in fh:
            if '"type":"custom-title"' in ligne or ('"type":"agent-name"' in ligne and not titre):
                m = _TITRE.search(ligne)
                if m:
                    titre = json.loads(f'"{m.group(1)}"')
            elif ligne.startswith('{"type":"user"') or '"type":"user"' in ligne[:200]:
                m = _HORODATE.search(ligne)
                if m:
                    instants.append(datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp())
                if not cwd:
                    c = _CWD.search(ligne)
                    cwd = c and json.loads(f'"{c.group(1)}"')
    return {"titre": titre, "cwd": cwd, "instants": instants}


class Index:
    """Index des sessions modifiées depuis une date, mis en cache par date de modification."""

    def __init__(self, depuis):
        try:
            cache = json.loads(CACHE.read_text())
        except (OSError, ValueError):
            cache = {}
        # le cache garde toutes les sessions lues, quelle que soit la période demandée
        neuf, self.points, change = dict(cache), [], False
        for f in PROJETS.glob("*/*.jsonl"):
            mtime = f.stat().st_mtime
            if mtime < depuis:
                continue
            cle = str(f)
            e = cache.get(cle)
            if not e or e["mtime"] != mtime:
                e = {"mtime": mtime, **_lire(f)}
                neuf[cle], change = e, True
            nom = e["titre"] or f.stem[:8]
            self.points += [(t, nom, e["cwd"]) for t in e["instants"] if t >= depuis - FENETRE]
        self.points.sort()
        self.temps = [p[0] for p in self.points]
        if change:
            try:
                CACHE.parent.mkdir(parents=True, exist_ok=True)
                CACHE.write_text(json.dumps(neuf))
            except OSError:
                pass

    def session(self, t):
        """(titre, dossier) de la session active à l'instant t, ou None."""
        i = bisect.bisect_right(self.temps, t) - 1
        if i >= 0 and t - self.temps[i] <= FENETRE:
            return self.points[i][1], self.points[i][2]
        return None


if __name__ == "__main__":
    t0 = time.time()
    idx = Index(time.time() - 7 * 86400)
    print(len(idx.points), "messages", round(time.time() - t0, 1), "s")
    print(idx.session(time.time() - 60))
