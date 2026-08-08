data "external" "git_info" {
  program = ["bash", "${path.module}/scripts/git-info.sh"]
}
