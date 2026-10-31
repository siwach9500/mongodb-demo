terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }

  # Remote state in S3, with a lock in DynamoDB
  backend "s3" {
    bucket         = "mongo-demo-assets"   # CHANGE
    key            = "mongo-demo/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "mongo-demo-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "ap-south-1"
  default_tags {
    tags = { Project = "mongo-demo" }   # the inventory finds servers by this tag
  }
}

locals {
  bucket = "mongo-demo-assets"   # CHANGE (same as the backend bucket)
}

# ---------- network: default VPC ----------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "mongo" {
  name_prefix = "mongo-demo-"
  vpc_id      = data.aws_vpc.default.id

  # Only the 3 nodes can talk to each other. No SSH port.
  ingress {
    from_port = 27017
    to_port   = 27017
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- IAM role: SSM access + upload backups to S3 ----------
resource "aws_iam_role" "mongo" {
  name_prefix = "mongo-demo-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.mongo.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "backup" {
  name = "backup-to-s3"
  role = aws_iam_role.mongo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::${local.bucket}/backups/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.bucket}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "mongo" {
  name_prefix = "mongo-demo-"
  rresource "terraform_data" "wait_for_iam" {
  depends_on = [
    aws_iam_instance_profile.mongo,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.backup,
  ]

  provisioner "local-exec" {
    command = "sleep 60"
  }
}ole        = aws_iam_role.mongo.name
}

# ---------- 3 MongoDB servers ----------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "mongo" {
  count = 3

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = data.aws_subnets.default.ids[count.index]
  vpc_security_group_ids      = [aws_security_group.mongo.id]
  iam_instance_profile        = aws_iam_instance_profile.mongo.name
  associate_public_ip_address = true   # outbound internet only (SSM + apt)

  depends_on = [aws_iam_role_policy_attachment.ssm]

  tags = {
    Name      = "mongo-${count.index + 1}"
    Role      = "mongodb"
    NodeIndex = tostring(count.index + 1)
    SsmBucket = local.bucket
  }
}

resource "terraform_data" "wait_for_iam" {
  depends_on = [
    aws_iam_instance_profile.mongo,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.backup,
  ]

  provisioner "local-exec" {
    command = "sleep 60"
  }
}

output "instance_ids" {
  value = aws_instance.mongo[*].id
}
