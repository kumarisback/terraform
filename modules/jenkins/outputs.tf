output "private_ip" {
  value = aws_instance.jenkins.private_ip
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "instance_id" {
  value = aws_instance.jenkins.id
}
