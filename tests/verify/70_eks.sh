section "EKS mirror (IAM on LocalStack) + Kind"

if [[ "$EKS_CLUSTER_STATUS" == "ACTIVE" ]]; then
  ok "mirrored EKS cluster status=ACTIVE"
else
  fail "mirrored EKS cluster status unexpected ($EKS_CLUSTER_STATUS)"
fi

if [[ "$EKS_CLUSTER_ARN" == "arn:aws:eks:${REGION}:000000000000:cluster/${EKS_CLUSTER_NAME}" ]]; then
  ok "mirrored EKS cluster ARN shape"
else
  fail "mirrored EKS cluster ARN unexpected ($EKS_CLUSTER_ARN)"
fi

CLUSTER_ROLE_NAME="${EXPECT_PREFIX}-eks-cluster"
NODE_ROLE_NAME="${EXPECT_PREFIX}-eks-node"
if aws_ls iam get-role --role-name "$CLUSTER_ROLE_NAME" >/dev/null 2>&1; then
  ok "EKS cluster IAM role exists ($CLUSTER_ROLE_NAME)"
else
  fail "EKS cluster IAM role missing ($CLUSTER_ROLE_NAME)"
fi
if aws_ls iam get-role --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1; then
  ok "EKS node IAM role exists ($NODE_ROLE_NAME)"
else
  fail "EKS node IAM role missing ($NODE_ROLE_NAME)"
fi

CLUSTER_TRUST="$(aws_ls iam get-role --role-name "$CLUSTER_ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo '{}')"
if echo "$CLUSTER_TRUST" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
if isinstance(doc, str):
  doc=json.loads(doc)
ok=False
for s in doc.get("Statement") or []:
  svc=(s.get("Principal") or {}).get("Service")
  if svc=="eks.amazonaws.com" or (isinstance(svc,list) and "eks.amazonaws.com" in svc):
    ok=True
sys.exit(0 if ok else 1)
'; then
  ok "cluster role trusts eks.amazonaws.com"
else
  fail "cluster role trust policy missing eks.amazonaws.com"
fi

if [[ "$EKS_NODE_GROUP" == "${EXPECT_PREFIX}-ng" ]]; then
  ok "mirrored node group name ($EKS_NODE_GROUP)"
else
  fail "mirrored node group name unexpected ($EKS_NODE_GROUP)"
fi

if command -v kind >/dev/null 2>&1 || [[ -x "$ROOT/bin/kind" ]]; then
  KIND_BIN="$(command -v kind 2>/dev/null || true)"
  [[ -z "$KIND_BIN" && -x "$ROOT/bin/kind" ]] && KIND_BIN="$ROOT/bin/kind"
  if "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    ok "Kind cluster exists ($KIND_CLUSTER_NAME)"
  else
    fail "Kind cluster missing ($KIND_CLUSTER_NAME)"
  fi
else
  fail "kind binary not found"
fi

if [[ -f "$KIND_KUBECONFIG" ]] && command -v kubectl >/dev/null 2>&1; then
  if kubectl --kubeconfig "$KIND_KUBECONFIG" get nodes --no-headers 2>/dev/null \
    | awk '$2 == "Ready" { ok=1 } END { exit ok ? 0 : 1 }'; then
    ok "Kind nodes are Ready"
  else
    fail "Kind nodes not Ready"
    kubectl --kubeconfig "$KIND_KUBECONFIG" get nodes -o wide >&2 || true
  fi

  WORKER_NODES="$(kubectl --kubeconfig "$KIND_KUBECONFIG" get nodes \
    -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${WORKER_NODES:-0}" -ge 2 ]]; then
    ok "Kind has >=2 worker nodes (got $WORKER_NODES)"
  else
    fail "Kind worker count expected >=2, got ${WORKER_NODES:-0} (recreate: kind-down && kind-up)"
  fi

  if [[ "${KIND_NODE_COUNT:-0}" -ge 3 ]]; then
    ok "eks kind_node_count output >=3 (cp+workers: $KIND_NODE_COUNT)"
  else
    fail "eks kind_node_count unexpected ($KIND_NODE_COUNT)"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n kube-system get deploy metrics-server >/dev/null 2>&1; then
    ok "metrics-server deployment present"
  else
    fail "metrics-server missing (HPA needs it; run kind-up.sh)"
  fi

  MIRROR_CM="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n default \
    get configmap "eks-mirror-${EKS_CLUSTER_NAME}" -o jsonpath='{.data.provider}' 2>/dev/null || true)"
  if [[ "$MIRROR_CM" == "kind" ]]; then
    ok "eks-mirror ConfigMap present (provider=kind)"
  else
    fail "eks-mirror ConfigMap missing or unexpected"
  fi

  READY_PODS="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${READY_PODS:-0}" -ge 2 ]]; then
    ok "sample-nginx deployment readyReplicas>=2 in $EKS_SAMPLE_NS"
  else
    fail "sample-nginx deployment not ready (readyReplicas=${READY_PODS:-empty}, want >=2)"
  fi

  DESIRED_REPLICAS="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [[ "${DESIRED_REPLICAS:-0}" -eq 2 ]]; then
    ok "sample-nginx spec.replicas=2"
  else
    fail "sample-nginx spec.replicas unexpected (${DESIRED_REPLICAS:-empty})"
  fi

  HAS_RESOURCES="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
containers=((d.get("spec") or {}).get("template") or {}).get("spec",{}).get("containers") or []
ok=False
for c in containers:
  r=(c.get("resources") or {})
  if (r.get("requests") or {}).get("memory") and (r.get("limits") or {}).get("memory"):
    ok=True
sys.exit(0 if ok else 1)
' 2>/dev/null && echo yes || echo no)"
  if [[ "$HAS_RESOURCES" == "yes" ]]; then
    ok "sample-nginx container resources requests/limits set"
  else
    fail "sample-nginx container resources missing"
  fi

  HAS_LIVENESS="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null || true)"
  if [[ "$HAS_LIVENESS" == "/" ]]; then
    ok "sample-nginx liveness_probe present"
  else
    fail "sample-nginx liveness_probe missing"
  fi

  HAS_STARTUP="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.spec.template.spec.containers[0].startupProbe.httpGet.path}' 2>/dev/null || true)"
  if [[ "$HAS_STARTUP" == "/" ]]; then
    ok "sample-nginx startup_probe present"
  else
    fail "sample-nginx startup_probe missing"
  fi

  HAS_SPREAD="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].topologyKey}' 2>/dev/null || true)"
  if [[ "$HAS_SPREAD" == "kubernetes.io/hostname" ]]; then
    ok "sample-nginx topology_spread_constraint on hostname"
  else
    fail "sample-nginx topology_spread_constraint missing"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get pdb sample-nginx >/dev/null 2>&1; then
    ok "PodDisruptionBudget sample-nginx exists"
  else
    fail "PodDisruptionBudget sample-nginx missing"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get resourcequota app-quota >/dev/null 2>&1; then
    ok "ResourceQuota app-quota exists"
  else
    fail "ResourceQuota app-quota missing"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get limitrange app-limits >/dev/null 2>&1; then
    ok "LimitRange app-limits exists"
  else
    fail "LimitRange app-limits missing"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get hpa sample-nginx >/dev/null 2>&1; then
    ok "HPA sample-nginx exists"
  else
    fail "HPA sample-nginx missing"
  fi

  # LocalStack bridge Service + Endpoints
  LS_SVC_IP="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get svc localstack -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ "$LS_SVC_IP" == "None" ]]; then
    ok "localstack headless Service exists"
  else
    fail "localstack headless Service missing or not headless (clusterIP=${LS_SVC_IP:-empty})"
  fi

  LS_EP_IP="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get endpoints localstack -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  if [[ -n "$LS_EP_IP" && "$LS_EP_IP" == "$LS_BRIDGE_IP" ]]; then
    ok "localstack Endpoints IP matches bridge output ($LS_EP_IP)"
  else
    fail "localstack Endpoints IP mismatch (ep=${LS_EP_IP:-empty} bridge=${LS_BRIDGE_IP:-empty})"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get sa workload >/dev/null 2>&1; then
    ok "ServiceAccount workload exists"
  else
    fail "ServiceAccount workload missing"
  fi

  SA_ROLE="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get sa workload -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
  if [[ -n "$SA_ROLE" && "$SA_ROLE" == "$EKS_WORKLOAD_ROLE" ]]; then
    ok "ServiceAccount IRSA annotation matches workload role"
  else
    fail "ServiceAccount IRSA annotation mismatch"
  fi

  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get secret localstack-creds >/dev/null 2>&1; then
    ok "LOCAL-ONLY Secret localstack-creds exists"
  else
    fail "Secret localstack-creds missing"
  fi

  WORKLOAD_ROLE_NAME="${EXPECT_PREFIX}-eks-workload"
  if aws_ls iam get-role --role-name "$WORKLOAD_ROLE_NAME" >/dev/null 2>&1; then
    ok "EKS workload IAM role exists ($WORKLOAD_ROLE_NAME)"
  else
    fail "EKS workload IAM role missing ($WORKLOAD_ROLE_NAME)"
  fi

  # smoke-test-messaging Job must be Complete (Jobs are kept without TTL so
  # verify can observe them after apply; replace_triggered_by recreates on change).
  if kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" get job smoke-test-messaging >/dev/null 2>&1; then
    JOB_STATUS="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
      get job smoke-test-messaging -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    JOB_FAILED="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
      get job smoke-test-messaging -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [[ "$JOB_STATUS" == "True" && "$JOB_FAILED" != "True" ]]; then
      ok "smoke-test-messaging Job Complete"
    else
      fail "smoke-test-messaging Job not Complete (Complete=$JOB_STATUS Failed=$JOB_FAILED)"
      kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" logs job/smoke-test-messaging --tail=40 >&2 || true
    fi
  else
    fail "smoke-test-messaging Job missing (re-apply eks after LocalStack bridge is up)"
  fi

  SVC_PORT="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get svc "$EKS_SAMPLE_SVC" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ "$SVC_PORT" == "$EKS_NODE_PORT" ]]; then
    ok "sample Service NodePort matches output ($SVC_PORT)"
  else
    fail "sample Service NodePort mismatch (expected $EKS_NODE_PORT, got ${SVC_PORT:-empty})"
  fi

  if curl -sf --max-time 15 "http://127.0.0.1:${EKS_NODE_PORT}/" | grep -qi nginx; then
    ok "Kind NodePort smoke (nginx via :$EKS_NODE_PORT)"
  else
    fail "Kind NodePort smoke failed (http://127.0.0.1:${EKS_NODE_PORT}/)"
  fi
else
  fail "kubectl or Kind kubeconfig missing for workload checks"
fi
