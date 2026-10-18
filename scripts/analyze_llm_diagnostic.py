#!/usr/bin/env python3
"""Preregistered metrics for the LLM diagnostic experiment.

Implements the measurement definitions in docs/llm_diagnostic_experiment.md
(section 4) and the analysis plan (section 8). Read-only with respect to the
forecasting pipeline: it consumes the three condition Parquet files and the
candidate crosswalk, and writes only processed/diagnostic/metrics.json.

Outputs markdown metric tables on stdout.
"""
from __future__ import annotations

import json
import math
import sys
from itertools import combinations
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from llm.prompts import derive_order_seed, order_candidates  # noqa: E402
from llm.runner import (  # noqa: E402
    load_candidates,
    load_personas,
    select_personas_stratified,
)

CONDITIONS = {
    "C0_ballot": (
        ROOT / "processed/diagnostic/c0_ballot_responses.parquet", "ballot", 20261026),
    "C1_randA": (
        ROOT / "processed/diagnostic/c1_random_a_responses.parquet", "random", 20261026),
    "C2_randB": (
        ROOT / "processed/diagnostic/c2_random_b_responses.parquet", "random", 7777777),
}
VALID_MODEL_STATUS = {"valid_choice", "undecided", "not_voting"}
PILOT = ROOT / "processed/llm_responses.parquet"
BOOTSTRAP_DRAWS = 10_000
BOOTSTRAP_SEED = 20261026


# ---------------------------------------------------------------- helpers
def wilson(k: int, n: int) -> tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    z = 1.959963984540054
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def entropy(counts: dict[str, int]) -> float:
    n = sum(counts.values())
    if n == 0:
        return float("nan")
    return -sum((c / n) * math.log(c / n) for c in counts.values() if c)


def hhi(counts: dict[str, int]) -> float:
    n = sum(counts.values())
    if n == 0:
        return float("nan")
    return sum((c / n) ** 2 for c in counts.values())


def jsd(p: dict[str, float], q: dict[str, float]) -> float:
    support = set(p) | set(q)
    def vec(d):
        tot = sum(d.values()) or 1.0
        return {s: d.get(s, 0.0) / tot for s in support}
    P, Q = vec(p), vec(q)
    M = {s: (P[s] + Q[s]) / 2 for s in support}
    def kl(a, b):
        return sum(a[s] * math.log(a[s] / b[s]) for s in support if a[s] > 0)
    return 0.5 * kl(P, M) + 0.5 * kl(Q, M)


def fisher_2x2(a: int, b: int, c: int, d: int) -> float:
    """Two-sided Fisher exact p-value for [[a, b], [c, d]]."""
    n = a + b + c + d
    r1, c1 = a + b, a + c
    def prob(x: int) -> float:
        return math.comb(c1, x) * math.comb(n - c1, r1 - x) / math.comb(n, r1)
    obs = prob(a)
    lo, hi = max(0, r1 - (n - c1)), min(r1, c1)
    p = sum(prob(x) for x in range(lo, hi + 1) if prob(x) <= obs * (1 + 1e-9))
    return min(1.0, p)


def avg_ranks(xs: list[float]) -> list[float]:
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        r = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = r
        i = j + 1
    return ranks


def spearman(xs: list[float], ys: list[float]) -> float:
    if len(set(xs)) == 1 or len(set(ys)) == 1:
        return float("nan")
    rx, ry = avg_ranks(xs), avg_ranks(ys)
    return float(np.corrcoef(rx, ry)[0, 1])


def fmt_ci(k: int, n: int) -> str:
    lo, hi = wilson(k, n)
    return f"{k}/{n} = {k / n:.3f} [{lo:.3f}, {hi:.3f}]"


# ---------------------------------------------------------------- load
cands = load_candidates(ROOT / "processed/simulated/candidate_crosswalk.parquet")
personas = load_personas(ROOT / "processed/simulated/simulated_personas.parquet")
selected = select_personas_stratified(personas, 12, seed=20261026)
sel_ids = {p.persona_id for p in selected}

data: dict[str, list[dict]] = {}
for cond, (path, mode, seed) in CONDITIONS.items():
    t = pq.read_table(path).to_pydict()
    rows = []
    for i in range(len(t["persona_id"])):
        race, model, rep = t["race_id"][i], t["model_id"][i], t["repeat_id"][i]
        ordered = list(cands[race])
        if mode == "random":
            ordered = order_candidates(
                cands[race], "random", derive_order_seed(seed, race, model, rep))
        rank = None
        if t["response_status"][i] == "valid_choice":
            rank = next(
                (k + 1 for k, c in enumerate(ordered)
                 if c.candidate_id == t["candidate_id"][i]), None)
        rows.append({
            "persona": t["persona_id"][i], "ward": t["ward"][i], "race": race,
            "model": model, "repeat": rep, "status": t["response_status"][i],
            "cand": t["candidate_id"][i], "rank": rank, "K": len(ordered),
            "from_cache": t["from_cache"][i],
            "in_tokens": t["input_tokens"][i], "out_tokens": t["output_tokens"][i],
        })
    data[cond] = rows


def split(rows):
    """-> (mayor rows, ward rows)."""
    return [r for r in rows if r["race"] == "mayor"], \
           [r for r in rows if r["race"] != "mayor"]


def counts_of(rows, model=None):
    c: dict[str, int] = {}
    for r in rows:
        if r["status"] != "valid_choice":
            continue
        if model and r["model"] != model:
            continue
        c[r["cand"]] = c.get(r["cand"], 0) + 1
    return c


MODELS = ["google/gemini-2.5-flash-lite", "openai/gpt-4o-mini"]
SHORT = {"google/gemini-2.5-flash-lite": "gemini-lite",
         "openai/gpt-4o-mini": "gpt-4o-mini"}

out: dict = {"validity": {}, "execution": {}, "concentration": {},
             "order": {}, "provider": {}, "repeats": {}, "demographics": {}}

# ---------------------------------------------------------------- validity gate
pilot = pq.read_table(PILOT).to_pydict()
pilot_map = {
    (pilot["persona_id"][i], pilot["race_id"][i], pilot["model_id"][i],
     pilot["repeat_id"][i]): (pilot["candidate_id"][i], pilot["response_status"][i])
    for i in range(len(pilot["persona_id"]))
}
v = {"checks": []}
all_rows = [r for rows in data.values() for r in rows]
v["checks"].append(("total rows (3 x 144)", len(all_rows) == 432, len(all_rows)))
v["checks"].append(("all personas in selected 12",
                    all(r["persona"] in sel_ids for r in all_rows), None))
v["checks"].append(("no null candidate_id on valid_choice",
                    all(r["cand"] for r in all_rows
                        if r["status"] == "valid_choice"), None))
v["checks"].append(("every candidate_id in its race list",
                    all(r["cand"] in {c.candidate_id for c in cands[r["race"]]}
                        for r in all_rows if r["cand"]), None))
v["checks"].append(("status vocabulary",
                    all(r["status"] in VALID_MODEL_STATUS for r in all_rows),
                    sorted({r["status"] for r in all_rows})))
v["checks"].append(("repeats are {1,2,3}",
                    {r["repeat"] for r in all_rows} == {1, 2, 3}, None))
# C0 cache hits must equal the pilot byte-for-byte on (persona, race, model, repeat)
c0_cached = [r for r in data["C0_ballot"] if r["from_cache"]]
mismatch = sum(
    1 for r in c0_cached
    if pilot_map.get((r["persona"], r["race"], r["model"], r["repeat"]))
    != (r["cand"], r["status"]))
v["checks"].append((f"{len(c0_cached)} C0 cache-hit rows identical to pilot",
                    mismatch == 0 and len(c0_cached) == 40, f"mismatches={mismatch}"))
out["validity"] = {"pass": all(ok for _, ok, _ in v["checks"]),
                   "checks": v["checks"]}

# ---------------------------------------------------------------- execution
exec_rows = []
for cond, rows in data.items():
    billed = 0.0  # actual is taken from the cost log below; recomputed from rows
    exec_rows.append({
        "condition": cond,
        "n": len(rows),
        "cache_hits": sum(r["from_cache"] for r in rows),
        "in_tokens": sum(r["in_tokens"] or 0 for r in rows),
        "out_tokens": sum(r["out_tokens"] or 0 for r in rows),
    })
# actual billed cost per condition from the cost log (API-reported only).
# The log is append-only and chronological: the pilot's 40 lines, then each
# condition's submitted requests in run order (C0, C1, C2). The `submitted`
# count per condition comes from its archived run summary, so the slice
# boundaries are taken from the runner's own records, not assumed.
cost_log = [json.loads(l) for l in
            (ROOT / "processed/llm/cost_log.jsonl").open()]
cond_cost, cond_submitted = {}, {}
offset = 40  # the pilot's first 40 lines precede all diagnostic runs
for cond in CONDITIONS:
    n_sub = json.load(open(
        ROOT / f"processed/diagnostic/{cond.split('_')[0]}_run_summary.json"
    ))["stats"]["submitted"]
    cond_submitted[cond] = n_sub
    slice_ = cost_log[offset:offset + n_sub]
    assert len(slice_) == n_sub, f"cost log too short for {cond}"
    assert all(e["cost_source"] == "api_reported" for e in slice_), \
        f"non-api_reported entry inside {cond} slice"
    cond_cost[cond] = sum(e["cost_usd_actual"] for e in slice_)
    offset += n_sub
assert offset == len(cost_log), \
    f"cost log length {len(cost_log)} != {offset} (pilot + diagnostic)"
for row in exec_rows:
    row["billed_usd"] = cond_cost[row["condition"]]
    row["submitted"] = cond_submitted[row["condition"]]
pilot_billed = sum(e["cost_usd_actual"] for e in cost_log[:40]
                   if e.get("cost_source") == "api_reported")
out["execution"] = {"rows": exec_rows,
                    "total_billed_usd": sum(cond_cost.values()),
                    "pilot_billed_usd": pilot_billed,
                    "cumulative_with_pilot_usd": sum(cond_cost.values()) + pilot_billed,
                    "budget_usd": 0.05}

# ---------------------------------------------------------------- concentration
K = {race: len(cl) for race, cl in cands.items()}
rng = np.random.default_rng(BOOTSTRAP_SEED)
conc = []
for cond, rows in data.items():
    mayor, ward = split(rows)
    for model in MODELS:
        mr = [r for r in mayor if r["model"] == model]
        cnt = counts_of(mr)
        n_valid = sum(cnt.values())
        H = entropy(cnt)
        lo, hi = wilson(max(cnt.values()), n_valid) if cnt else (0, 0)
        # bootstrap over personas (12 clusters, 3 repeats each)
        by_p: dict[str, list[dict]] = {}
        for r in mr:
            by_p.setdefault(r["persona"], []).append(r)
        pids = sorted(by_p)
        bH, bA = [], []
        for _ in range(BOOTSTRAP_DRAWS):
            pick = rng.choice(len(pids), size=len(pids), replace=True)
            sample = [r for i in pick for r in by_p[pids[i]]]
            c2 = counts_of(sample)
            if sum(c2.values()) >= 2:
                bH.append(entropy(c2))
            pairs = [(x["cand"], y["cand"]) for x, y in combinations(
                [r for r in sample if r["status"] == "valid_choice"], 2)]
            if pairs:
                bA.append(sum(1 for a, b in pairs if a == b) / len(pairs))
        allpairs = list(combinations(
            [r["cand"] for r in mr if r["status"] == "valid_choice"], 2))
        agree = (sum(1 for a, b in allpairs if a == b) / len(allpairs)
                 if allpairs else float("nan"))
        # ward races: 1 persona x 3 repeats per race/model -> mean across 12 races
        w_by_race: dict[str, list[dict]] = {}
        for r in ward:
            if r["model"] == model:
                w_by_race.setdefault(r["race"], []).append(r)
        wU = float(np.nanmean([len(counts_of(rr)) or np.nan
                                for rr in w_by_race.values()]))
        wH = float(np.nanmean([entropy(counts_of(rr)) for rr in w_by_race.values()]))
        w_valid = sum(1 for rr in w_by_race.values()
                      for r in rr if r["status"] == "valid_choice")
        w_tot = sum(len(rr) for rr in w_by_race.values())
        conc.append({
            "condition": cond, "model": SHORT[model],
            "mayor_n": len(mr), "mayor_valid": n_valid,
            "U": len(cnt), "top1": max(cnt.values()) / n_valid if cnt else float("nan"),
            "top1_id": max(cnt, key=cnt.get) if cnt else None,
            "top1_lo": lo, "top1_hi": hi,
            "H": H, "H_over_lnK": H / math.log(K["mayor"]),
            "eff_choices": math.exp(H) if cnt else float("nan"),
            "hhi": hhi(cnt), "hhi_eff": 1 / hhi(cnt) if cnt else float("nan"),
            "pairwise_agree": agree,
            "agree_ci": [float(x) for x in np.percentile(bA, [2.5, 97.5])] if bA else None,
            "H_ci": [float(x) for x in np.percentile(bH, [2.5, 97.5])],
            "ward_mean_U": float(wU), "ward_mean_H": float(wH),
            "ward_valid": w_valid, "ward_tot": w_tot,
        })
out["concentration"] = {"K_mayor": K["mayor"], "rows": conc,
                        "bootstrap": {"draws": BOOTSTRAP_DRAWS,
                                      "seed": BOOTSTRAP_SEED, "unit": "persona"}}

# ---------------------------------------------------------------- order sensitivity
order_out = []
for cond, (path, mode, seed) in CONDITIONS.items():
    rows = data[cond]
    for model in MODELS:
        mr = [r for r in rows if r["race"] == "mayor" and r["model"] == model
              and r["status"] == "valid_choice"]
        n = len(mr)
        top1 = sum(1 for r in mr if r["rank"] == 1)
        top3 = sum(1 for r in mr if r["rank"] <= 3)
        mean_rank = float(np.mean([r["rank"] for r in mr]))
        med_rank = float(np.median([r["rank"] for r in mr]))
        # per-candidate mean presented position vs selection count
        pos: dict[str, list[int]] = {}
        cnt = counts_of(mr)
        for r in rows:
            if r["race"] != "mayor" or r["model"] != model:
                continue
            ordered = list(cands["mayor"])
            if mode == "random":
                ordered = order_candidates(
                    cands["mayor"], "random", derive_order_seed(
                        seed, "mayor", model, r["repeat"]))
            for k, c in enumerate(ordered):
                pos.setdefault(c.candidate_id, []).append(k + 1)
        cand_ids = sorted(pos)
        rho = spearman([float(np.mean(pos[c])) for c in cand_ids],
                       [float(cnt.get(c, 0)) for c in cand_ids])
        order_out.append({
            "condition": cond, "model": SHORT[model], "n_valid": n,
            "first_capture": [top1, n], "first_null": f"1/{K['mayor']}",
            "top3_capture": [top3, n], "top3_null": f"3/{K['mayor']}",
            "mean_rank": mean_rank, "median_rank": med_rank,
            "rank_null": (K["mayor"] + 1) / 2,
            "spearman_pos_vs_freq": rho,
            "winner": max(cnt, key=cnt.get) if cnt else None,
            "winner_share": max(cnt.values()) / n if cnt else float("nan"),
        })

# cross-condition order-switch rates (matched cells, both valid)
switch = []
conds = list(CONDITIONS)
for a, b in [("C0_ballot", "C1_randA"), ("C0_ballot", "C2_randB"),
             ("C1_randA", "C2_randB")]:
    for label, pred in [("mayor", lambda r: r["race"] == "mayor"),
                        ("ward", lambda r: r["race"] != "mayor")]:
        same = diff = 0
        for ra in data[a]:
            if not pred(ra) or ra["status"] != "valid_choice":
                continue
            rb = next(r for r in data[b]
                       if r["persona"] == ra["persona"] and r["race"] == ra["race"]
                       and r["model"] == ra["model"] and r["repeat"] == ra["repeat"])
            if rb["status"] != "valid_choice":
                continue
            if ra["cand"] == rb["cand"]:
                same += 1
            else:
                diff += 1
        switch.append({"pair": f"{a} vs {b}", "race": label,
                       "same": same, "diff": diff,
                       "switch_rate": diff / (same + diff)})
# winner invariance: fraction of matched cells identical across ALL three conditions
inv = {"mayor": [0, 0], "ward": [0, 0]}
for r0 in data["C0_ballot"]:
    if r0["status"] != "valid_choice":
        continue
    r1 = next(r for r in data["C1_randA"] if r["persona"] == r0["persona"]
              and r["race"] == r0["race"] and r["model"] == r0["model"]
              and r["repeat"] == r0["repeat"])
    r2 = next(r for r in data["C2_randB"] if r["persona"] == r0["persona"]
              and r["race"] == r0["race"] and r["model"] == r0["model"]
              and r0["repeat"] == r["repeat"])
    if r1["status"] == r2["status"] == "valid_choice":
        key = "mayor" if r0["race"] == "mayor" else "ward"
        inv[key][1] += 1
        if r0["cand"] == r1["cand"] == r2["cand"]:
            inv[key][0] += 1
out["order"] = {"rows": order_out, "switch_rates": switch,
                "winner_invariant_all3": {
                    k: {"same": v[0], "n": v[1],
                        "rate": v[0] / v[1] if v[1] else float("nan")}
                    for k, v in inv.items()}}

# ---------------------------------------------------------------- provider
prov = []
for cond in CONDITIONS:
    rows = data[cond]
    stats_by = {}
    for model in MODELS:
        mr = [r for r in rows if r["model"] == model]
        und = sum(1 for r in mr if r["status"] == "undecided")
        val = sum(1 for r in mr if r["status"] == "valid_choice")
        stats_by[model] = (val, und, len(mr))
    (gv, gu, gn), (ov, ou, on) = stats_by[MODELS[0]], stats_by[MODELS[1]]
    # 2x2: rows = providers, cols = [valid_choice, undecided]
    table = [[gv, gu], [ov, ou]]
    # cross-provider agreement on matched (persona, race, repeat)
    agree_m = {"mayor": [0, 0], "ward": [0, 0]}
    for r in data[cond]:
        if r["model"] != MODELS[0] or r["status"] != "valid_choice":
            continue
        o = next(x for x in data[cond] if x["model"] == MODELS[1]
                 and x["persona"] == r["persona"] and x["race"] == r["race"]
                 and x["repeat"] == r["repeat"])
        if o["status"] != "valid_choice":
            continue
        key = "mayor" if r["race"] == "mayor" else "ward"
        agree_m[key][1] += 1
        agree_m[key][0] += r["cand"] == o["cand"]
    prov.append({
        "condition": cond,
        "gemini_undecided": fmt_ci(gu, gn), "gpt_undecided": fmt_ci(ou, on),
        "fisher_valid_vs_undecided": fisher_2x2(gv, gu, ov, ou),
        "cross_provider_agree": {
            k: {"same": v[0], "n": v[1],
                "rate": v[0] / v[1] if v[1] else float("nan")}
            for k, v in agree_m.items()},
    })
out["provider"] = {"rows": prov}

# ---------------------------------------------------------------- repeats
rep = []
for cond in CONDITIONS:
    rows = data[cond]
    for model in MODELS:
        for label, pred in [("mayor", lambda r: r["race"] == "mayor"),
                            ("ward", lambda r: r["race"] != "mayor")]:
            agree = cflip = sflip = 0
            cells = {}
            for r in rows:
                if r["model"] == model and pred(r):
                    cells.setdefault(
                        (r["persona"], r["race"]), {})[r["repeat"]] = r
            for cell in cells.values():
                for a, b in combinations(sorted(cell), 2):
                    x, y = cell[a], cell[b]
                    if x["status"] == y["status"] == "valid_choice":
                        agree += x["cand"] == y["cand"]
                        cflip += x["cand"] != y["cand"]
                    elif x["status"] == y["status"]:
                        agree += 1  # both undecided / both not_voting
                    else:
                        sflip += 1
            tot = agree + cflip + sflip
            rep.append({
                "condition": cond, "model": SHORT[model], "race": label,
                "pairs": tot, "agree": agree, "choice_flips": cflip,
                "status_flips": sflip,
                "agree_rate": agree / tot if tot else float("nan"),
                "agree_ci": [float(x) for x in wilson(agree, tot)]})
out["repeats"] = {"rows": rep}

# ---------------------------------------------------------------- demographics
demo = []
for cond in CONDITIONS:
    for model in MODELS:
        mayor = [r for r in data[cond] if r["race"] == "mayor"
                 and r["model"] == model]
        pooled = counts_of(mayor)
        for attr, groups in [
                ("age", ["20-29", "30-44", "45-64", "65+"]),
                ("education", ["High school or less",
                               "Postsecondary below bachelor's",
                               "Bachelor's degree or higher"])]:
            pmap = {p.persona_id: (getattr(p, "age_group") if attr == "age"
                                   else getattr(p, "education_group"))
                    for p in selected}
            for g in groups:
                sub = [r for r in mayor if pmap[r["persona"]] == g]
                cnt = counts_of(sub)
                n_valid = sum(cnt.values())
                und = sum(1 for r in sub if r["status"] == "undecided")
                demo.append({
                    "condition": cond, "model": SHORT[model], "attr": attr,
                    "group": g, "personas": len({r["persona"] for r in sub}),
                    "n": len(sub), "valid": n_valid, "undecided": und,
                    "U": len(cnt),
                    "top1_share": max(cnt.values()) / n_valid if cnt else float("nan"),
                    "H": entropy(cnt),
                    "jsd_vs_pooled": jsd(cnt, pooled) if cnt else float("nan"),
                })
out["demographics"] = {"rows": demo}

# ward-race choices are not poolable across wards (different candidate lists),
# but undecided STATUS is comparable across demographics
ward_status = []
for cond in CONDITIONS:
    for model in MODELS:
        ward = [r for r in data[cond] if r["race"] != "mayor" and r["model"] == model]
        for attr, groups in [
                ("age", ["20-29", "30-44", "45-64", "65+"]),
                ("education", ["High school or less",
                               "Postsecondary below bachelor's",
                               "Bachelor's degree or higher"])]:
            pmap = {p.persona_id: (p.age_group if attr == "age"
                                   else p.education_group)
                    for p in selected}
            for g in groups:
                sub = [r for r in ward if pmap[r["persona"]] == g]
                und = sum(1 for r in sub if r["status"] == "undecided")
                ward_status.append({
                    "condition": cond, "model": SHORT[model], "attr": attr,
                    "group": g, "n": len(sub), "undecided": und,
                    "undec_rate": und / len(sub) if sub else float("nan")})
out["demographics"]["ward_status_rows"] = ward_status

# ---------------------------------------------------------------- emit
(ROOT / "processed/diagnostic/metrics.json").write_text(json.dumps(out, indent=2))

def md_table(headers, rows):
    yield "| " + " | ".join(headers) + " |"
    yield "|" + "|".join("---" for _ in headers) + "|"
    for r in rows:
        yield "| " + " | ".join(str(x) for x in r) + " |"

print("## Validity gate")
for name, ok, extra in v["checks"]:
    print(f"- {'PASS' if ok else 'FAIL'}: {name}" + (f" ({extra})" if extra else ""))
print("\n## Execution")
print("\n".join(md_table(
    ["condition", "rows", "HTTP submitted", "cache hits", "in tok", "out tok",
     "actual billed"],
    [[r["condition"], r["n"], r["submitted"], r["cache_hits"],
      f"{r['in_tokens']:,}", f"{r['out_tokens']:,}",
      f"${r['billed_usd']:.7f}"] for r in exec_rows])))
print(f"\n- diagnostic total actual billed: ${out['execution']['total_billed_usd']:.7f}")
print(f"- pilot actual billed:            ${pilot_billed:.7f}")
print(f"- cumulative (pilot + diagnostic): ${out['execution']['cumulative_with_pilot_usd']:.7f}"
      f" of ${out['execution']['budget_usd']:.2f} budget")
print("\n## Concentration (mayor; ward aggregated)")
print("\n".join(md_table(
    ["cond", "model", "valid", "U", "top-1 (Wilson CI)", "winner",
     "H", "H/lnK", "exp(H)", "1/HHI", "pairwise agr (boot CI)",
     "ward mean U", "ward mean H", "ward valid"],
    [[c["condition"], c["model"], c["mayor_valid"], c["U"],
      f"{c['top1']:.3f} [{c['top1_lo']:.3f},{c['top1_hi']:.3f}]",
      c["top1_id"], f"{c['H']:.3f}", f"{c['H_over_lnK']:.3f}",
      f"{c['eff_choices']:.2f}", f"{c['hhi_eff']:.2f}",
      f"{c['pairwise_agree']:.3f} "
      f"[{c['agree_ci'][0]:.3f},{c['agree_ci'][1]:.3f}]",
      f"{c['ward_mean_U']:.2f}", f"{c['ward_mean_H']:.3f}",
      f"{c['ward_valid']}/{c['ward_tot']}"] for c in conc])))
print("\n## Order sensitivity (mayor)")
print("\n".join(md_table(
    ["cond", "model", "valid", "rank-1 capture", "top-3 capture",
     "mean rank (null)", "median", "Spearman pos~freq", "winner share"],
    [[r["condition"], r["model"], r["n_valid"],
      f"{r['first_capture'][0]}/{r['first_capture'][1]} (≈{1 / 53:.3f} null)",
      f"{r['top3_capture'][0]}/{r['top3_capture'][1]} (≈{3 / 53:.3f} null)",
      f"{r['mean_rank']:.1f} ({r['rank_null']:.1f})", f"{r['median_rank']:.0f}",
      f"{r['spearman_pos_vs_freq']:+.3f}", f"{r['winner_share']:.3f}"]
     for r in order_out])))
print("\n### Cross-condition switch rates & winner invariance")
print("\n".join(md_table(
    ["condition pair", "race", "same", "diff", "switch rate"],
    [[s["pair"], s["race"], s["same"], s["diff"], f"{s['switch_rate']:.3f}"]
     for s in switch])))
for k, d in out["order"]["winner_invariant_all3"].items():
    print(f"- winner invariant across all 3 conditions ({k}): "
          f"{d['same']}/{d['n']} = {d['rate']:.3f}")
print("\n## Provider differences")
print("\n".join(md_table(
    ["cond", "gemini undecided (Wilson)", "gpt undecided (Wilson)",
     "Fisher p (valid vs undec)", "cross-provider agree mayor", "ward"],
    [[p["condition"], p["gemini_undecided"], p["gpt_undecided"],
      f"{p['fisher_valid_vs_undecided']:.4f}",
      f"{p['cross_provider_agree']['mayor']['rate']:.3f} "
      f"({p['cross_provider_agree']['mayor']['same']}/"
      f"{p['cross_provider_agree']['mayor']['n']})",
      f"{p['cross_provider_agree']['ward']['rate']:.3f} "
      f"({p['cross_provider_agree']['ward']['same']}/"
      f"{p['cross_provider_agree']['ward']['n']})"] for p in prov])))
print("\n## Repeat disagreement (3 pairs per cell)")
print("\n".join(md_table(
    ["cond", "model", "race", "pairs", "agree", "choice flips",
     "status flips", "agree rate (Wilson)"],
    [[r["condition"], r["model"], r["race"], r["pairs"], r["agree"],
      r["choice_flips"], r["status_flips"],
      f"{r['agree_rate']:.3f} [{r['agree_ci'][0]:.3f},{r['agree_ci'][1]:.3f}]"]
     for r in rep])))
print("\n## Demographic marginals (mayor)")
print("\n".join(md_table(
    ["cond", "model", "attr", "group", "personas", "valid/total",
     "undec", "U", "top-1", "H", "JSD vs pooled"],
    [[d["condition"], d["model"], d["attr"], d["group"], d["personas"],
      f"{d['valid']}/{d['n']}", d["undecided"], d["U"],
      f"{d['top1_share']:.3f}", f"{d['H']:.3f}", f"{d['jsd_vs_pooled']:.4f}"]
     for d in demo])))
print("\n## Ward-race undecided rate by demographic group")
print("\n".join(md_table(
    ["cond", "model", "attr", "group", "undec/total", "rate"],
    [[d["condition"], d["model"], d["attr"], d["group"],
      f"{d['undecided']}/{d['n']}", f"{d['undec_rate']:.3f}"]
     for d in ward_status])))
print("\nmetrics.json ->", ROOT / "processed/diagnostic/metrics.json")
