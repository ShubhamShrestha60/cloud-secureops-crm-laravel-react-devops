# Remote state: create the bucket + lock table once (outside this stack),
# then uncomment and fill in. Do NOT commit real bucket names with secrets —
# bucket name itself is fine, it holds state not app secrets.
#
terraform {
  backend "s3" {
    bucket         = "secureops-tfstate-<ACCOUNT_ID>"
    key            = "secureops/eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "secureops-terraform-locks"
    encrypt        = true
  }
}
# Bootstrap (one time, with admin creds):
#   aws s3 mb s3://secureops-terraform-state-<account-id> --region ap-south-1
#   aws dynamodb create-table --table-name secureops-terraform-locks \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region ap-south-1
