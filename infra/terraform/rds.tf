resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.env}-rds"
  description = "Postgres access from EKS nodes only."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.env}"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project}-${var.env}"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_type           = "gp3"
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.env == "prod"

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  backup_retention_period = var.env == "prod" ? 7 : 1
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:00-sun:04:00"
  deletion_protection     = var.env == "prod"
  skip_final_snapshot     = var.env != "prod"

  performance_insights_enabled = var.env == "prod"

  tags = {
    Name = "${var.project}-${var.env}-postgres"
  }
}

# Store DB URL parts in Secrets Manager. The Helm chart reads them via
# External Secrets Operator or plain env-from-secret wired by ArgoCD values.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project}/${var.env}/database"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    DB_HOST     = aws_db_instance.main.address
    DB_PORT     = "5432"
    DB_DATABASE = var.db_name
    DB_USERNAME = var.db_username
    DB_PASSWORD = random_password.db.result
  })
}
