provider "azurerm" {
  version = "~>1.20.0"
}

data "azurerm_subscription" "current" {}

resource "azurerm_azuread_application" "aks" {
  name = "${var.prefix}-k8sbook-sp-aks-blue-${var.cluster_type}"
}

resource "azurerm_azuread_service_principal" "aks" {
  application_id = "${azurerm_azuread_application.aks.application_id}"
}

resource "azurerm_role_assignment" "aks" {
  scope                = "${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = "${azurerm_azuread_service_principal.aks.id}"
}

resource "random_string" "password" {
  length  = 32
  special = true
}

resource "azurerm_azuread_service_principal_password" "aks" {
  end_date             = "2299-12-30T23:00:00Z"                        # Forever
  service_principal_id = "${azurerm_azuread_service_principal.aks.id}"
  value                = "${random_string.password.result}"
}

resource "null_resource" "aadsync_delay" {
  // Wait for AAD async global replication
  provisioner "local-exec" {
    command = "sleep 120"
  }

  triggers = {
    "before" = "${azurerm_azuread_service_principal_password.aks.id}"
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  depends_on = ["null_resource.aadsync_delay"]

  name                = "${var.prefix}-k8sbook-${var.chap}-aks-blue-${var.cluster_type}"
  kubernetes_version  = "1.11.4"
  location            = "${var.location}"
  resource_group_name = "${var.resource_group_name}"
  dns_prefix          = "${var.prefix}-k8sbook-${var.chap}-aks-blue-${var.cluster_type}"

  agent_pool_profile {
    name            = "default"
    count           = 2
    vm_size         = "Standard_D2s_v3"
    os_type         = "Linux"
    os_disk_size_gb = 30
  }

  service_principal {
    client_id     = "${azurerm_azuread_application.aks.application_id}"
    client_secret = "${azurerm_azuread_service_principal_password.aks.value}"
  }

  role_based_access_control {
    enabled = true

    azure_active_directory {
      client_app_id     = "${var.aad_client_app_id}"
      server_app_id     = "${var.aad_server_app_id}"
      server_app_secret = "${var.aad_server_app_secret}"
    }
  }

  addon_profile {
    http_application_routing {
      enabled = true
    }

    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = "${var.log_analytics_workspace_id}"
    }
  }
}

resource "azurerm_monitor_metric_alert" "pendning_pods" {
  name                = "pending_pods_${azurerm_kubernetes_cluster.aks.name}"
  resource_group_name = "${var.resource_group_name}"
  scopes              = ["${azurerm_kubernetes_cluster.aks.id}"]
  description         = "Action will be triggered when pending pods count is greater than 0."

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "kube_pod_status_phase"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      "name"     = "phase"
      "operator" = "Include"
      "values"   = ["Pending"]
    }
  }

  action {
    action_group_id = "${var.action_group_id_critical}"
  }
}

provider "kubernetes" {
  load_config_file       = false
  host                   = "${azurerm_kubernetes_cluster.aks.kube_admin_config.0.host}"
  client_certificate     = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.client_certificate)}"
  client_key             = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.client_key)}"
  cluster_ca_certificate = "${base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.0.cluster_ca_certificate)}"
}

resource "kubernetes_service" "todoapp" {
  depends_on = ["azurerm_kubernetes_cluster.aks"]

  metadata {
    name = "todoapp"
  }

  spec {
    selector {
      app = "todoapp"
    }

    session_affinity = "ClientIP"

    port {
      port        = 80
      target_port = 8080
    }

    type = "LoadBalancer"
  }
}

resource "azurerm_traffic_manager_endpoint" "todoapp-blue" {
  name                = "${var.prefix}-k8sbook-${var.chap}-todoapp-blue-${var.cluster_type}"
  resource_group_name = "${var.resource_group_name}"
  profile_name        = "${var.traffic_manager_profile_name}"
  target              = "${kubernetes_service.todoapp.load_balancer_ingress.0.ip}"
  type                = "externalEndpoints"
  priority            = "${var.traffic_manager_endpoint_priority}"
}

resource "kubernetes_secret" "cosmosdb" {
  depends_on = ["azurerm_kubernetes_cluster.aks"]

  metadata {
    name = "cosmosdb-secret"
  }

  data {
    MONGO_URL = "mongodb://${var.cosmosdb_account_name}:${var.cosmosdb_account_primary_master_key}@${var.cosmosdb_account_name}.documents.azure.com:10255/?ssl=true"
  }
}

resource "kubernetes_deployment" "todoapp" {
  metadata {
    name = "todoapp"
  }

  spec {
    replicas = 2

    selector {
      match_labels {
        app = "todoapp"
      }
    }

    template {
      metadata {
        labels {
          app = "todoapp"
        }
      }

      spec {
        container {
          image = "torumakabe/todo-app:0.0.2"
          name  = "todoapp"

          port {
            container_port = 8080
          }

          env {
            name = "MONGO_URL"

            value_from {
              secret_key_ref {
                name = "cosmosdb-secret"
                key  = "MONGO_URL"
              }
            }
          }

          resources {
            limits {
              cpu    = "250m"
              memory = "100Mi"
            }

            requests {
              cpu    = "250m"
              memory = "100Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_secret" "cluster_autoscaler" {
  depends_on = ["azurerm_kubernetes_cluster.aks"]

  metadata {
    name      = "cluster-autoscaler-azure"
    namespace = "kube-system"
  }

  data {
    ClientID          = "${azurerm_azuread_application.aks.application_id}"
    ClientSecret      = "${azurerm_azuread_service_principal_password.aks.value}"
    ResourceGroup     = "${var.resource_group_name}"
    SubscriptionID    = "${substr(var.subscription_id,15,-1)}"
    TenantID          = "${var.aad_tenant_id}"
    VMType            = "AKS"
    ClusterName       = "${azurerm_kubernetes_cluster.aks.name}"
    NodeResourceGroup = "${azurerm_kubernetes_cluster.aks.node_resource_group}"
  }
}