locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment
  })
}

resource "aws_vpc" "main" {
  cidr_block           = "${var.vpc_cidr_prefix}.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-igw" })
}

# Public subnets (azone / dzone / ezone)
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "${var.vpc_cidr_prefix}.${count.index == 0 ? 0 : count.index + 2}.0/24"
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.prefix}-public-${["azone", "dzone", "ezone"][count.index]}"
    Tier = "public"
  })
}

# Private subnets (bzone / czone / fzone)
resource "aws_subnet" "private" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "${var.vpc_cidr_prefix}.${[1, 2, 5][count.index]}.0/24"
  availability_zone       = var.availability_zones[[1, 2, 0][count.index]]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${local.prefix}-private-${["bzone", "czone", "fzone"][count.index]}"
    Tier = "private"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# LocalStack free: skip NAT Gateway (often flaky / unnecessary for local mocks)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
