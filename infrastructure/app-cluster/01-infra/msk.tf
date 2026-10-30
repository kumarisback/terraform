# ---------------------------------------------------------
# Amazon MSK Serverless (roadmap step 14, learning topic 14): the managed
# alternative to the Strimzi cluster. Off by default and meant to be on
# for an afternoon: it bills about $0.75 an hour for existing, plus
# partitions and traffic. gitops docs/msk-vs-strimzi.md says how to point
# the services at it and back.
#
# Kafka ACLs become IAM policies: each service's IRSA role below may do
# with its topics and group exactly what its KafkaUser may on Strimzi
# (gitops streaming/base/users.yaml), and msk_admin creates the topics.
# ---------------------------------------------------------
module "msk" {
  source = "../../../modules/msk"
  count  = var.enable_msk ? 1 : 0

  name               = var.project_name
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_app_subnet_ids
  client_cidr_blocks = var.private_app_subnet_cidrs
}

locals {
  # "" while MSK is off: the roles below are dropped then, but their
  # policies are still built.
  msk_cluster_arn  = try(module.msk[0].cluster_arn, "")
  msk_topic_prefix = try(module.msk[0].topic_arn_prefix, "")
  msk_group_prefix = try(module.msk[0].group_arn_prefix, "")

  # Every client signs in and reads the cluster's metadata. Producers are
  # idempotent (a retried send can't duplicate), which IAM checks apart.
  msk_connect = {
    Effect   = "Allow"
    Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    Resource = local.msk_cluster_arn
  }
  msk_write_idempotently = {
    Effect   = "Allow"
    Action   = ["kafka-cluster:WriteDataIdempotently"]
    Resource = local.msk_cluster_arn
  }

  # Merged into module "eks"'s irsa_roles (main.tf). The services'
  # ServiceAccounts carry these roles only while they use MSK.
  msk_irsa_roles = {
    for k, v in {
      msk_order_service = {
        namespace       = var.msk_client_namespace
        service_account = "order-service"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            local.msk_connect,
            local.msk_write_idempotently,
            {
              Effect   = "Allow"
              Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
              Resource = "${local.msk_topic_prefix}/orders"
            }
          ]
        })
      }

      msk_user_service = {
        namespace       = var.msk_client_namespace
        service_account = "user-service"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            local.msk_connect,
            local.msk_write_idempotently,
            {
              Effect   = "Allow"
              Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
              Resource = "${local.msk_topic_prefix}/users"
            }
          ]
        })
      }

      # Reads both topics in its group; parks what it gives up on in the
      # dead-letter topics.
      msk_notification_service = {
        namespace       = var.msk_client_namespace
        service_account = "notification-service"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            local.msk_connect,
            local.msk_write_idempotently,
            {
              Effect   = "Allow"
              Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
              Resource = ["${local.msk_topic_prefix}/orders", "${local.msk_topic_prefix}/users"]
            },
            {
              Effect   = "Allow"
              Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
              Resource = ["${local.msk_topic_prefix}/orders-dlq", "${local.msk_topic_prefix}/users-dlq"]
            },
            {
              Effect   = "Allow"
              Action   = ["kafka-cluster:DescribeGroup", "kafka-cluster:AlterGroup"]
              Resource = "${local.msk_group_prefix}/notification-service"
            }
          ]
        })
      }

      # The topics Job (gitops msk/topics-job.yaml), in a namespace of its
      # own: creates and configures topics, reads and writes no data.
      msk_admin = {
        namespace       = "msk-admin"
        service_account = "msk-admin"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            local.msk_connect,
            {
              Effect = "Allow"
              Action = [
                "kafka-cluster:CreateTopic",
                "kafka-cluster:DescribeTopic",
                "kafka-cluster:AlterTopic",
                "kafka-cluster:DescribeTopicDynamicConfiguration",
                "kafka-cluster:AlterTopicDynamicConfiguration"
              ]
              Resource = "${local.msk_topic_prefix}/*"
            }
          ]
        })
      }
    } : k => v if var.enable_msk
  }
}
