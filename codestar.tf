# -------------------------------------------------------------------
# CodeStar Connection (GitHub)
# -------------------------------------------------------------------

resource "aws_codestarconnections_connection" "github" {
  name          = "${local.name_prefix}-github"
  provider_type = "GitHub"
}
