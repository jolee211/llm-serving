#!/usr/bin/env bash
# Fast tripwire for the actual failure mode: resources left running after a session.
# Billing alarms lag 8-24h; this is immediate. Exits 1 with a report if anything is up.
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

INST=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running,pending \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output text)
CLUS=$(aws eks list-clusters --query 'clusters[]' --output text)
EFS=$(aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text)

if [ -z "$INST$CLUS$EFS" ]; then
  echo "clean: no instances, clusters, or filesystems"
  exit 0
fi

echo "STILL RUNNING:"
[ -n "$INST" ] && echo "  instances:" && echo "$INST" | sed 's/^/    /'
[ -n "$CLUS" ] && echo "  clusters:   $CLUS"
[ -n "$EFS"  ] && echo "  filesystems: $EFS"
echo
echo "Estimated burn if this is the usual lab shape:"
echo "  g5.xlarge  ~\$1.01/hr   = ~\$24/day"
echo "  EKS + CPU  ~\$0.18/hr   = ~\$4.40/day"
echo
echo "Tear down with: ~/llm-serving/teardown-cluster.sh"
exit 1
