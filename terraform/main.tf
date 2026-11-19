terraform {
  required_version = ">= 1.10"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  # Backend remoto: el bucket y la región se pasan con
  #   terraform init -backend-config="bucket=..." -backend-config="region=..."
  # para no dejar nombres hardcodeados en el repo. El tfstate nunca se commitea.
  backend "s3" {
    key          = "todo-list/terraform.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------ red
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ------------------------------------------------------------ key pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# ------------------------------------------------------ security groups
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "SSH y API de to-do-list"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (lo usa el workflow de deploy)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db-sg"
  description = "PostgreSQL solo desde la EC2 de la app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde la app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------ RDS
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "db" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "db" {
  identifier             = "${var.project_name}-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  apply_immediately      = true
}

# ------------------------------------------------------ Secrets Manager
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/db-credentials"
  description             = "Credenciales de RDS para to-do-list"
  recovery_window_in_days = 0 # permite destruir y recrear con el mismo nombre
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.db.address
    port     = aws_db_instance.db.port
    dbname   = var.db_name
  })
}

# ------------------------------------------------------------------ EC2
resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.app.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = var.instance_profile
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    repo_url    = var.repo_url
    app_version = var.app_version
    region      = var.aws_region
    secret_name = aws_secretsmanager_secret.db.name
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-app" }

  # La app lee el secret al primer request, así que el secret debe existir antes.
  depends_on = [aws_secretsmanager_secret_version.db]
}

# ------------------------------------------------- SNS + alarmas + dashboard
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # hay que confirmar el correo que llega de AWS
}

locals {
  # Se lee con file() para que los nombres de las alarmas sean conocidos en el plan.
  # El ID de la instancia se sustituye abajo, en las dimensiones.
  alarms = jsondecode(file("${path.module}/../alerting/alarms.json"))
}

resource "aws_cloudwatch_metric_alarm" "alarms" {
  for_each = local.alarms

  alarm_name          = "${var.project_name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  treat_missing_data  = each.value.treat_missing_data
  dimensions          = { for k, v in each.value.dimensions : k => (v == "INSTANCE_ID" ? aws_instance.app.id : v) }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"
  dashboard_body = templatefile("${path.module}/../alerting/cloudwatch-dashboard.json", {
    region      = var.aws_region
    instance_id = aws_instance.app.id
  })
}
