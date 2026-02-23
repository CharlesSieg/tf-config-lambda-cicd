# -------------------------------------------------------------------
# Lambda Function
# -------------------------------------------------------------------

resource "aws_lambda_function" "this" {
  function_name = "${local.name_prefix}-lambda"
  role          = aws_iam_role.lambda_execution.arn
  package_type  = "Image"
  image_uri     = local.ecr_image_uri
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  publish       = true

  architectures = [var.lambda_architecture]

  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]
}

# -------------------------------------------------------------------
# Lambda Alias (managed by CodeDeploy)
# -------------------------------------------------------------------

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

# -------------------------------------------------------------------
# CodeDeploy Application
# -------------------------------------------------------------------

resource "aws_codedeploy_app" "lambda" {
  name             = "${local.name_prefix}-lambda"
  compute_platform = "Lambda"
}

# -------------------------------------------------------------------
# CodeDeploy Deployment Group
# -------------------------------------------------------------------

resource "aws_codedeploy_deployment_group" "lambda" {
  app_name               = aws_codedeploy_app.lambda.name
  deployment_group_name  = "${local.name_prefix}-lambda-dg"
  deployment_config_name = "CodeDeployDefault.LambdaCanary10Percent5Minutes"
  service_role_arn       = aws_iam_role.codedeploy.arn

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.lambda_errors.alarm_name]
    enabled = true
  }
}
