output "instance_id" {
  value = aws_instance.app.id
}

output "instance_public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_ip}:8000"
}

output "rds_endpoint" {
  value = aws_db_instance.db.address
}

output "rds_identifier" {
  value = aws_db_instance.db.identifier
}

output "secret_name" {
  value = aws_secretsmanager_secret.db.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

# Lo usan los workflows de deploy para entrar por SSH. Queda en el tfstate remoto (no en el repo).
output "private_key_pem" {
  value     = tls_private_key.ssh.private_key_pem
  sensitive = true
}
