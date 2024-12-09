# Define the AWS provider
provider "aws" {
  region = "us-west-2"
}

# Define variables
variable "az_list" {
  default = ["us-west-2a", "us-west-2b"]
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "public_subnet_ranges" {
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_ranges" {
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}

# Create public subnets
resource "aws_subnet" "public_subnets" {
  count                   = length(var.az_list)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_ranges[count.index]
  availability_zone       = var.az_list[count.index]
  map_public_ip_on_launch = true
}

# Create private subnets
resource "aws_subnet" "private_subnets" {
  count             = length(var.az_list)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_ranges[count.index]
  availability_zone = var.az_list[count.index]
}

# Create Internet Gateway and route table for public subnets
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_rta" {
  count          = length(var.az_list)
  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# Security Group for public subnet
resource "aws_security_group" "public_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
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

# Security Group for private subnet
resource "aws_security_group" "private_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.public_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Autoscaling Group in public subnet
resource "aws_launch_template" "as_conf" {
  name            = "asg_config_1"
  image_id        = "ami-055e3d4f0bbeb5878"
  instance_type   = "t2.micro"
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }
  vpc_security_group_ids = [aws_security_group.public_sg.id]
}

resource "aws_autoscaling_group" "asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = aws_subnet.public_subnets[*].id
  launch_template {
    id      = aws_launch_template.as_conf.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.public_tg.arn]
}

# EC2 instance in private subnet
resource "aws_instance" "private_instance" {
  ami             = "ami-055e3d4f0bbeb5878"
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.private_subnets[0].id
  security_groups = [aws_security_group.private_sg.id]
}

# Load Balancers
resource "aws_lb" "public_lb" {
  name               = "publiclb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.public_sg.id]
  subnets            = aws_subnet.public_subnets[*].id
}

resource "aws_lb_target_group" "public_tg" {
  name     = "public-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.public_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.public_tg.arn
  }
}

# S3 bucket
resource "aws_s3_bucket" "app_storage" {
  bucket = "application-storage-bucket"
  tags = {
    Name = "app_storage"
  }
}

resource "aws_s3_bucket_acl" "app_storage_acl" {
  bucket = aws_s3_bucket.app_storage.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "app_storage_versioning" {
  bucket = aws_s3_bucket.app_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM role
resource "aws_iam_role" "ec2_role" {
  name = "EC2S3AccessRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "policy" {
  name        = "s3-policy"
  description = "IAM policy granting full access to the S3 bucket."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:*",
        ]
        Resource = [
          "${aws_s3_bucket.app_storage.arn}",
          "${aws_s3_bucket.app_storage.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_full_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2S3IntsanceProfile"
  role = aws_iam_role.ec2_role.name
}

