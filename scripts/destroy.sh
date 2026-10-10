#!/usr/bin/env bash
set -euo pipefail

STUDENT_SUFFIX="${1:-${STUDENT_SUFFIX:-}}"
if [ -z "$STUDENT_SUFFIX" ]; then
  echo "ERROR: Student suffix must be provided as argument or STUDENT_SUFFIX env var."
  echo "Usage: $0 <student_suffix>"
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="${APP_NAME:-greeting}"
FULL_APP_NAME="${APP_NAME}-${STUDENT_SUFFIX}"
CLUSTER_NAME="cluster-${STUDENT_SUFFIX}"
SERVICE_NAME="service-${FULL_APP_NAME}"
ASG_NAME="asg-${STUDENT_SUFFIX}"
LT_NAME="lt-${STUDENT_SUFFIX}"
CP_NAME="cp-${STUDENT_SUFFIX}"
SG_NAME="secgroup-${FULL_APP_NAME}"
INSTANCE_ROLE_NAME="ecs-instance-role-${STUDENT_SUFFIX}"
INSTANCE_PROFILE_NAME="ecs-instance-profile-${STUDENT_SUFFIX}"
TASK_EXECUTION_ROLE_NAME="ecs-task-execution-role-${STUDENT_SUFFIX}"
ECR_REPO_NAME="greeting-${STUDENT_SUFFIX}"

echo "=================================================="
echo "Destroying all infrastructure for suffix: ${STUDENT_SUFFIX}"
echo "=================================================="

# 1. Scale down and delete ECS service
if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
  echo "Scaling down and deleting ECS service ${SERVICE_NAME}..."
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 0 >/dev/null 2>&1 || true
  aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --force >/dev/null 2>&1 || true
fi

# Disassociate capacity providers from the cluster and clean up custom providers referencing this ASG
aws ecs put-cluster-capacity-providers --cluster "$CLUSTER_NAME" --capacity-providers [] --default-capacity-provider-strategy [] >/dev/null 2>&1 || true
if aws ecs describe-capacity-providers --capacity-providers "$CP_NAME" --query 'capacityProviders[?status==`ACTIVE`].name' --output text 2>/dev/null | grep -q "$CP_NAME"; then
  echo "Deleting capacity provider ${CP_NAME}..."
  aws ecs delete-capacity-provider --capacity-provider "$CP_NAME" >/dev/null 2>&1 || true
fi
CAP_NAMES=$(aws ecs describe-capacity-providers --query 'capacityProviders[?contains(autoScalingGroupProvider.autoScalingGroupArn, `'"$ASG_NAME"'`)].name' --output text 2>/dev/null || echo "")
if [ -n "$CAP_NAMES" ] && [ "$CAP_NAMES" != "None" ]; then
  for cp in $CAP_NAMES; do
    echo "Deleting capacity provider ${cp}..."
    aws ecs delete-capacity-provider --capacity-provider "$cp" >/dev/null 2>&1 || true
  done
fi

# 2. Force delete Auto Scaling Group
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -q "$ASG_NAME"; then
  echo "Force deleting Auto Scaling Group ${ASG_NAME}..."
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete >/dev/null 2>&1 || true
fi

# 3. Wait for associated EC2 instances to terminate
echo "Waiting for EC2 instances to terminate..."
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:StudentSuffix,Values=${STUDENT_SUFFIX}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo "")
if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
  for id in $INSTANCE_IDS; do
    echo "Waiting for instance $id..."
    aws ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || true
  done
fi

# 4. Delete ECS Cluster
if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[?status==`ACTIVE`].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "Deleting ECS cluster ${CLUSTER_NAME}..."
  aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
fi

# 5. Delete Launch Template
if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
  echo "Deleting Launch Template ${LT_NAME}..."
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null 2>&1 || true
fi

# 6. Delete Security Group (with retries for network interface detach)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  echo "Deleting security group ${SG_NAME} (${SG_ID})..."
  for i in {1..6}; do
    if aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1; then
      echo "Security group deleted."
      break
    fi
    sleep 5
  done
fi

# 7. Delete IAM Instance Profile & Roles
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "Deleting instance profile ${INSTANCE_PROFILE_NAME}..."
  aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$INSTANCE_ROLE_NAME" >/dev/null 2>&1 || true
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1 || true
fi

if aws iam get-role --role-name "$INSTANCE_ROLE_NAME" >/dev/null 2>&1; then
  echo "Deleting IAM role ${INSTANCE_ROLE_NAME}..."
  aws iam detach-role-policy --role-name "$INSTANCE_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$INSTANCE_ROLE_NAME" >/dev/null 2>&1 || true
fi

if aws iam get-role --role-name "$TASK_EXECUTION_ROLE_NAME" >/dev/null 2>&1; then
  echo "Deleting IAM role ${TASK_EXECUTION_ROLE_NAME}..."
  aws iam detach-role-policy --role-name "$TASK_EXECUTION_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$TASK_EXECUTION_ROLE_NAME" >/dev/null 2>&1 || true
fi

# 8. Delete ECR Repository
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1; then
  echo "Deleting ECR repository ${ECR_REPO_NAME}..."
  aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force >/dev/null 2>&1 || true
fi

# 9. Clean up CloudWatch Log Group
LOG_GROUP="/ecs/${FULL_APP_NAME}"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  echo "Deleting CloudWatch log group ${LOG_GROUP}..."
  aws logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true
fi

# 10. Clean up legacy Lambda & Role if existing
LAMBDA_NAME="greeting-${STUDENT_SUFFIX}"
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  echo "Deleting legacy lambda ${LAMBDA_NAME}..."
  aws lambda delete-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1 || true
fi

LAMBDA_ROLE="greeting-lambda-execution-role-${STUDENT_SUFFIX}"
if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  echo "Deleting legacy lambda execution role ${LAMBDA_ROLE}..."
  aws iam detach-role-policy --role-name "$LAMBDA_ROLE" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1 || true
fi

echo "=================================================="
echo "Infrastructure cleanup complete for suffix: ${STUDENT_SUFFIX}"
echo "=================================================="
