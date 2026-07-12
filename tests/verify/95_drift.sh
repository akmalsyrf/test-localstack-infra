section "Terraform drift (plan -detailed-exitcode)"

DRIFT_OUT="/tmp/verify-drift-${ENV}.txt"
set +e
"$ROOT/scripts/check-drift.sh" "$ENV" | tee "$DRIFT_OUT"
DRIFT_RC=${PIPESTATUS[0]}
set -e
# Merge PASS/FAIL lines into this run's counters (check-drift prints the same format).
DRIFT_PASS="$(grep -c '^  PASS  ' "$DRIFT_OUT" 2>/dev/null || true)"
DRIFT_FAIL="$(grep -c '^  FAIL  ' "$DRIFT_OUT" 2>/dev/null || true)"
PASS=$((PASS + ${DRIFT_PASS:-0}))
FAIL=$((FAIL + ${DRIFT_FAIL:-0}))
if [[ "$DRIFT_RC" -ne 0 && "${DRIFT_FAIL:-0}" -eq 0 ]]; then
  fail "check-drift.sh exited $DRIFT_RC without FAIL lines"
fi
