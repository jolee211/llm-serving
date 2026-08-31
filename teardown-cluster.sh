#!/usr/bin/env bash
# Full teardown for the ephemeral llm-serving lab.
#
# Order matters, and it is not the obvious order:
#   1. EFS first. Its mount target ENIs live in the cluster subnets and block
#      the CloudFormation subnet delete.
#   2. The EFS security group must also go BEFORE the cluster delete. Its
#      ingress rule references the EKS cluster SG, which stops EKS from
#      cleaning that SG up, which then orphans it and blocks the VPC delete.
#   3. Only then delete the cluster.
set -uo pipefail

CLUSTER=llm-serving
export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "=== 1/4 EFS (mount targets, then filesystem)"
for fs in $(aws efs describe-file-systems \
      --query "FileSystems[?Name=='llm-serving-hf-cache'].FileSystemId" --output text); do
  for mt in $(aws efs describe-mount-targets --file-system-id "$fs" \
        --query 'MountTargets[].MountTargetId' --output text); do
    echo "  deleting mount target $mt"
    aws efs delete-mount-target --mount-target-id "$mt"
  done
  until [ -z "$(aws efs describe-mount-targets --file-system-id "$fs" \
        --query 'MountTargets[].MountTargetId' --output text 2>/dev/null)" ]; do sleep 10; done
  aws efs delete-file-system --file-system-id "$fs" && echo "  deleted filesystem $fs"
done

echo "=== 2/4 EFS security group (before the cluster, see header)"
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=efs-llm-serving \
      --query 'SecurityGroups[].GroupId' --output text)
[ -n "$SG" ] && aws ec2 delete-security-group --group-id "$SG" && echo "  deleted $SG"

echo "=== 3/4 cluster"
eksctl delete cluster --name "$CLUSTER" 2>&1 | tail -3

echo "=== 4/4 sweep any orphaned cluster SG, then retry the stack if it failed"
if aws cloudformation describe-stacks --stack-name "eksctl-$CLUSTER-cluster" >/dev/null 2>&1; then
  for sg in $(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=eks-cluster-sg-$CLUSTER-*" \
        --query 'SecurityGroups[].GroupId' --output text); do
    echo "  deleting orphaned $sg"; aws ec2 delete-security-group --group-id "$sg"
  done
  aws cloudformation delete-stack --stack-name "eksctl-$CLUSTER-cluster"
  until ! aws cloudformation describe-stacks --stack-name "eksctl-$CLUSTER-cluster" >/dev/null 2>&1; do sleep 15; done
  echo "  cluster stack deleted"
fi

echo "=== verify (every line must be empty)"
echo "clusters:  [$(aws eks list-clusters --output text)]"
echo "instances: [$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running,pending \
                   --query 'Reservations[].Instances[].InstanceId' --output text)]"
echo "efs:       [$(aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text)]"
echo "volumes:   [$(aws ec2 describe-volumes --query 'Volumes[].VolumeId' --output text)]"
echo "vpcs:      [$(aws ec2 describe-vpcs --filters Name=is-default,Values=false --query 'Vpcs[].VpcId' --output text)]"
