# This is a simple VPC to place ec2s. It's just one big public
# subnet with an internet gateway.

# !! 
# NOT SECURE! It should not be used in production accounts or for production
# workloads. It is for demonstration purposes in lower environments only.
# !!


# big flat public VPC for windows VMs
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "fcc-hello-world-demo-vpc"

  azs            = ["us-east-1a"]
  cidr           = "10.0.0.0/16"
  public_subnets = ["10.0.1.0/25"]

  create_igw = true

  # allow outbound access to internet
  default_security_group_egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  # allow rdp and ssh
  default_security_group_ingress = [
    {
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_vpn_gateway = false
  enable_flow_log    = false

}




# IAM instance profile stuff for session manager
# All the ec2 created by the factory will use the same instance profile
resource "aws_iam_role" "instance_role" {
  name = "fcc-hello-world-demo-ec2-role"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "ec2.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2readS3Allow" {
  name = "Ec2ReadS3Allow"
  role = aws_iam_role.instance_role.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect": "Allow",
        "Action": [
          "s3:ListBucket",
          "s3:GetObject"
        ],
        "Resource": [
          "arn:aws:s3:::fcc-demo-hello-world-artifacts",
          "arn:aws:s3:::fcc-demo-hello-world-artifacts/*"
        ]
      }    ]
  })

}

resource "aws_iam_instance_profile" "instance_profile" {
  name = "fcc-hello-world-demo-instance-profile"
  role = aws_iam_role.instance_role.name
}


resource "aws_iam_role_policy_attachment" "combined" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.instance_role.name
}


# Key pair for the ec2 instances
# this will be shared by devs for the windows instances
module "key_pair" {
  source = "terraform-aws-modules/key-pair/aws"

  key_name           = "fcc-demo-hello-world-key"
  create_private_key = true
}


# OIDC provider and role that will trust certain repositories
# from exampleco. This will enable the hello world product's github
# actions to leverage the ec2 factory and to add SSM documents

module "iam_github_oidc_provider" {
  source = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
}



module "iam_github_oidc_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"

  name = "@fcc-demo-role"

  # Note the audience will allow any repo in ExampleCoDept github org
  # that starts with fcc-demo-hello-world- to assume the role
  #
  # That is intentional so that forked repositories by new developers
  # can deploy to AWS without IAM/SAML credentials.
  subjects = ["ExampleCoDept/fcc-demo-*:*"]

  policies = {
    DenyRoleJumps = aws_iam_policy.deny_role_jumping.arn
    AllowS3Write  = aws_iam_policy.allow_s3_write.arn
    AllowSSMRead  = aws_iam_policy.allow_ssm_read.arn
    AllowEC2Manage = aws_iam_policy.allow_ec2_manage.arn
  }
}

# This prevents github/oidc from assuming a next role, "role jumping" or "role chaining" or "role hopping"
resource "aws_iam_policy" "deny_role_jumping" {
  name        = "DenyRoleJumps"
  path        = "/"
  description = "Deny role jumping/chaining"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "OidcSafety",
        "Effect" : "Deny",
        "Action" : "sts:AssumeRole",
        "Resource" : "*"
      }
    ]
  })
}


############################################################################################################
# S3 bucket to store hellow-world .NET artifacts
############################################################################################################

module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"
  bucket = "fcc-demo-hello-world-artifacts"
  versioning    = { enabled = false }
  force_destroy = true
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  lifecycle_rule = [
    {
      id      = "expire-30-days"
      enabled = true
      prefix  = ""
      tags    = {
        "expire" = "true"
      }
      expiration = {
        days = 30
      }
    }
  ]  
}



resource "aws_iam_policy" "allow_s3_write" {
  name        = "AllowS3Write"
  path        = "/"
  description = "Allow OIDC role to write to fcc artifact and tf remote state s3 buckets"

  policy = jsonencode({
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowS3Write",
			"Effect": "Allow",
			"Action": [
				"s3:ListBucket",
				"s3:GetObject",
				"s3:PutObject",
        "s3:DeleteObject"
			],
			"Resource": [
        "arn:aws:s3:::fcc-demo-hello-world-artifacts",
        "arn:aws:s3:::fcc-demo-hello-world-artifacts/*",
        "aarn:aws:s3:::terraform-remote-state-12345678901-us-east-1",
        "aarn:aws:s3:::terraform-remote-state-12345678901-us-east-1/*"
      ]
		}
	]

  })

}




############################################################################################################
# Use SSM parameters to pass information to the ec2 factory (instead of remote terraform state outputs)
############################################################################################################

resource "aws_iam_policy" "allow_ssm_read" {
  name        = "allow_ssm_read"
  path        = "/"
  description = "Allow OIDC role to read SSM parameters"

  policy = jsonencode({
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowSSMRead",
			"Effect": "Allow",
			"Action": [
				"ssm:GetParameters",
				"ssm:GetParameter"
			],
			"Resource": "*"
		}
	]

  })
}

resource "aws_ssm_parameter" "subnet_id" {
  name           = "/fcc-demo/hello-world/subnet-id"
  type           = "String"
  insecure_value = module.vpc.public_subnets[0]
  description    = "Subnet ID to be used by the ec2 factory to place instances"
}

resource "aws_ssm_parameter" "securitygroup_id" {
  name           = "/fcc-demo/hello-world/securitygroup-id"
  type           = "String"
  insecure_value = module.vpc.default_security_group_id
  description    = "Security Group ID to be used by the ec2 factory to allow RDP connections"
}

resource "aws_ssm_parameter" "instance_profile_name" {
  name           = "/fcc-demo/hello-world/instance-profile-name"
  type           = "String"
  insecure_value = aws_iam_instance_profile.instance_profile.name
  description    = "Instance profile for ec2 role"
}

resource "aws_ssm_parameter" "ec2_private_key" {
  name           = "/fcc-demo/hello-world/private-key"
  type           = "SecureString"
  value = module.key_pair.private_key_pem
  description    = "PEM private key for ec2 instances"
}



# permissions needed to do ec2
# rpc.method=DescribeInstanceAttribute
# rpc.method=DescribeInstanceCreditSpecifications
# rpc.method=DescribeInstanceTypes
# rpc.method=DescribeInstances
# rpc.method=DescribeTags
# rpc.method=DescribeVolumes
# rpc.method=DescribeVpcs
# rpc.method=RunInstances
# rpc.method=ModifyInstanceAttribute
# rpc.method=TerminateInstances

resource "aws_iam_policy" "allow_ec2_manage" {
  name        = "AllowEC2Manage"
  path        = "/"
  description = "Allow OIDC role to manage ec2 instances"

  policy = jsonencode({
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowEC2Manage",
			"Effect": "Allow",
			"Action": [
        "ec2:DescribeInstanceAttribute",
        "ec2:DescribeInstanceCreditSpecifications",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVpcs",
        "ec2:RunInstances",
        "ec2:ModifyInstanceAttribute",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "iam:PassRole"

      ],
			"Resource": "*"
		}
  ],

  })

}