#!/usr/bin/env bash
# Full teardown for the ephemeral llm-serving lab.
# Order matters: EFS mount target ENIs live in the cluster subnets and will
# block the CloudFormation subnet delete if the filesystem is removed after.
set -uo pipefail

CLUSTER=llm-serving
export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "=== 1/4 cluster"
eksctl delete cluster --name "$CLUSTER" 2>&1 | tail -3

echo "=== 2/4 EFS (mount targets, then filesystem)"
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

echo "=== 3/4 EFS security group"
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=efs-llm-serving \
      --query 'SecurityGroups[].GroupId' --output text)
[ -n "$SG" ] && aws ec2 delete-security-group --group-id "$SG" && echo "  deleted $SG"

echo "=== 4/4 retry cluster stack if it failed on subnet dependencies"
if aws cloudformation describe-stacks --stack-name "eksctl-$CLUSTER-cluster" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "eksctl-$CLUSTER-cluster"
  until ! aws cloudformation describe-stacks --stack-name "eksctl-$CLUSTER-cluster" >/dev/null 2>&1; do sleep 15; done
  echo "  cluster stack deleted"
fi

echo "=== verify (all four should be empty)"
echo "clusters:  $(aws eks list-clusters --output text)"
echo "instances: $(aws ec2 describe-instances --filters Name=instance-state-name,Values=running,pending \
                   --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "efs:       $(aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text)"
echo "volumes:   $(aws ec2 describe-volumes --query 'Volumes[].VolumeId' --output text)"
