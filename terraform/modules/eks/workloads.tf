# Sample workload on Kind (mirrors deploying into LocalStack EKS after CreateNodegroup).
#
# HPA requires metrics-server (installed by scripts/kind-up.sh with --kubelet-insecure-tls).
# NetworkPolicy enforcement needs Calico (optional; Kind default kindnet does not enforce
# policies — skipped to keep CI bring-up stable). See docs/ARCHITECTURE.md.

locals {
  app_ns = var.deploy_sample_workload ? kubernetes_namespace_v1.app[0].metadata[0].name : ""
  # In-cluster LocalStack base URL via headless Service (see localstack Service below).
  localstack_base_url = var.deploy_sample_workload ? "http://localstack.${local.app_ns}.svc.cluster.local:4566" : ""
  # Rewrite LocalStack queue URLs so pods do not call localhost.
  sqs_standard_url_incluster = var.deploy_sample_workload ? replace(
    replace(var.sqs_standard_queue_url, "http://localhost:4566", local.localstack_base_url),
    "http://127.0.0.1:4566", local.localstack_base_url
  ) : ""
  sqs_fifo_url_incluster = var.deploy_sample_workload ? replace(
    replace(var.sqs_fifo_queue_url, "http://localhost:4566", local.localstack_base_url),
    "http://127.0.0.1:4566", local.localstack_base_url
  ) : ""
}

resource "kubernetes_namespace_v1" "app" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name = "${var.prefix}-app"
    labels = {
      "app.kubernetes.io/part-of" = var.prefix
      "testinfra.io/mirror"       = "localstack-eks"
      "eks.amazonaws.com/cluster" = var.cluster_name
    }
  }

  depends_on = [data.external.kind]
}

resource "kubernetes_resource_quota_v1" "app" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "app-quota"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "2"
      "requests.memory" = "2Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "4Gi"
      pods              = "20"
    }
  }
}

resource "kubernetes_limit_range_v1" "app" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "app-limits"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "200m"
        memory = "256Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "64Mi"
      }
      max = {
        cpu    = "1"
        memory = "1Gi"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# LOCAL-ONLY: LocalStack reachability via headless Service + Endpoints.
# IP comes from data.external.localstack_network (Docker `kind` network).
# Delete Service + Endpoints + localstack-network-info.sh when migrating to
# real EKS (workloads use VPC / VPC endpoints / public AWS APIs instead).
# ---------------------------------------------------------------------------
resource "kubernetes_service_v1" "localstack" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "localstack"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    labels = {
      "testinfra.io/bridge" = "localstack"
    }
  }

  spec {
    cluster_ip = "None" # headless — DNS returns Endpoints IPs directly
    port {
      name        = "edge"
      port        = 4566
      target_port = 4566
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_endpoints_v1" "localstack" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = kubernetes_service_v1.localstack[0].metadata[0].name
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
  }

  subset {
    address {
      ip = data.external.localstack_network.result.ip
    }
    port {
      name     = "edge"
      port     = 4566
      protocol = "TCP"
    }
  }
}

module "iam_workload" {
  count  = var.deploy_sample_workload ? 1 : 0
  source = "../iam-eks-workload"

  role_name              = "${var.prefix}-eks-workload"
  namespace              = kubernetes_namespace_v1.app[0].metadata[0].name
  service_account_name   = "workload"
  enable_irsa_oidc       = var.enable_irsa_oidc
  oidc_provider_arn      = var.oidc_provider_arn
  oidc_issuer_host       = var.oidc_issuer_host
  sns_topic_arn          = var.sns_topic_arn
  sqs_standard_queue_arn = var.sqs_standard_queue_arn
  sqs_fifo_queue_arn     = var.sqs_fifo_queue_arn
  tags                   = var.tags
}

resource "kubernetes_service_account_v1" "workload" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "workload"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    annotations = {
      # Inert on Kind; becomes active IRSA on real EKS when enable_irsa_oidc=true.
      "eks.amazonaws.com/role-arn" = module.iam_workload[0].role_arn
    }
  }
}

# ---------------------------------------------------------------------------
# LOCAL-ONLY BYPASS — remove this Secret when migrating to real EKS with IRSA.
# Pods get dummy LocalStack credentials + in-cluster endpoint override.
# On real EKS: delete this Secret, drop envFrom, rely on IRSA via ServiceAccount.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "localstack_creds" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "localstack-creds"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    labels = {
      "testinfra.io/local-only" = "true"
    }
  }

  data = {
    AWS_ACCESS_KEY_ID      = "test"
    AWS_SECRET_ACCESS_KEY  = "test"
    AWS_DEFAULT_REGION     = var.aws_region
    AWS_REGION             = var.aws_region
    AWS_ENDPOINT_URL       = local.localstack_base_url
    SQS_STANDARD_QUEUE_URL = local.sqs_standard_url_incluster
    SQS_FIFO_QUEUE_URL     = local.sqs_fifo_url_incluster
    SNS_TOPIC_ARN          = var.sns_topic_arn
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "sample" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "sample-nginx"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    labels = {
      app = "sample-nginx"
    }
  }

  spec {
    replicas = var.sample_replicas

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }

    selector {
      match_labels = {
        app = "sample-nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "sample-nginx"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.workload[0].metadata[0].name

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              app = "sample-nginx"
            }
          }
        }

        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
            name           = "http"
          }

          # LOCAL-ONLY: messaging endpoint env (unused by nginx; proves wiring for sidecars/jobs).
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.localstack_creds[0].metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          startup_probe {
            http_get {
              path = "/"
              port = 80
            }
            failure_threshold     = 10
            period_seconds        = 2
            initial_delay_seconds = 0
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_resource_quota_v1.app,
    kubernetes_limit_range_v1.app,
    kubernetes_endpoints_v1.localstack,
  ]

  # Fail fast if Kind is unhealthy / pods never become Ready (CI hung waiters).
  timeouts {
    create = "5m"
    update = "5m"
    delete = "5m"
  }
}

resource "kubernetes_pod_disruption_budget_v1" "sample" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "sample-nginx"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = {
        app = "sample-nginx"
      }
    }
  }

  depends_on = [kubernetes_deployment_v1.sample]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "sample" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "sample-nginx"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
  }

  spec {
    min_replicas = 2
    max_replicas = 4

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.sample[0].metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }

  depends_on = [kubernetes_deployment_v1.sample]
}

resource "kubernetes_service_v1" "sample" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "sample-nginx"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    labels = {
      app = "sample-nginx"
    }
  }

  spec {
    selector = {
      app = "sample-nginx"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 80
      node_port   = var.sample_node_port
    }

    type = "NodePort"
  }

  depends_on = [kubernetes_deployment_v1.sample]
}

# Smoke-test: publish SNS → receive SQS via in-cluster LocalStack bridge.
resource "kubernetes_job_v1" "smoke_messaging" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "smoke-test-messaging"
    namespace = kubernetes_namespace_v1.app[0].metadata[0].name
    labels = {
      "testinfra.io/smoke" = "messaging"
    }
  }

  wait_for_completion = true

  timeouts {
    create = "4m"
  }

  spec {
    # Keep completed Jobs around for verify-apply (TTL caused silent drift:
    # K8s deleted the Job while Terraform state still pointed at it).
    backoff_limit = 1

    template {
      metadata {
        labels = {
          "testinfra.io/smoke" = "messaging"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.workload[0].metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "awscli"
          image = "amazon/aws-cli:2.15.0"

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.localstack_creds[0].metadata[0].name
            }
          }

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            MSG_ID="smoke-$$(date +%s)-$${RANDOM}"
            echo "Publishing MSG_ID=$$MSG_ID to $$SNS_TOPIC_ARN via $$AWS_ENDPOINT_URL"
            aws sns publish \
              --endpoint-url "$$AWS_ENDPOINT_URL" \
              --topic-arn "$$SNS_TOPIC_ARN" \
              --message "{\"smoke\":true,\"id\":\"$$MSG_ID\"}"
            i=0
            while [ "$$i" -lt 30 ]; do
              BODY=$$(aws sqs receive-message \
                --endpoint-url "$$AWS_ENDPOINT_URL" \
                --queue-url "$$SQS_STANDARD_QUEUE_URL" \
                --max-number-of-messages 10 \
                --wait-time-seconds 1 \
                --query 'Messages[].Body' \
                --output text 2>/dev/null || true)
              echo "poll $$i: $$BODY"
              case "$$BODY" in
                *"$$MSG_ID"*) echo "SNS→SQS smoke OK"; exit 0 ;;
              esac
              i=$$((i+1))
              sleep 1
            done
            echo "SNS→SQS smoke FAILED: message not received" >&2
            exit 1
          EOT
          ]

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_endpoints_v1.localstack,
    kubernetes_secret_v1.localstack_creds,
    module.iam_workload,
  ]

  lifecycle {
    # Job pods are immutable; recreate when messaging endpoints change.
    replace_triggered_by = [
      kubernetes_secret_v1.localstack_creds[0].id,
      kubernetes_endpoints_v1.localstack[0].id,
    ]
  }
}

# Annotate a ConfigMap as the "registered" EKS-like cluster record (for humans / verify).
resource "kubernetes_config_map_v1" "eks_mirror" {
  metadata {
    name      = "eks-mirror-${var.cluster_name}"
    namespace = "default"
    labels = {
      "testinfra.io/mirror" = "localstack-eks"
    }
  }

  data = {
    cluster_name      = var.cluster_name
    cluster_arn       = local.cluster_arn
    cluster_endpoint  = local.kind_endpoint
    cluster_version   = coalesce(local.kind_version, var.kubernetes_version)
    cluster_status    = data.external.kind.result.status
    node_group_name   = local.node_group_name
    node_group_arn    = local.node_group_arn
    node_role_arn     = aws_iam_role.node.arn
    cluster_role_arn  = aws_iam_role.cluster.arn
    subnet_ids        = join(",", var.subnet_ids)
    kind_cluster_name = var.kind_cluster_name
    provider          = "kind"
    localstack_bridge = try(data.external.localstack_network.result.ip, "")
  }

  depends_on = [aws_iam_role_policy.cluster, aws_iam_role_policy.node, data.external.kind]
}
