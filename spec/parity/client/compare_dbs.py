#!/usr/bin/env python3
"""
Check that the Django reference DB and the Rails dummy DB hold the same schema
and rows (both seeded from spec/parity/fixtures/data.json). Run after
bin/django-server (or manage.py migrate + load_parity_data) and
bin/rails db:prepare db:seed.

    compare_dbs.py [--django PATH] [--rails PATH]

Compared per shared table: column names, primary key, NOT NULL flags, and every
row by primary key. Values are normalised for storage differences that do not
change meaning: JSON text is parsed, numbers compared numerically.
"""
import argparse
import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TABLES = ["categories", "customers", "products", "orders", "line_items"]


def columns(conn, table):
    return {r[1]: {"notnull": bool(r[3]), "pk": bool(r[5])} for r in conn.execute(f'PRAGMA table_info("{table}")')}


def norm(value):
    if isinstance(value, str) and value[:1] in "{[":
        try:
            return json.loads(value)
        except ValueError:
            return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return round(float(value), 6)
    return value


def rows(conn, table, cols, pk):
    names = sorted(cols)
    sql = f'SELECT {", ".join(chr(34) + c + chr(34) for c in names)} FROM "{table}"'
    return {r[names.index(pk)]: {c: norm(v) for c, v in zip(names, r)} for r in conn.execute(sql)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--django", type=Path, default=ROOT / "spec/parity/django_app/db.sqlite3")
    ap.add_argument("--rails", type=Path, default=ROOT / "spec/dummy/storage/development.sqlite3")
    args = ap.parse_args()
    dj, rb = sqlite3.connect(args.django), sqlite3.connect(args.rails)

    problems = []
    for table in TABLES:
        dc, rc = columns(dj, table), columns(rb, table)
        if set(dc) != set(rc):
            problems.append(f"{table}: columns differ: django-only {sorted(set(dc) - set(rc))}, "
                            f"rails-only {sorted(set(rc) - set(dc))}")
            print(f"FAIL {table}")
            continue
        for col in dc:
            if dc[col] != rc[col]:
                problems.append(f"{table}.{col}: django {dc[col]} vs rails {rc[col]}")
        pk = next(c for c, info in dc.items() if info["pk"])
        dr, rr = rows(dj, table, dc, pk), rows(rb, table, rc, pk)
        if set(dr) != set(rr):
            problems.append(f"{table}: row keys differ: django-only {sorted(set(dr) - set(rr))}, "
                            f"rails-only {sorted(set(rr) - set(dr))}")
        for key in sorted(set(dr) & set(rr), key=str):
            for col in dr[key]:
                if dr[key][col] != rr[key][col]:
                    problems.append(f"{table}[{key}].{col}: django {dr[key][col]!r} vs rails {rr[key][col]!r}")
        print(f"{'ok  ' if not any(p.startswith(table) for p in problems) else 'FAIL'} {table}: "
              f"{len(dc)} columns, {len(dr)} rows")

    for p in problems:
        print("     " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
