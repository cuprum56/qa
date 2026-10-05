#!/usr/bin/env python3
"""Разбор JSON-отчёта Newman. usage: summarize.py <report.json> [collection.json]

Сценарии [KNOWN BUG] фиксируют текущее ошибочное поведение, поэтому их провал -
это не регрессия, а признак того, что дефект исправлен.

Код выхода: 0 - регрессий нет, 1 - регрессии, 2 - стенд недоступен,
3 - регрессий нет, но какой-то дефект перестал воспроизводиться.
"""
import io
import json
import sys

KNOWN_PREFIX = "[KNOWN BUG]"


def load_locations(collection_path):
    # имя папки в отчёте не сохраняется, поэтому подпись собираем из коллекции
    empty = ({}, {})
    if not collection_path:
        return empty
    with io.open(collection_path, encoding="utf-8") as fh:
        col = json.load(fh)

    by_id, by_name = {}, {}
    for folder in col.get("item", []):
        for request in folder.get("item", []):
            name = request.get("name", "?")
            label = "%s / %s" % (folder.get("name", "?"), name)
            if request.get("id"):
                by_id[request["id"]] = label
            by_name[name] = label
    return by_id, by_name


def message(assertion):
    err = assertion.get("error")
    if isinstance(err, dict):
        return err.get("message") or err.get("name") or str(err)
    return str(err) if err else ""


def main(report_path, collection_path=None):
    with io.open(report_path, encoding="utf-8") as fh:
        report = json.load(fh)

    by_id, by_name = load_locations(collection_path)
    run = report.get("run", {})
    stats = run.get("stats", {})
    executions = run.get("executions", [])

    def label(ex):
        item = ex.get("item", {})
        if item.get("id") in by_id:
            return by_id[item["id"]]
        return by_name.get(item.get("name"), item.get("name", "?"))

    network, fixed, regressions = [], [], []
    known_passed = 0

    for ex in executions:
        name = ex.get("item", {}).get("name", "")
        is_known = name.startswith(KNOWN_PREFIX)
        if ex.get("requestError"):
            network.append((label(ex), ex["requestError"]))
            continue
        bad = [a for a in ex.get("assertions", [])
               if a.get("error") and not a.get("skipped")]
        if not bad:
            if is_known:
                known_passed += 1
            continue
        if is_known:
            fixed.append((label(ex), bad))
        else:
            regressions.append((label(ex), bad))

    total_asserts = stats.get("assertions", {}).get("total", 0)
    failed_asserts = stats.get("assertions", {}).get("failed", 0)
    fixed_count = sum(len(b) for _, b in fixed)
    regression_count = sum(len(b) for _, b in regressions)

    print("=" * 70)
    print("СВОДКА ПРОГОНА")
    print("=" * 70)
    print("Запросов выполнено:        %d" % len(executions))
    print("Проверок выполнено:        %d" % total_asserts)
    print("Проверок провалено:        %d" % failed_asserts)
    print("  дефектов воспроизведено: %d  (%d запросов [%s] прошли - дефект на месте)"
          % (known_passed, known_passed, KNOWN_PREFIX.strip("[]")))
    print("  регрессии:               %d" % regression_count)
    print("  сетевых ошибок:          %d" % len(network))

    if network:
        print("\n" + "!" * 70)
        print("ПРОГОН НЕДЕЙСТВИТЕЛЕН: %d запросов не дошли до стенда" % len(network))
        print("!" * 70)
        first = network[0][1]
        code = first.get("code", "") if isinstance(first, dict) else first
        print("  Первая ошибка: %s (%s)" % (network[0][0], code))
        print("  Проверьте, что стенд поднят: ./stand/up.sh")
        return 2

    if fixed:
        print("\nДЕФЕКТ ПЕРЕСТАЛ ВОСПРОИЗВОДИТЬСЯ (%d) - перевести в позитивные тесты:" % len(fixed))
        for name, bad in fixed:
            print("  * %s" % name)
            print("      %s" % message(bad[0]).split("\n")[0][:88])
        print()
        print("  Сценарий ждал ошибочного ответа - значит дефект исправлен.")

    if regressions:
        print("\nРЕГРЕССИИ - требуют разбора (%d):" % len(regressions))
        for name, bad in regressions:
            for assertion in bad:
                print("  ! %s" % name)
                print("      %s" % message(assertion).split("\n")[0][:88])
        return 1

    if not fixed:
        print("\nРегрессий нет. Дефектов на месте: %d" % known_passed)
        return 0
    return 3


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
