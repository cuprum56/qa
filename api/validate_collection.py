#!/usr/bin/env python3
"""Проверка целостности коллекции Postman: схема v2.1 + синтаксис всех скриптов."""
import io
import json
import os
import subprocess
import sys
import tempfile

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "postman_collection.json")


def collect(items, depth=0):
    out = []
    for it in items:
        if "item" in it:
            out.extend(collect(it["item"], depth + 1))
        else:
            out.append(it)
    return out


def main():
    with io.open(PATH, encoding="utf-8") as fh:
        col = json.load(fh)

    problems = []

    if col["info"].get("schema", "").endswith("v2.1.0/collection.json") is False:
        problems.append("info.schema не указывает на v2.1.0")

    reqs = collect(col["item"])
    folders = col["item"]

    counts = {}
    for f in folders:
        counts[f["name"]] = len(f["item"])

    for r in reqs:
        if "event" not in r:
            continue
        for ev in r["event"]:
            script = ev.get("script", {})
            if script.get("type") != "text/javascript":
                problems.append("%s: тип скрипта %s" % (r["name"], script.get("type")))
            src = script.get("exec")
            if not isinstance(src, list) or not all(isinstance(x, str) for x in src):
                problems.append("%s: exec должен быть массивом строк" % r["name"])
                continue
            code = "\n".join(src)
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                             encoding="utf-8") as fh:
                fh.write(code)
                tmp = fh.name
            proc = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
            os.unlink(tmp)
            if proc.returncode != 0:
                problems.append("%s [%s]: %s" % (r["name"], ev["listen"],
                                                proc.stderr.strip().split("\n")[1]))

    for ev in col.get("event", []):
        code = "\n".join(ev["script"]["exec"])
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as fh:
            fh.write(code)
            tmp = fh.name
        proc = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        os.unlink(tmp)
        if proc.returncode != 0:
            problems.append("collection-level [%s]: %s"
                            % (ev["listen"], proc.stderr.strip().split("\n")[1]))

    known = sum(1 for r in reqs if r["name"].startswith("[KNOWN BUG]"))
    asserts = 0
    for r in reqs:
        for ev in r.get("event", []):
            if ev["listen"] == "test":
                asserts += sum(1 for ln in ev["script"]["exec"] if "pm.test(" in ln)

    print("Файлов в схеме v2.1.0: %d" % len(folders))
    for name, n in counts.items():
        print("  %-20s %2d" % (name, n))
    print("Всего запросов:            %d" % len(reqs))
    print("Сценариев [KNOWN BUG]:     %d" % known)
    print("Проверок (pm.test):        %d" % asserts)

    if problems:
        print("\nОшибок: %d" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1
    print("\nОшибок нет.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
