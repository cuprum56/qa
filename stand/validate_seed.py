#!/usr/bin/env python3
"""Сверка seed-данных со схемой из миграций: usage: validate_seed.py [путь/к/gra]

Путь к исходникам берётся из аргумента или APP_DIR.
"""
import io
import os
import re
import sys

SEEDS = {
    "users_db": ("stand/000_users_db.sql", "user-service"),
    "projects_db": ("stand/100_projects_db.sql", "project-service"),
    "observations_db": ("stand/200_observations_db.sql", "observation-service"),
}

CREATE_TABLE = re.compile(
    r"CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+(\w+)\s*\((.*?)\n\);",
    re.S | re.I,
)
DROP_COLUMN = re.compile(
    r"ALTER\s+TABLE\s+(\w+)\s+DROP\s+COLUMN(?:\s+IF\s+EXISTS)?\s+(\w+)", re.I)
ADD_COLUMN = re.compile(
    r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN(?:\s+IF\s+NOT\s+EXISTS)?\s+(\w+)", re.I)
INSERT = re.compile(
    r"INSERT\s+INTO\s+(\w+)\s*\(([^)]*)\)", re.I)
NOT_A_COLUMN = re.compile(
    r"^(UNIQUE|PRIMARY|FOREIGN|CHECK|CONSTRAINT|EXCLUDE|INDEX)\b", re.I)


def read(path):
    with io.open(path, encoding="utf-8") as fh:
        return fh.read()


def columns_of(table, body):
    cols = []
    for line in body.split("\n"):
        line = line.strip().rstrip(",")
        if not line or NOT_A_COLUMN.match(line):
            continue
        name = line.split()[0]
        if re.fullmatch(r"\w+", name):
            cols.append(name)
    return cols


def build_schema(app_dir):
    schema = {db: {} for db in SEEDS}
    for db, (_, service) in SEEDS.items():
        migrations = os.path.join(app_dir, "backend", service, "migrations")
        if not os.path.isdir(migrations):
            raise SystemExit("нет каталога миграций: %s\n"
                             "укажите путь: validate_seed.py /путь/к/gra" % migrations)
        for name in sorted(os.listdir(migrations)):
            if not name.endswith(".sql"):
                continue
            sql = read(os.path.join(migrations, name))
            for match in CREATE_TABLE.finditer(sql):
                schema[db][match.group(1)] = set(columns_of(match.group(1), match.group(2)))
            for match in DROP_COLUMN.finditer(sql):
                schema[db].get(match.group(1), set()).discard(match.group(2))
            for match in ADD_COLUMN.finditer(sql):
                schema[db].setdefault(match.group(1), set()).add(match.group(2))
    return schema


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if len(sys.argv) > 1:
        app_dir = sys.argv[1]
    else:
        app_dir = os.environ.get("APP_DIR", "")
    if not app_dir:
        raise SystemExit("укажите путь к исходникам: "
                         "APP_DIR=/путь/к/gra python3 stand/validate_seed.py")

    schema = build_schema(app_dir)
    problems = []

    for db, (seed_rel, _) in sorted(SEEDS.items()):
        seed_path = os.path.join(repo_root, seed_rel)
        if not os.path.exists(seed_path):
            problems.append("нет файла seed: %s" % seed_rel)
            continue
        sql = read(seed_path)
        print("== %s ==" % db)
        for table in sorted(schema[db]):
            print("   %-22s %s" % (table, ", ".join(sorted(schema[db][table]))))
        print("   seed: %s" % seed_rel)
        for match in INSERT.finditer(sql):
            table = match.group(1)
            cols = [c.strip() for c in match.group(2).split(",") if c.strip()]
            known = schema[db].get(table)
            if known is None:
                problems.append("%s: таблица %s не создана миграциями %s" % (seed_rel, table, db))
                continue
            unknown = [c for c in cols if c not in known]
            if unknown:
                problems.append("%s: в %s нет колонок %s" % (seed_rel, table, ", ".join(unknown)))
            else:
                print("      %-22s %d колонок - ok" % (table, len(cols)))
        print()

    if problems:
        print("Найдены расхождения со схемой:")
        for p in problems:
            print("  x %s" % p)
        return 1
    print("+ Seed соответствует схеме, заданной миграциями.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
