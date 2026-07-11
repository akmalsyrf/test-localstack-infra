# Sample workload on Kind (mirrors deploying into LocalStack EKS after CreateNodegroup).

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
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }
        }
      }
    }
  }
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
  }

  depends_on = [aws_iam_role_policy.cluster, aws_iam_role_policy.node, data.external.kind]
}
