project  = "secureops"
env      = "staging"
region   = "ap-south-1"
az_count = 2

eks_version         = "1.32"
node_instance_types = ["t3.small"]
node_min_size       = 2
node_max_size       = 4
# NOTE: upstream EKS module ignores desired_size after creation
# (lifecycle ignore_changes for autoscaler compat). Change node count via:
# aws eks update-nodegroup-config --cluster-name secureops-staging \
#   --nodegroup-name <name> --scaling-config minSize=2,maxSize=4,desiredSize=N
node_desired_size   = 3

db_instance_class = "db.t3.micro"
domain_name       = ""
github_repo = "<GITHUB_OWNER>/<GITHUB_REPO>"
