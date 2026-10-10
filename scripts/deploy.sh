#!/usr/bin/env bash
set -euo pipefail

if [ -z "${STUDENT_SUFFIX:-}" ]; then
  echo "ERROR: STUDENT_SUFFIX is not set."
  echo "Set STUDENT_SUFFIX with your IAM username to namespace resources."
  exit 1
fi

APP_NAME="${APP_NAME:-greeting}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT_VOLUME_SIZE="${ROOT_VOLUME_SIZE:-30}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

FULL_APP_NAME="${APP_NAME}-${STUDENT_SUFFIX}"
CLUSTER_NAME="cluster-${STUDENT_SUFFIX}"
SERVICE_NAME="service-${FULL_APP_NAME}"
TASK_FAMILY="task-${FULL_APP_NAME}"
ASG_NAME="asg-${STUDENT_SUFFIX}"
LT_NAME="lt-${STUDENT_SUFFIX}"
CP_NAME="cp-${STUDENT_SUFFIX}"
SG_NAME="secgroup-${FULL_APP_NAME}"
INSTANCE_ROLE_NAME="ecs-instance-role-${STUDENT_SUFFIX}"
INSTANCE_PROFILE_NAME="ecs-instance-profile-${STUDENT_SUFFIX}"
TASK_EXECUTION_ROLE_NAME="ecs-task-execution-role-${STUDENT_SUFFIX}"
ECR_REPO_NAME="greeting-${STUDENT_SUFFIX}"

echo "=================================================="
echo "Deploying container application for: ${STUDENT_SUFFIX}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Service: ${SERVICE_NAME}"
echo "Root Volume Size: ${ROOT_VOLUME_SIZE} GiB"
echo "=================================================="

# 1. Resolve Account ID & Image URI
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
IMAGE_URI="${IMAGE_URI:-${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}}"
echo "Using Container Image: ${IMAGE_URI}"

# 2. Get Default VPC & Subnets
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
if [ -z "$DEFAULT_VPC_ID" ] || [ "$DEFAULT_VPC_ID" = "None" ]; then
  DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
fi
echo "VPC: ${DEFAULT_VPC_ID}"

SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${DEFAULT_VPC_ID}" --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

# 3. Security Group (Idempotent)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${DEFAULT_VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  echo "Creating security group ${SG_NAME}..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SG_NAME}" \
    --description "Security group for ${FULL_APP_NAME}" \
    --vpc-id "${DEFAULT_VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=StudentSuffix,Value=${STUDENT_SUFFIX}}]" \
    --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 8000 \
    --cidr 0.0.0.0/0
else
  echo "Security group ${SG_NAME} (${SG_ID}) already exists."
fi

# 4. IAM EC2 Instance Role & Instance Profile (Idempotent)
INSTANCE_ROLE_ARN=$(aws iam get-role --role-name "$INSTANCE_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "")
if [ -z "$INSTANCE_ROLE_ARN" ] || [ "$INSTANCE_ROLE_ARN" = "None" ]; then
  echo "Creating EC2 instance role ${INSTANCE_ROLE_NAME}..."
  INSTANCE_ROLE_ARN=$(aws iam create-role \
    --role-name "$INSTANCE_ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "Key=StudentSuffix,Value=${STUDENT_SUFFIX}" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$INSTANCE_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
else
  echo "EC2 instance role ${INSTANCE_ROLE_NAME} already exists."
fi

if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "Creating instance profile ${INSTANCE_PROFILE_NAME}..."
  aws iam create-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --tags "Key=StudentSuffix,Value=${STUDENT_SUFFIX}"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$INSTANCE_ROLE_NAME"
  echo "Waiting 10 seconds for instance profile propagation..."
  sleep 10
else
  echo "Instance profile ${INSTANCE_PROFILE_NAME} already exists."
fi

# 5. IAM ECS Task Execution Role (Idempotent)
TASK_EXEC_ROLE_ARN=$(aws iam get-role --role-name "$TASK_EXECUTION_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "")
if [ -z "$TASK_EXEC_ROLE_ARN" ] || [ "$TASK_EXEC_ROLE_ARN" = "None" ]; then
  echo "Creating task execution role ${TASK_EXECUTION_ROLE_NAME}..."
  TASK_EXEC_ROLE_ARN=$(aws iam create-role \
    --role-name "$TASK_EXECUTION_ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "Key=StudentSuffix,Value=${STUDENT_SUFFIX}" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$TASK_EXECUTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
else
  echo "Task execution role ${TASK_EXECUTION_ROLE_NAME} already exists."
fi

# 6. ECS Cluster (Idempotent)
echo "Ensuring ECS cluster ${CLUSTER_NAME} exists..."
aws ecs create-cluster \
  --cluster-name "$CLUSTER_NAME" \
  --tags "key=StudentSuffix,value=${STUDENT_SUFFIX}" >/dev/null

# 7. Resolve Amazon Linux 2023 ECS-Optimized AMI
ECS_AMI_ID=$(aws ssm get-parameter --name /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id --query 'Parameter.Value' --output text 2>/dev/null || echo "")
if [ -z "$ECS_AMI_ID" ] || [ "$ECS_AMI_ID" = "None" ]; then
  ECS_AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-ecs-hvm-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text 2>/dev/null || echo "")
fi

if [ -z "$ECS_AMI_ID" ] || [ "$ECS_AMI_ID" = "None" ]; then
  echo "ERROR: Unable to resolve ECS-optimized AMI ID."
  exit 1
fi
echo "Using ECS-optimized AMI: ${ECS_AMI_ID}"

# 8. EC2 Launch Template (Idempotent: create or update version)
USER_DATA_B64=$(printf "#!/bin/bash\necho \"ECS_CLUSTER=%s\" >> /etc/ecs/ecs.config\n" "$CLUSTER_NAME" | base64 -w 0)
LT_DATA='{
  "ImageId": "'"$ECS_AMI_ID"'",
  "InstanceType": "'"$INSTANCE_TYPE"'",
  "IamInstanceProfile": {"Name": "'"$INSTANCE_PROFILE_NAME"'"},
  "SecurityGroupIds": ["'"$SG_ID"'"],
  "UserData": "'"$USER_DATA_B64"'",
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": {
        "VolumeSize": '"$ROOT_VOLUME_SIZE"',
        "VolumeType": "gp3",
        "DeleteOnTermination": true
      }
    }
  ],
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "Name", "Value": "ecs-node-'"$STUDENT_SUFFIX"'"},
        {"Key": "StudentSuffix", "Value": "'"$STUDENT_SUFFIX"'"}
      ]
    }
  ]
}'

if ! aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
  echo "Creating Launch Template ${LT_NAME} (${INSTANCE_TYPE})..."
  aws ec2 create-launch-template \
    --launch-template-name "$LT_NAME" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=StudentSuffix,Value=${STUDENT_SUFFIX}}]" \
    --launch-template-data "$LT_DATA" >/dev/null
else
  echo "Updating Launch Template ${LT_NAME} with latest configuration (${INSTANCE_TYPE})..."
  aws ec2 create-launch-template-version \
    --launch-template-name "$LT_NAME" \
    --launch-template-data "$LT_DATA" >/dev/null
fi

# 9. Auto Scaling Group (Idempotent)
EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null || echo "")
if [ -z "$EXISTING_ASG" ] || [ "$EXISTING_ASG" = "None" ]; then
  echo "Creating Auto Scaling Group ${ASG_NAME} (1 ${INSTANCE_TYPE} instance)..."
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=${LT_NAME},Version=\$Latest" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_IDS" \
    --tags "Key=StudentSuffix,Value=${STUDENT_SUFFIX},PropagateAtLaunch=true"
else
  echo "Auto Scaling Group ${ASG_NAME} already exists."
fi

# 10. Register Auto Scaling Group as Cluster Capacity Provider (Idempotent)
echo "Ensuring Cluster Capacity Provider ${CP_NAME} is registered..."
ASG_ARN=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].AutoScalingGroupARN' \
  --output text)

EXISTING_CP=$(aws ecs describe-capacity-providers \
  --capacity-providers "$CP_NAME" \
  --query 'capacityProviders[?status==`ACTIVE`].name' \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_CP" ] || [ "$EXISTING_CP" = "None" ]; then
  echo "Creating ECS Capacity Provider ${CP_NAME}..."
  aws ecs create-capacity-provider \
    --name "$CP_NAME" \
    --auto-scaling-group-provider "autoScalingGroupArn=${ASG_ARN},managedScaling={status=ENABLED,targetCapacity=100},managedTerminationProtection=DISABLED" \
    --tags "key=StudentSuffix,value=${STUDENT_SUFFIX}" >/dev/null
else
  echo "ECS Capacity Provider ${CP_NAME} already exists."
fi

CLUSTER_CPS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].capacityProviders' --output text 2>/dev/null || echo "")
if ! echo "$CLUSTER_CPS" | grep -qw "$CP_NAME"; then
  echo "Associating Capacity Provider ${CP_NAME} with cluster ${CLUSTER_NAME}..."
  aws ecs put-cluster-capacity-providers \
    --cluster "$CLUSTER_NAME" \
    --capacity-providers "$CP_NAME" \
    --default-capacity-provider-strategy "capacityProvider=${CP_NAME},weight=1,base=1" >/dev/null
else
  echo "Capacity Provider ${CP_NAME} already associated with cluster ${CLUSTER_NAME}."
fi

# 11. Register Task Definition (Always register latest revision)
echo "Registering Task Definition ${TASK_FAMILY} with image ${IMAGE_URI}..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --family "$TASK_FAMILY" \
  --network-mode "bridge" \
  --requires-compatibilities "EC2" \
  --cpu "256" \
  --memory "256" \
  --execution-role-arn "$TASK_EXEC_ROLE_ARN" \
  --tags "key=StudentSuffix,value=${STUDENT_SUFFIX}" \
  --container-definitions '[{
    "name": "greeting-app",
    "image": "'"$IMAGE_URI"'",
    "cpu": 256,
    "memory": 256,
    "essential": true,
    "portMappings": [{
      "containerPort": 8000,
      "hostPort": 8000,
      "protocol": "tcp"
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/'"$FULL_APP_NAME"'",
        "awslogs-region": "'"$AWS_REGION"'",
        "awslogs-stream-prefix": "ecs",
        "awslogs-create-group": "true"
      }
    }
  }]' --query 'taskDefinition.taskDefinitionArn' --output text)

# 12. ECS Service (Idempotent: create if missing, force update if exists)
EXISTING_SERVICE=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null || echo "")
if [ -n "$EXISTING_SERVICE" ] && [ "$EXISTING_SERVICE" != "None" ]; then
  echo "Updating existing ECS Service ${SERVICE_NAME} with latest Task Definition..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --force-new-deployment >/dev/null
else
  echo "Creating ECS Service ${SERVICE_NAME}..."
  aws ecs create-service \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --desired-count 1 \
    --capacity-provider-strategy "capacityProvider=${CP_NAME},weight=1,base=1" \
    --tags "key=StudentSuffix,value=${STUDENT_SUFFIX}" >/dev/null
fi

echo "=================================================="
echo "Deployment initiated successfully!"

# 13. Retrieve EC2 Instance Public IP for URL verification
echo "Locating EC2 instance public IP..."
INSTANCE_ID=""
for i in {1..12}; do
  INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "")
  if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    break
  fi
  sleep 5
done

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "")
  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ]; then
    echo "EC2 Instance Public IP: ${PUBLIC_IP}"
    echo "App URL: http://${PUBLIC_IP}:8000/"
    echo "Health Check: http://${PUBLIC_IP}:8000/health"
    echo "Personalized Greeting: http://${PUBLIC_IP}:8000/?first_name=John&last_name=Doe"
  else
    echo "Instance launched (${INSTANCE_ID}), public IP pending assignment."
  fi
else
  echo "Auto Scaling Group instance is currently provisioning."
fi
echo "=================================================="
