import json
from pathlib import Path

from django.core.management.base import BaseCommand
from django.db import connection, transaction

FIXTURE = Path(__file__).resolve().parents[4] / "fixtures" / "data.json"


class Command(BaseCommand):
    help = "Replace the shop tables' contents with spec/parity/fixtures/data.json (the same rows Rails seeds)."

    def handle(self, *args, **options):
        data = json.loads(FIXTURE.read_text())
        tables = [t for t in data if not t.startswith("_")]
        # Raw inserts, so both apps store exactly the fixture's column values.
        with transaction.atomic(), connection.cursor() as cur:
            quote = connection.ops.quote_name  # "…" on PostgreSQL/SQLite, `…` on MySQL
            for table in reversed(tables):
                cur.execute(f"DELETE FROM {quote(table)}")
            for table in tables:
                for row in data[table]:
                    cols = list(row)
                    values = [json.dumps(v) if isinstance(v, (dict, list)) else v for v in row.values()]
                    values = [_db_value(table, c, v) for c, v in zip(cols, values)]
                    cur.execute(
                        f"INSERT INTO {quote(table)} ({', '.join(quote(c) for c in cols)}) "
                        f"VALUES ({', '.join(['%s'] * len(cols))})",
                        values,
                    )
        self.stdout.write(f"Loaded {', '.join(f'{t}={len(data[t])}' for t in tables)}")


def _db_value(table, column, value):
    # Django stores datetimes in SQLite as "YYYY-MM-DD HH:MM:SS" (UTC when USE_TZ).
    if table == "orders" and column == "placed_at":
        return value.replace("T", " ").rstrip("Z")
    return value
