terraform {
  required_version = ">=1.9.2"
}

provider "aws" {
  region     = var.region
  secret_key = var.secret_key
  access_key = var.access_key
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "joyjam" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "joyjam-vpc"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.joyjam.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-${count.index}"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.joyjam.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "joyjam" {
  vpc_id = aws_vpc.joyjam.id
  tags = {
    Name = "joyjam-igw"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_eip" "nat" {
  vpc = true
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.joyjam.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.joyjam.id
  }
}

resource "aws_route_table_association" "public_subnet" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.joyjam.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private_subnet" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "bastion_sg" {
  vpc_id = aws_vpc.joyjam.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_instance" "bastion" {
  ami           = var.ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name = "bastion-host"
  }

  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
}

resource "aws_db_instance" "postgresql" {
  identifier             = var.db_identifier
  engine                 = var.db_engine
  instance_class         = var.db_instance_type
  allocated_storage      = var.db_allocated_storage
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.postgresql.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false
}

resource "aws_db_subnet_group" "postgresql" {
  name       = "my-postgres-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags = {
    Name = "postgresql-subnet-group"
  }
}

resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.joyjam.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }
}

resource "aws_s3_bucket" "user_bucket" {
  bucket = "user-bucket"

  tags = {
    Name = "user-bucket"
  }

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_acl" "user_bucket_acl" {
  bucket = aws_s3_bucket.user_bucket.id
  acl    = "public-read"

}

resource "aws_s3_bucket" "admin_bucket" {
  bucket = "admin-bucket"

  tags = {
    Name = "admin-bucket"
  }

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_acl" "admin_bucket_acl" {
  bucket = aws_s3_bucket.admin_bucket.id
  acl    = "public-read"
}


resource "aws_cloudfront_origin_access_identity" "admin" {
  comment = "Origin access identity for admin bucket"
}


resource "aws_cloudfront_distribution" "admin_cloudfront" {

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  origin {
    domain_name = aws_s3_bucket.admin_bucket.website_endpoint
    origin_id   = "s3-admin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.admin.id
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  default_cache_behavior {
    target_origin_id = "s3-admin"

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]

    cached_methods = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  price_class = "PriceClass_100"

  tags = {
    Name = "admin-cloudfront"
  }
}


resource "aws_cloudfront_origin_access_identity" "user" {
  comment = "Origin access identity for admin bucket"

}

resource "aws_cloudfront_distribution" "user_cloudfront" {

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  origin {
    domain_name = aws_s3_bucket.user_bucket.website_endpoint
    origin_id   = "s3-user"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.user.id
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  default_cache_behavior {
    target_origin_id = "s3-user"

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]

    cached_methods = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  price_class = "PriceClass_100"

  tags = {
    Name = "user-cloudfront"
  }
}



resource "aws_s3_bucket" "media_bucket" {
  bucket = "media-bucket"
  tags = {
    Name = "media-bucket"
  }
}

resource "aws_s3_bucket_acl" "media_bucket_acl" {
  bucket = aws_s3_bucket.media_bucket.id
  acl    = "private"

}
# -----------------------------------------------------------

resource "aws_cloudfront_origin_access_identity" "media" {
  comment = "OAI for media bucket"

}

resource "aws_cloudfront_distribution" "media_cloudfront" {

  viewer_certificate {
    cloudfront_default_certificate = true

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  origin {
    domain_name = aws_s3_bucket.media_bucket.bucket_regional_domain_name
    origin_id   = "s3-media"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.media.id

    }
  }
  enabled         = true
  is_ipv6_enabled = true

  default_cache_behavior {
    target_origin_id = "s3-user"

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]

    cached_methods = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }

    }
  }

  price_class = "PriceClass_100"

  tags = {
  }
}



