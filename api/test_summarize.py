#!/usr/bin/env python3
"""Тест классификатора api/summarize.py на собранных вручную отчётах Newman.

    usage: python3 api/test_summarize.py

Стенд не нужен: summarize.py читает готовый JSON. Ждём пять подтестов и код 0.
"""
import io
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARIZE = os.path.join(HERE, "summarize.py")
COLLECTION = os.path.join(HERE, "postman_collection.json")

KNOWN = "[KNOWN BUG] Дефект %02d"


def execution(name, failures=0, request_error=False):
    assertions = [
        {"assertion": "проверка %d" % i, "skipped": False, "error": None}
        for i in range(failures + 1)
    ]
    for i in range(failures):
        assertions[i]["error"] = {"name": "AssertionError", "message": "ожидалось иное"}
    ex = {"item": {"name": name}, "assertions": assertions}
    if request_error:
        ex["requestError"] = "connect ECONNREFUSED 127.0.0.1:8080"
    return ex


def report(executions):
    total = sum(len(e["assertions"]) for e in executions)
    failed = sum(1 for e in executions for a in e["assertions"] if a.get("error"))
    return {
        "run": {
            "stats": {"assertions": {"total": total, "failed": failed}},
            "executions": executions,
        }
    }


def run(data, with_collection=True):
    path = tempfile.mktemp(suffix=".json")
    with io.open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    cmd = [sys.executable, SUMMARIZE, path]
    if with_collection:
        cmd.append(COLLECTION)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(path)
    return proc.returncode, proc.stdout + proc.stderr


CASES = [
    (
        "код 0: дефекты на месте",
        0,
        report([execution("Health"), execution(KNOWN % 1), execution(KNOWN % 2)]),
        ["Регрессий нет", "Дефектов на месте: 2"],
    ),
    (
        "код 1: регрессия в обычном сценарии",
        1,
        report([execution("Health", failures=1), execution(KNOWN % 1)]),
        ["РЕГРЕССИИ"],
    ),
    (
        "код 3: дефект перестал воспроизводиться",
        3,
        report([execution("Health"), execution(KNOWN % 1, failures=1)]),
        ["ДЕФЕКТ ПЕРЕСТАЛ ВОСПРОИЗВОДИТЬСЯ"],
    ),
    (
        "код 2: стенд недоступен",
        2,
        report([execution("Health"), execution(KNOWN % 1, request_error=True)]),
        ["ПРОГОН НЕДЕЙСТВИТЕЛЕН"],
    ),
]


def main():
    failed = 0
    for title, expected, data, must_contain in CASES:
        code, output = run(data)
        ok = code == expected and all(s in output for s in must_contain)
        print("%-38s ожидаем %d, получено %d  %s"
              % (title, expected, code, "OK" if ok else "FAIL"))
        if not ok:
            failed += 1
            print("\n".join("    " + l for l in output.strip().split("\n")))

    # коллекция не должна влиять на подсчёт
    code, output = run(report([execution(KNOWN % 1)]), with_collection=False)
    ok = code == 0 and "Дефектов на месте: 1" in output
    print("%-38s ожидаем 0, получено %d  %s"
          % ("код 0: без файла коллекции", code, "OK" if ok else "FAIL"))
    if not ok:
        failed += 1

    print()
    if failed:
        print("FAIL: расходится %d подтестов из %d" % (failed, len(CASES) + 1))
        return 1
    print("OK: все %d подтестов прошли" % (len(CASES) + 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
