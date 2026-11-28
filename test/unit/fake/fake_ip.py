#!/usr/bin/env python3
"""Stateful stand-in for the iproute2 commands used by unit tests.

State lives in $FAKE_IP_STATE. Every mutation is appended to $FAKE_IP_LOG.
Failure injection:
  FAKE_IP_FAIL_AT=N  fail the Nth mutation before applying it (rc 2)
  FAKE_IP_KILL_AT=N  apply the Nth mutation, then SIGKILL the calling process
"""
import ipaddress
import json
import os
import signal
import sys
import tempfile

STATE = os.environ["FAKE_IP_STATE"]
LOG = os.environ.get("FAKE_IP_LOG", "")
COUNT = os.environ.get("FAKE_IP_COUNT", "")


def load():
    with open(STATE) as fh:
        return json.load(fh)


def save(state):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATE))
    with os.fdopen(fd, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE)


def log(argv):
    if not LOG:
        return
    with open(LOG, "a") as fh:
        fh.write(json.dumps(argv) + "\n")


def fail(msg, rc=2):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def read_count():
    if not COUNT or not os.path.exists(COUNT):
        return 0
    try:
        return int(open(COUNT).read().strip() or "0")
    except ValueError:
        return 0


def bump_mutation():
    n = read_count() + 1
    if COUNT:
        with open(COUNT, "w") as fh:
            fh.write(str(n))
    return n


def mutate_gate():
    n = bump_mutation()
    fail_at = int(os.environ.get("FAKE_IP_FAIL_AT", "0") or "0")
    if fail_at and n == fail_at:
        fail("RTNETLINK answers: injected failure")
    return n


def kill_gate(n):
    kill_at = int(os.environ.get("FAKE_IP_KILL_AT", "0") or "0")
    if kill_at and n == kill_at:
        os.kill(os.getppid(), signal.SIGKILL)


def render_route(r):
    typ = r.get("type", "unicast")
    parts = []
    if typ in ("unreachable", "blackhole", "prohibit"):
        parts.extend([typ, r["prefix"]])
    else:
        parts.append(r["prefix"])
        if r.get("via"):
            parts.extend(["via", r["via"]])
        if r.get("dev"):
            parts.extend(["dev", r["dev"]])
    parts.extend(["proto", str(r.get("proto", 0)), "metric", str(r.get("metric", 0))])
    return " ".join(parts)


def render_rule(r):
    if r["action"] == "lookup":
        return f'{r["pref"]}: from {r["from"]} lookup {r["table"]}'
    return f'{r["pref"]}: from {r["from"]} {r["action"]}'


def parse_route(args):
    r = {"type": "unicast", "metric": 1024, "proto": 0}
    i = 0
    if args[i] in ("unreachable", "blackhole", "prohibit", "unicast"):
        r["type"] = args[i]
        i += 1
    r["prefix"] = args[i]
    i += 1
    while i < len(args):
        a = args[i]
        if a in ("via", "dev", "table", "metric", "proto"):
            r[a] = args[i + 1]
            i += 2
        else:
            i += 1
    for key in ("metric", "proto"):
        if key in r:
            r[key] = int(r[key])
    return r


def route_match(r, q):
    for key in ("prefix", "type"):
        if r.get(key) != q.get(key):
            return False
    for key in ("table", "metric", "proto"):
        if key in q and r.get(key) != q.get(key):
            return False
    return True


def from_matches(rule_from, src):
    if rule_from == "all":
        return True
    try:
        net = ipaddress.ip_network(rule_from, strict=False)
        addr = ipaddress.ip_address(src)
        return addr in net
    except ValueError:
        return False


def lookup_table(state, table, dst):
    routes = state["tables"].get(str(table))
    if routes is None:
        return None
    best = None
    try:
        dst_addr = ipaddress.ip_address(dst)
    except ValueError:
        return None
    for r in routes:
        if r.get("type") not in ("unicast", None):
            continue
        try:
            net = ipaddress.ip_network(r["prefix"], strict=False)
        except ValueError:
            continue
        if dst_addr in net:
            if best is None or net.prefixlen > best[0]:
                best = (net.prefixlen, r)
    return best[1] if best else None


def main():
    argv = sys.argv[1:]
    log(argv)
    if argv[:3] == ["-j", "-d", "link"]:
        print(json.dumps(load()["links"]))
        return
    if argv[:1] != ["-6"]:
        fail("fake_ip: unsupported invocation", 2)
    argv = argv[1:]
    state = load()

    if argv[:2] == ["rule", "show"]:
        for r in sorted(state["rules"], key=lambda x: (x["pref"], x["from"])):
            print(render_rule(r))
        return

    if argv[:2] == ["rule", "add"]:
        rest = argv[2:]
        if not rest or rest[0] != "from":
            fail("fake_ip: bad rule add")
        rule = {"from": rest[1], "pref": 0}
        i = 2
        if rest[i] == "lookup":
            rule.update(action="lookup", table=rest[i + 1])
            i += 2
        else:
            rule["action"] = rest[i]
            i += 1
        if i < len(rest) and rest[i] == "pref":
            rule["pref"] = int(rest[i + 1])
        key = (rule["pref"], rule["from"], rule["action"], rule.get("table"))
        for r in state["rules"]:
            if (r["pref"], r["from"], r["action"], r.get("table")) == key:
                fail("RTNETLINK answers: File exists")
        n = mutate_gate()
        state["rules"].append(rule)
        save(state)
        kill_gate(n)
        return

    if argv[:2] == ["rule", "del"]:
        rest = argv[2:]
        rule = {"from": rest[1], "pref": 0}
        i = 2
        if rest[i] == "lookup":
            rule.update(action="lookup", table=rest[i + 1])
            i += 2
        else:
            rule["action"] = rest[i]
            i += 1
        if i < len(rest) and rest[i] == "pref":
            rule["pref"] = int(rest[i + 1])
        for idx, r in enumerate(state["rules"]):
            if (r["pref"], r["from"], r["action"], r.get("table")) == (
                rule["pref"], rule["from"], rule["action"], rule.get("table")
            ):
                n = mutate_gate()
                state["rules"].pop(idx)
                save(state)
                kill_gate(n)
                return
        fail("RTNETLINK answers: No such file or directory")
        return

    if argv[:2] == ["route", "show"]:
        rest = argv[2:]
        table = "main"
        exact = None
        i = 0
        while i < len(rest):
            if rest[i] == "table":
                table = rest[i + 1]
                i += 2
            elif rest[i] == "exact":
                exact = rest[i + 1]
                i += 2
            else:
                i += 1
        if table not in state["tables"]:
            fail("Error: ipv6: FIB table does not exist.\nDump terminated")
        routes = state["tables"][table]
        if exact is not None:
            routes = [r for r in routes if r["prefix"] == exact]
        for r in routes:
            print(render_route(r))
        return

    if argv[:2] == ["route", "replace"]:
        q = parse_route(argv[2:])
        table = q.pop("table", "main")
        n = mutate_gate()
        state["tables"].setdefault(str(table), [])
        routes = state["tables"][str(table)]
        for idx, r in enumerate(routes):
            if route_match(r, q):
                q["table"] = str(table)
                routes[idx] = q
                save(state)
                kill_gate(n)
                return
        q["table"] = str(table)
        routes.append(q)
        save(state)
        kill_gate(n)
        return

    if argv[:2] == ["route", "del"]:
        q = parse_route(argv[2:])
        table = q.pop("table", "main")
        routes = state["tables"].get(str(table))
        if routes is None:
            fail("Error: ipv6: FIB table does not exist.\nDump terminated")
        for idx, r in enumerate(routes):
            if route_match(r, q):
                n = mutate_gate()
                routes.pop(idx)
                save(state)
                kill_gate(n)
                return
        fail("RTNETLINK answers: No such process")

    if argv[:2] == ["route", "get"]:
        rest = argv[2:]
        dst = rest[0]
        src = None
        i = 1
        while i < len(rest):
            if rest[i] == "from" and i + 1 < len(rest):
                src = rest[i + 1]
                i += 2
            else:
                i += 1
        if src is None:
            fail("fake_ip: route get requires from")
        selected = None
        selected_table = "main"
        for r in sorted(state["rules"], key=lambda x: x["pref"]):
            if not from_matches(r["from"], src):
                continue
            if r["action"] == "lookup":
                selected = lookup_table(state, r["table"], dst)
                selected_table = str(r["table"])
                if selected:
                    break
                continue
            if r["action"] in ("unreachable", "blackhole", "prohibit"):
                fail("RTNETLINK answers: Network is unreachable")
        if selected is None:
            selected = lookup_table(state, "main", dst)
            selected_table = "main"
        if selected is None:
            fail("RTNETLINK answers: Network is unreachable")
        parts = [dst, "from", src]
        if selected.get("via"):
            parts.extend(["via", selected["via"]])
        if selected.get("dev"):
            parts.extend(["dev", selected["dev"]])
        parts.extend(["table", selected_table])
        print(" ".join(parts))
        return

    fail("fake_ip: unsupported invocation: " + " ".join(argv), 2)


main()
