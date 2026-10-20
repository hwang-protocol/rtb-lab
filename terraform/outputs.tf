output "vpc_id" { value = aws_vpc.main.id }
output "availability_zone" { value = local.az }
output "public_subnet_id" { value = aws_subnet.public.id }
output "private_subnet_id" { value = aws_subnet.private.id }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "security_groups" {
  value = {
    bidder     = aws_security_group.bidder.id
    loadgen    = aws_security_group.loadgen.id
    monitoring = aws_security_group.monitoring.id
  }
}
output "instance_profiles" {
  value = { for k, p in aws_iam_instance_profile.host : k => p.name }
}
