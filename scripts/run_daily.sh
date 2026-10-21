#!/usr/bin/env bash
# scripts/run_daily.sh
#
# One day of the daily tracker: news -> LLM poll -> post-stratification.
# Used by .github/workflows/daily-forecast.yml; also runs locally:
#
#   OPENROUTER_API_KEY=sk-or-... scripts/run_daily.sh
#
# Environment (all optional):
#   POLL_DATE                 YYYY-MM-DD; default = today in Toronto
#   POLL_END_DATE             last day to poll (default 2026-10-26, election day)
#   DAILY_BUDGET_USD          hard spend cap for the day, split across models (default 1.50)
#   DAILY_PERSONAS_PER_CELL   panel size per census cell (default 4 -> 1,200 personas)
#   FORCE_POLL                "true" re-polls a date that already has responses
#   PYTHON                    python interpreter (default python3)
#   WORK_DIR                  scratch space for cache/raw requests (default: mktemp)

set -euo pipefail
cd "$(dirname "$0")/.."

POLL_DATE="${POLL_DATE:-$(TZ=America/Toronto date +%F)}"
POLL_END_DATE="${POLL_END_DATE:-2026-10-26}"
DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-1.50}"
PER_CELL="${DAILY_PERSONAS_PER_CELL:-4}"
FORCE_POLL="${FORCE_POLL:-false}"
PY="${PYTHON:-python3}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

DAILY=processed/daily
CONFIG=llm/models.daily.json
NEWS="$DAILY/news/$POLL_DATE.json"
RESP_DIR="$DAILY/responses/$POLL_DATE"

log() { echo "[run_daily $POLL_DATE] $*"; }

if [[ "$POLL_DATE" > "$POLL_END_DATE" ]]; then
  log "after POLL_END_DATE ($POLL_END_DATE); nothing to poll"
  exit 0
fi
if [[ -d "$RESP_DIR" && "$FORCE_POLL" != "true" ]]; then
  log "already polled ($RESP_DIR exists); set FORCE_POLL=true to re-poll"
  exit 0
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  log "OPENROUTER_API_KEY is not set" >&2
  exit 2
fi

Rscript R/11_daily_panel.R "$PER_CELL"

# The news snapshot lives in WORK_DIR next to the response cache, so a
# resumed run (same WORK_DIR) rebuilds identical prompts and hits the cache.
WORK_NEWS="$WORK_DIR/news-$POLL_DATE.json"
if [[ -f "$WORK_NEWS" ]]; then
  log "reusing news snapshot $WORK_NEWS"
else
  set +e
  "$PY" -m llm.news --date "$POLL_DATE" --out "$WORK_NEWS"
  rc=$?
  set -e
  if [[ $rc -eq 3 ]]; then
    mkdir -p "$(dirname "$NEWS")"
    cp "$WORK_NEWS" "$NEWS"
    # Not kept in WORK_DIR, otherwise the cached copy would be reused by a later run.
    rm -f "$WORK_NEWS"
    log "news block unusable today; skipping the poll (news file kept for audit)"
    exit 0
  elif [[ $rc -ne 0 ]]; then
    exit $rc
  fi
fi
mkdir -p "$(dirname "$NEWS")"
cp "$WORK_NEWS" "$NEWS"

MODELS=()
while IFS= read -r m; do MODELS+=("$m"); done < <(
  "$PY" -c "import json; [print(m['model_id']) for m in json.load(open('$CONFIG'))['models']]"
)
PER_MODEL_BUDGET=$("$PY" -c "print(round($DAILY_BUDGET_USD / ${#MODELS[@]}, 4))")
log "${#MODELS[@]} models, \$$PER_MODEL_BUDGET budget each, work dir $WORK_DIR"

mkdir -p "$WORK_DIR/out" "$DAILY/runs/$POLL_DATE"
pids=()
for model in "${MODELS[@]}"; do
  slug="${model%%/*}"
  "$PY" -m llm.runner run \
    --config "$CONFIG" --models "$model" \
    --personas "$DAILY/panel_personas.parquet" \
    --repeats 1 --order random \
    --news "$NEWS" \
    --budget-usd "$PER_MODEL_BUDGET" \
    --out "$WORK_DIR/out/$slug.parquet" \
    --cache-dir "$WORK_DIR/cache/$slug" \
    --raw-dir "$WORK_DIR/raw/$slug" \
    --cost-log "$WORK_DIR/cost/$POLL_DATE-$slug.jsonl" \
    --summary "$DAILY/runs/$POLL_DATE/$slug.json" \
    > "$WORK_DIR/$slug.log" 2>&1 &
  pids+=("$!")
done

status=0
for i in "${!pids[@]}"; do
  slug="${MODELS[$i]%%/*}"
  if ! wait "${pids[$i]}"; then
    log "runner for ${MODELS[$i]} failed" >&2
    status=1
  fi
  tail -n 25 "$WORK_DIR/$slug.log"
done
[[ $status -eq 0 ]] || exit $status

rm -rf "$RESP_DIR"
mkdir -p "$RESP_DIR"
cp "$WORK_DIR"/out/*.parquet "$RESP_DIR/"

Rscript R/12_daily_forecast.R "$POLL_DATE"
log "done"
