"""The engine registry and the database's voting_methods table must list the same methods with the same capabilities."""
import re
from pathlib import Path

from app.domain.voting_methods import registry

MIGRATIONS = Path(__file__).resolve().parents[2] / "database" / "migrations"


def sql_methods() -> dict[str, dict]:
    text = "\n".join(p.read_text() for p in sorted(MIGRATIONS.glob("*.sql")))
    out: dict[str, dict] = {}
    for block in re.findall(r"insert into public\.voting_methods \(([^)]*)\) values(.*?);", text, re.S | re.I):
        cols = [c.strip() for c in block[0].split(",")]
        for row in re.findall(r"\(\s*'((?:[^']|'')*)'\s*,(.*?)\)\s*(?:,|$)", block[1].strip(), re.S):
            vals = [v.strip().strip("'").replace("''", "'") for v in re.split(r",\s*(?=(?:[^']*'[^']*')*[^']*$)", "'" + row[0] + "'," + row[1])]
            out[vals[0]] = dict(zip(cols, vals))
    return out


def test_registry_matches_database_seed():
    db = sql_methods()
    engine = {m.key: m for m in registry.all_methods()}
    assert set(db) == set(engine), f"registry {set(engine)} vs migrations {set(db)}"
    for key, m in engine.items():
        assert db[key]["category"] == m.category and db[key]["ballot_type"] == m.ballot_type, key
        assert (db[key].get("supports_threshold", "false") == "true") == m.supports_threshold, key
        assert (int(db[key]["max_seats"]) if db[key].get("max_seats") else None) == m.max_seats, key
