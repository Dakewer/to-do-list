variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para nombrar los recursos"
  type        = string
  default     = "todo-list"
}

variable "repo_url" {
  description = "URL https del repositorio que user_data clona (debe ser público)"
  type        = string
}

variable "app_version" {
  description = "Versión inicial que reporta GET /version (el deploy la actualiza)"
  type        = string
  default     = "v0.0.0"
}

variable "alert_email" {
  description = "Correo que se suscribe al tópico SNS de las alarmas"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "todos"
}

variable "db_username" {
  description = "Usuario administrador de RDS"
  type        = string
  default     = "todoadmin"
}

variable "instance_profile" {
  description = "Instance profile existente del Learner Lab (permite Secrets Manager y CloudWatch)"
  type        = string
  default     = "LabInstanceProfile"
}
