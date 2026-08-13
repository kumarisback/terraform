output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr_block" {
  value = aws_vpc.main.cidr_block
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

# First (or only, in single-NAT mode) private route table. The
# shared-services VPC peering routes in 01-infra assume single-NAT mode and
# use this; multi-AZ NAT deployments should use private_route_table_ids
# instead and add a peering route per AZ if cross-VPC private traffic needs
# to reach every AZ.
output "private_route_table_id" {
  value = aws_route_table.private[0].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  value = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  value = aws_subnet.private_data[*].id
}
