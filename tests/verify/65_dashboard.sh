section "CloudWatch ops dashboard"

# DASHBOARD_NAME / DASHBOARD_URL already required in 20_outputs.sh

DASH_JSON="$(aws_ls cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" --output json 2>/dev/null || echo '{}')"
if echo "$DASH_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
body_raw=d.get("DashboardBody") or "{}"
try:
  body=json.loads(body_raw) if isinstance(body_raw, str) else body_raw
except Exception:
  sys.exit(2)
widgets=body.get("widgets") or []
if len(widgets) < 4:
  sys.exit(3)
titles=" ".join(str((w.get("properties") or {}).get("title","")) for w in widgets).lower()
need=("ec2","lambda","sqs","api gateway")
sys.exit(0 if all(n in titles for n in need) else 4)
'; then
  ok "CloudWatch dashboard $DASHBOARD_NAME has EC2/Lambda/SQS/API Gateway widgets"
else
  rc=$?
  case "$rc" in
    2) fail "CloudWatch dashboard body is not valid JSON" ;;
    3) fail "CloudWatch dashboard has fewer than 4 widgets" ;;
    4) fail "CloudWatch dashboard missing expected EC2/Lambda/SQS/API Gateway widgets" ;;
    *) fail "CloudWatch dashboard missing or get-dashboard failed ($DASHBOARD_NAME)" ;;
  esac
fi

if [[ "$DASHBOARD_URL" == *"console.aws.amazon.com/cloudwatch"* && "$DASHBOARD_URL" == *"$DASHBOARD_NAME"* ]]; then
  ok "dashboard_url is a CloudWatch console deep-link for $DASHBOARD_NAME"
else
  fail "dashboard_url unexpected: ${DASHBOARD_URL:-empty}"
fi
