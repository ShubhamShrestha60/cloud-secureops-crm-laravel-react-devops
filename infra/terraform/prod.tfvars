project  = "secureops"
env      = "prod"
region   = "ap-south-1"
az_count = 3

eks_version         = "1.32"
node_instance_types = ["t3.medium"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2

db_instance_class = "db.t3.small"
domain_name       = ""
# github_repo = "OWNER/secureopsCRM_laravel-react_devops"
