output "cluster_arn" {
  value = aws_msk_serverless_cluster.this.arn
}

output "cluster_name" {
  value = aws_msk_serverless_cluster.this.cluster_name
}

output "bootstrap_brokers_sasl_iam" {
  description = "host:port list for clients signing in with IAM"
  value       = data.aws_msk_bootstrap_brokers.this.bootstrap_brokers_sasl_iam
}

# IAM names a topic or consumer group of this cluster by the cluster's ARN
# with "cluster" replaced, followed by /<name>; e.g. <topic_arn_prefix>/orders.
output "topic_arn_prefix" {
  value = replace(aws_msk_serverless_cluster.this.arn, ":cluster/", ":topic/")
}

output "group_arn_prefix" {
  value = replace(aws_msk_serverless_cluster.this.arn, ":cluster/", ":group/")
}

output "security_group_id" {
  value = aws_security_group.msk.id
}
