terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  prefix = "${var.prefix}-${var.env}"
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
}

# configure the VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.4.0"

  name = "${local.prefix}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  tags = {
    Terraform   = "true"
    Environment = var.env
  }
}

resource "aws_security_group" "lb-sg" {
  name        = "${local.prefix}-lb-sg"
  description = "Allow vault traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Vault traffic"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = var.port
    to_port          = var.port
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Environment = var.env
  }
}

resource "aws_lb" "public" {
  name               = local.prefix
  internal           = false
  load_balancer_type = "network"
  security_groups    = [aws_security_group.lb-sg.id]
  subnets            = module.vpc.public_subnets
  tags = {
    Environment = var.env
  }
}

resource "aws_lb_target_group" "target_group_public" {
  name        = local.prefix
  port        = var.port
  protocol    = "TCP"
  target_type = "ip"

  vpc_id = module.vpc.vpc_id

  tags = {
    Environment = var.env
  }
}

resource "aws_lb_listener" "public_listener" {
  load_balancer_arn = aws_lb.public.arn
  port              = var.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_public.arn
  }

  tags = {
    Environment = var.env
  }
}

resource "aws_kms_key" "vault-cluster-kms" {
  description             = "Vault Cluster CloudWatch Logs Key"
  deletion_window_in_days = 7
}

resource "aws_cloudwatch_log_group" "vault-cluster-cloudwatch-log-group" {
  name = local.prefix
}

resource "aws_ecs_cluster" "vault-cluster" {
  name = local.prefix

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.vault-cluster-kms.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.vault-cluster-cloudwatch-log-group.name
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "app" {
  cluster_name = aws_ecs_cluster.vault-cluster.name

  capacity_providers = ["FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
  }
}

resource "aws_iam_role" "ECSTaskExecutionRole" {
  name_prefix = local.prefix

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Environment = var.env
  }
}

resource "aws_iam_policy" "ECSTaskPolicy" {

  name        = "ECSTaskPolicy"
  path        = "/"
  description = "Permissions used by ECS tasks"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutRetentionPolicy",
          "logs:CreateLogGroup"
        ],
        "Effect" : "Allow",
        "Resource" : "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ECSRolePolicyAttachment" {
  role       = aws_iam_role.ECSTaskExecutionRole.name
  policy_arn = aws_iam_policy.ECSTaskPolicy.arn
}


resource "aws_ecs_task_definition" "vault-cluster" {
  family                   = local.prefix
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  execution_role_arn = aws_iam_role.ECSTaskExecutionRole.arn
  container_definitions = jsonencode([
    {
      name      = local.prefix
      image     = "${var.docker_hub_image_name}:${var.vault_version_tag}"
      cpu       = var.container_cpu
      memory    = var.container_memory
      essential = true
      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
        }
      ]
    }
  ])
}

resource "aws_security_group" "vault-cluster-ecs" {
  name        = "${local.prefix}-sg"
  description = "Allow Vault traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Vault Incoming Traffic"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To allow ECR repository image download"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.env
  }
}



resource "aws_ecs_service" "ecs_service" {
  depends_on                         = [aws_lb.public]
  name                               = local.prefix
  cluster                            = aws_ecs_cluster.vault-cluster.id
  launch_type                        = "FARGATE"
  deployment_maximum_percent         = "200"
  deployment_minimum_healthy_percent = "75"
  desired_count                      = var.desired_count

  force_new_deployment = true

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.vault-cluster-ecs.id]
  }
  # Track the latest ACTIVE revision
  task_definition = "${aws_ecs_task_definition.vault-cluster.family}:${max(aws_ecs_task_definition.vault-cluster.revision, aws_ecs_task_definition.vault-cluster.revision)}"

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group_public.arn
    container_name   = local.prefix
    container_port   = var.port
  }
}

data "aws_route53_zone" "uri" {
  name         = var.dns
  private_zone = false
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.uri.id
  name    = "vault.${var.dns}"
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}
