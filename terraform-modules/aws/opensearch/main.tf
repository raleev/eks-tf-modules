resource "aws_cloudwatch_log_group" "opensearch_slow_logs" {
  name              = "${var.domain_name}-slow-logs"
  retention_in_days = var.retention_in_days
}

resource "aws_cloudwatch_log_resource_policy" "opensearch_slow_logs_policy" {
  policy_name = "${var.domain_name}-policy"
  policy_document = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "es.amazonaws.com"
        },
        "Action" : [
          "logs:PutLogEvents",
          "logs:CreateLogStream",
          "logs:PutLogEventsBatch"
        ],
        "Resource" : "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:${aws_cloudwatch_log_group.opensearch_slow_logs.name}:*"
      }
    ]
  })
}

resource "aws_opensearch_domain" "this" {
  domain_name    = var.domain_name
  engine_version = "OpenSearch_2.5"

  cluster_config {
    instance_type          = var.instance_type
    zone_awareness_enabled = var.zone_awareness_enabled
    instance_count         = var.instance_count
  }

  ebs_options {
    ebs_enabled = var.ebs_enabled
    volume_size = var.volume_size
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = var.enforce_https
    tls_security_policy = var.tls_security_policy
  }

  # the dynamic block creates a vpc_options block with the specified security group and subnet IDs.
  # If the variable vpc_enabled is set to false, the dynamic block is not created, 
  # and the aws_opensearch_domain resource will not include a vpc_options block, 
  # creating the OpenSearch domain publicly.
  dynamic "vpc_options" {
    for_each = var.vpc_enabled ? [1] : []
    content {
      security_group_ids = concat([aws_security_group.opensearch_sg.id], var.additional_security_group_ids)
      subnet_ids         = var.subnet_ids
    }
  }

  # The current configuration with Principal = { AWS = "*" } allows any authenticated AWS user or role to access the OpenSearch domain but the policy enforces that the access must be over a secure transport (HTTPS),
  # as specified in the Condition block.
  # Plese refer the documentation for access policies https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearch_domain#access-policy
  # use variable allowed_roles to update the policy with a user role who can access this
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "es:*"
        Effect = "Allow"
        Principal = {
          AWS = var.allowed_roles
        }
        Resource = "arn:aws:es:${var.aws_region}:${var.account_id}:domain/${var.domain_name}/*"
        Condition = var.vpc_enabled ? {
          Bool = {
            "aws:SecureTransport" = "true"
          }
        } : {}
      }
    ]
  })

  # Index and search slow logs are logs generated by OpenSearch (formerly Elasticsearch) to record operations that take longer than a specified threshold. 
  # These logs help identify performance issues and bottlenecks within the OpenSearch cluster

  # Index Slow Logs: These logs record indexing operations that exceed the specified threshold, usually in terms of time taken to process the operation. 
  # Indexing operations involve adding, updating, or deleting documents in the OpenSearch index. By analyzing index slow logs, 
  # you can identify slow indexing operations and investigate potential causes, such as complex mappings, resource constraints, or heavy indexing loads.

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_slow_logs.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  # These logs record search and query operations that exceed the specified threshold, usually in terms of time taken to process the operation.
  # Search operations involve running queries against the OpenSearch index to retrieve documents. By analyzing search slow logs, 
  # you can identify slow search operations and investigate potential causes, such as inefficient queries, resource constraints, or heavy search loads.
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_slow_logs.arn
    log_type                 = "SEARCH_SLOW_LOGS"
  }

  depends_on = [aws_security_group.opensearch_sg]
}

resource "aws_security_group" "opensearch_sg" {
  name        = "${var.domain_name}-sg"
  description = "Security group for OpenSearch domain"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rule
    content {
      description      = ingress.value["description"]
      from_port        = ingress.value["from_port"]
      to_port          = ingress.value["to_port"]
      protocol         = ingress.value["protocol"]
      cidr_blocks      = ingress.value["cidr_blocks"]
      ipv6_cidr_blocks = ingress.value["ipv6_cidr_blocks"]
    }
  }

  dynamic "egress" {
    for_each = var.egress_rule
    content {
      description      = egress.value["description"]
      from_port        = egress.value["from_port"]
      to_port          = egress.value["to_port"]
      protocol         = egress.value["protocol"]
      cidr_blocks      = egress.value["cidr_blocks"]
      ipv6_cidr_blocks = egress.value["ipv6_cidr_blocks"]
    }
  }

  tags = var.tags
}
