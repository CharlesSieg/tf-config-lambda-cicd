# Lambda CI/CD Pipeline: Terraform

Terraform configuration for deploying a production CI/CD pipeline for containerized AWS Lambda functions.

## Architecture

```
GitHub → CodeStar Connection → CodePipeline → CodeBuild → ECR → CodeDeploy → Lambda
```

This pipeline automates the full lifecycle of a containerized Lambda function. A push to GitHub triggers CodePipeline, which delegates to CodeBuild to build and push a Docker image to ECR, then hands off to CodeDeploy to shift traffic to the new version using a canary deployment strategy. A CloudWatch error alarm monitors the canary window and triggers an automatic rollback if the new version produces errors.

## Design Decisions

### Why CodePipeline V2 with QUEUED Execution

The pipeline uses a V2 pipeline with QUEUED execution mode. SUPERSEDED (V1) cancels in-progress deployments when a new commit arrives, which can leave a Lambda alias in an inconsistent state with partial traffic routing mid-shift. QUEUED mode ensures each deployment completes fully, including the CodeDeploy canary window, before the next begins. This is essential for any pipeline that includes traffic-shifting deployments.

### Why CodeStar Connections Over OAuth Tokens

CodeStar Connections use an AWS-managed GitHub App installed in your GitHub organization, replacing the older OAuth-based integration that relied on personal access tokens. The benefits include push-based event detection (no polling), fine-grained repository-level access control, and no token rotation burden. The one-time manual activation in the AWS Console is a deliberate security measure. AWS requires explicit authorization before accessing your repositories.

### Why Immutable ECR Tags

The ECR repository enforces immutable tags, meaning once an image is pushed with a given tag, that tag permanently refers to that exact image digest. Immutable tags eliminate a class of deployment bugs where `latest` silently points to a different image than what was tested. The pipeline tags images with the Git commit hash, providing full traceability from a running Lambda version back to the exact source commit.

### Why CodeDeploy Canary Over AllAtOnce

AllAtOnce deployments shift 100% of traffic immediately to the new version, so a bug in the new version affects every request. Canary10Percent5Minutes shifts only 10% of traffic initially and holds for 5 minutes while the CloudWatch error alarm evaluates. If the alarm fires, CodeDeploy reverts the alias to the previous version automatically. The 90% of traffic on the previous version remains unaffected. This is the single most important safety mechanism in the pipeline.

### Why a Separate Error Alarm for Rollback

The CloudWatch metric alarm monitors the Lambda function's `Errors` metric with a threshold of zero and a 60-second evaluation period. This is deliberately sensitive; in a canary window, even a single error warrants investigation. The alarm is associated with the CodeDeploy deployment group's alarm configuration, so CodeDeploy reads the alarm state during the canary window and triggers rollback automatically. You can adjust the threshold based on your function's baseline error rate, but starting at zero forces clean deployments.

### Why `lifecycle { ignore_changes }` on the Lambda Alias

Terraform creates the Lambda alias "live," and CodeDeploy manages it afterward. Without `lifecycle { ignore_changes = [function_version] }`, every `terraform apply` would reset the alias to the initially deployed version, undoing whatever version CodeDeploy has promoted. This annotation establishes a clear ownership boundary: Terraform creates the alias; CodeDeploy manages which version it points to.

## Resources Created

| Resource | File | Purpose |
|----------|------|---------|
| **ECR Repository** | `ecr.tf` | Container image storage with immutable tags, scan-on-push, lifecycle policy (keep last 10) |
| **S3 Bucket** | `s3.tf` | Pipeline artifact storage with versioning and AES256 encryption |
| **CodeBuild Project** | `codebuild.tf` | Docker image build with privileged mode, ECR push, `imageDetail.json` output |
| **CodePipeline** | `codepipeline.tf` | V2 pipeline with 3 stages: Source (CodeStar), Build (CodeBuild), Deploy (CodeDeploy) |
| **CodeDeploy App + Group** | `lambda.tf` | Lambda deployment with Canary10Percent5Minutes and alarm-based rollback |
| **Lambda Function + Alias** | `lambda.tf` | Container image function with "live" alias for traffic shifting |
| **CloudWatch Log Group** | `cloudwatch.tf` | Lambda execution logs with 14-day retention |
| **CloudWatch Alarm** | `cloudwatch.tf` | Error alarm (Errors > 0) as CodeDeploy rollback trigger |
| **IAM Roles (4)** | `iam.tf` | Least-privilege roles for CodeBuild, CodePipeline, Lambda, CodeDeploy |
| **CodeStar Connection** | `codestar.tf` | GitHub integration (requires manual console activation) |

## IAM Architecture

The pipeline uses four IAM roles, each scoped to the minimum permissions required:

| Role | Trust Principal | Key Permissions |
|------|-----------------|-----------------|
| **CodeBuild** | `codebuild.amazonaws.com` | ECR push/pull (scoped to repo), S3 artifact read/write (scoped to bucket), CloudWatch Logs |
| **CodePipeline** | `codepipeline.amazonaws.com` | S3 artifacts, CodeBuild start, CodeDeploy create deployment, CodeStar connection use, Lambda invoke, IAM PassRole for CodeDeploy |
| **Lambda Execution** | `lambda.amazonaws.com` | `AWSLambdaBasicExecutionRole` managed policy; extend with your application-specific permissions |
| **CodeDeploy** | `codedeploy.amazonaws.com` | `AWSCodeDeployRoleForLambda` managed policy (Lambda alias management, CloudWatch alarm read) |

All roles include `aws:SourceAccount` conditions on trust policies where supported, preventing confused deputy attacks from other accounts.

## File Structure

```
tf-config-lambda-cicd/
├── versions.tf          # Terraform and provider version constraints
├── providers.tf         # AWS provider with default tags
├── variables.tf         # Input variables with validation blocks
├── locals.tf            # Computed values: name_prefix, account_id, ECR URI, tags
├── outputs.tf           # Pipeline ARN, ECR URL, Lambda ARN/name, CodeDeploy names
├── ecr.tf               # ECR repository + lifecycle policy
├── s3.tf                # Pipeline artifact bucket
├── iam.tf               # 4 IAM roles with least-privilege policies
├── codestar.tf          # GitHub CodeStar connection
├── codebuild.tf         # CodeBuild project
├── codepipeline.tf      # V2 pipeline with 3 stages
├── lambda.tf            # Lambda function, alias, CodeDeploy app + deployment group
├── cloudwatch.tf        # Log group + error alarm
└── example/
    ├── app.py           # Sample Lambda handler
    ├── requirements.txt # Python dependencies
    ├── Dockerfile       # Container image definition
    └── buildspec.yml    # CodeBuild build specification
```

## Prerequisites

1. An AWS account with appropriate permissions
2. Terraform >= 1.6 and AWS provider ~> 5.0
3. A GitHub repository containing a Dockerfile and buildspec.yml

## Bootstrap Sequence

The pipeline has a circular dependency on first deployment. CodeDeploy requires a Lambda function with a published version. The Lambda function requires a container image in ECR. ECR is empty until CodeBuild runs. CodeBuild only runs after the pipeline exists.

1. Run `terraform apply`. ECR and IAM roles create successfully; Lambda may fail because no image exists yet.
2. Build and push an initial image to ECR:
   ```bash
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
   docker build -t ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/PROJECT-ENV-lambda:initial example/
   docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/PROJECT-ENV-lambda:initial
   ```
3. Run `terraform apply` again. Lambda and all remaining resources create successfully.
4. Activate the CodeStar Connection in the AWS Console under **Developer Tools → Connections**

After this one-time bootstrap, every push to the configured branch triggers the full automated pipeline.

## Usage

```bash
terraform init
terraform plan -var="project_name=myapp" -var="github_repo_owner=MyOrg" -var="github_repo_name=my-lambda"
terraform apply -var="project_name=myapp" -var="github_repo_owner=MyOrg" -var="github_repo_name=my-lambda"
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `project_name` | (required) | Project name used as prefix for all resource names |
| `environment` | `dev` | Environment name (dev, staging, prod): validated |
| `aws_region` | `us-east-1` | AWS region for all resources |
| `github_repo_owner` | (required) | GitHub repository owner or organization |
| `github_repo_name` | (required) | GitHub repository name |
| `github_branch` | `main` | Branch that triggers the pipeline |
| `lambda_memory_size` | `256` | Lambda memory in MB (128-10240): validated |
| `lambda_timeout` | `30` | Lambda timeout in seconds (1-900): validated |
| `lambda_architecture` | `x86_64` | Lambda CPU architecture (x86_64, arm64): validated |

## Cost Estimate

| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| CodePipeline V2 | ~$0.50-2.00 | $0.002 per action execution minute |
| CodeBuild (small) | ~$1.00-10.00 | $0.005/min; Docker builds typically 2-5 min |
| ECR storage | ~$0.10-1.00 | $0.10/GB/month; 10 images at ~200 MB |
| S3 artifacts | <$0.10 | Minimal storage |
| CloudWatch | <$0.50 | Log group + metric alarm |
| CodeDeploy | $0.02/deploy | Per-deployment charge for Lambda |
| **Total pipeline** | **~$2-15/month** | Excludes Lambda compute (your application cost) |

## Extending the Pipeline

Common modifications:

- **Add a test stage.** Insert a CodeBuild action between Build and Deploy that runs your test suite against the newly built image.
- **Add manual approval.** Insert a Manual Approval action before Deploy for human sign-off on production deployments.
- **Multiple environments.** Use Terraform workspaces or separate variable files to deploy dev/staging/prod pipelines from the same configuration.
- **Cross-account deployment.** Add cross-account IAM roles and modify the CodeDeploy action to assume a role in the target account.
- **Notifications.** Add an SNS topic and CodePipeline notification rule for Slack/email alerts on pipeline success or failure.

## Related

- [Pulumi implementation](https://github.com/CharlesSieg/pul-py-config-lambda-cicd)
- [Architecture article](https://charlessieg.com/articles/aws-lambda-container-cicd-pipeline-architecture.html)
