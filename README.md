# Lambda CI/CD Pipeline — Terraform

Terraform configuration for deploying a CI/CD pipeline for containerized AWS Lambda functions.

## Architecture

```
GitHub → CodeStar Connection → CodePipeline → CodeBuild → ECR → CodeDeploy → Lambda
```

## Resources Created

- **Amazon ECR** — Container image repository with immutable tags and scan-on-push
- **AWS CodeBuild** — Build project for Docker image builds with ECR push
- **AWS CodePipeline** — V2 pipeline orchestrating source, build, and deploy stages
- **AWS CodeDeploy** — Lambda deployment with Canary10Percent5Minutes traffic shifting
- **AWS Lambda** — Container image function with "live" alias for traffic shifting
- **CloudWatch** — Lambda log group and error alarm for CodeDeploy rollback triggers
- **S3** — Pipeline artifact bucket with versioning and encryption
- **IAM** — Least-privilege roles for CodeBuild, CodePipeline, Lambda, and CodeDeploy
- **CodeStar Connection** — GitHub source integration (requires manual console activation)

## Prerequisites

1. An AWS account with appropriate permissions
2. A GitHub repository containing a Dockerfile and buildspec.yml
3. An initial container image pushed to ECR before first `terraform apply`

## Bootstrap Sequence

CodeDeploy requires an existing Lambda function with a published version. The Lambda function requires a container image in ECR. Therefore:

1. Run `terraform apply` (this will create ECR but Lambda creation may fail)
2. Build and push an initial image to the ECR repository
3. Run `terraform apply` again (Lambda and remaining resources will succeed)

## Usage

```bash
terraform init
terraform plan -var="project_name=myapp" -var="github_repo_owner=MyOrg" -var="github_repo_name=my-lambda"
terraform apply -var="project_name=myapp" -var="github_repo_owner=MyOrg" -var="github_repo_name=my-lambda"
```

After applying, activate the CodeStar Connection in the AWS Console under Developer Tools → Connections.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `project_name` | — | Project name used in resource naming |
| `environment` | `dev` | Environment (dev, staging, prod) |
| `aws_region` | `us-east-1` | AWS region |
| `github_repo_owner` | — | GitHub repository owner |
| `github_repo_name` | — | GitHub repository name |
| `github_branch` | `main` | Branch to trigger pipeline |
| `lambda_memory_size` | `256` | Lambda memory in MB (128–10240) |
| `lambda_timeout` | `30` | Lambda timeout in seconds (1–900) |
| `lambda_architecture` | `x86_64` | Lambda architecture (x86_64, arm64) |

## Related

- [Pulumi implementation](https://github.com/CharlesSieg/pul-py-config-lambda-cicd)
- [Architecture article](https://charlessieg.com/articles/aws-lambda-container-cicd-pipeline-architecture.html)
