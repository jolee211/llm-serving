#!/usr/bin/env python3
"""Fail-closed, read-only AWS inventory for the personal llm-serving lab."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any, Iterable


PROFILE = "personal"
PIN_FILE = Path.home() / ".aws" / "llm-serving-account.sha256"
AUTH_PATTERNS = (
    "LoginRefreshRequired",
    "ExpiredToken",
    "ExpiredTokenException",
    "RequestExpired",
    "reauthenticate",
)
ID_PATTERN = re.compile(
    r"(?<![A-Za-z0-9])(?:i|vol|snap|eipalloc|eipassoc|eni|nat|vpc|subnet|sg|igw|fsmt|fs|sfr|sir|fleet)-[A-Za-z0-9-]+"
)
ACCOUNT_PATTERN = re.compile(r"(?<!\d)\d{12}(?!\d)")
IP_PATTERN = re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)")


class ScanError(RuntimeError):
    pass


class AuthError(ScanError):
    pass


@dataclass(frozen=True, order=True)
class Finding:
    region: str
    service: str
    state: str
    identifier: str
    detail: str = ""


def redact(text: str) -> str:
    def mask_id(match: re.Match[str]) -> str:
        value = match.group(0)
        prefix, _, suffix = value.partition("-")
        return f"{prefix}-…{suffix[-4:]}"

    text = ACCOUNT_PATTERN.sub("[ACCOUNT-REDACTED]", text)
    text = IP_PATTERN.sub("[IP-REDACTED]", text)
    return ID_PATTERN.sub(mask_id, text)


def safe_name(value: Any) -> str:
    text = str(value or "unknown")
    if "llm-serving" in text.lower() or text in {"personal-lab-monthly"}:
        return redact(text)
    if len(text) <= 4:
        return "[REDACTED]"
    return f"…{re.sub(r'[^A-Za-z0-9._-]', '_', text[-6:])}"


class Aws:
    def __init__(self) -> None:
        configured = os.environ.get("AWS_PROFILE")
        if configured and configured != PROFILE:
            raise AuthError(
                f"AWS_PROFILE is {configured!r}; run with AWS_PROFILE={PROFILE}."
            )
        self.aws_bin = os.environ.get("LLM_SERVING_AWS_BIN", "aws")
        self.env = os.environ.copy()
        self.env["AWS_PROFILE"] = PROFILE
        self.env["AWS_RETRY_MODE"] = "standard"
        self.env["AWS_MAX_ATTEMPTS"] = "2"
        for key in tuple(self.env):
            if key.startswith("AWS_ENDPOINT_URL") or key in {
                "AWS_ACCESS_KEY_ID",
                "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN",
                "AWS_SECURITY_TOKEN",
                "AWS_DEFAULT_PROFILE",
            }:
                self.env.pop(key, None)

    def json(self, service: str, operation: str, *args: str, region: str | None = None) -> Any:
        command = [
            self.aws_bin,
            service,
            operation,
            "--profile",
            PROFILE,
            "--output",
            "json",
            "--no-cli-pager",
            "--cli-connect-timeout",
            "5",
            "--cli-read-timeout",
            "20",
        ]
        if region:
            command.extend(["--region", region])
        command.extend(args)
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                env=self.env,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ScanError(f"{service}.{operation} failed to execute") from exc
        if result.returncode:
            combined = result.stderr + result.stdout
            if any(pattern.lower() in combined.lower() for pattern in AUTH_PATTERNS):
                raise AuthError(f"authentication expired during {service}.{operation}")
            code = re.search(r"\(([A-Za-z0-9._-]+)\)", combined)
            label = code.group(1) if code else f"exit {result.returncode}"
            raise ScanError(f"{service}.{operation} failed: {label}")
        try:
            return json.loads(result.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise ScanError(f"{service}.{operation} returned invalid JSON") from exc


def preflight_and_identity(aws: Aws, needed_hours: int = 4) -> None:
    preflight_bin = os.environ.get("LLM_SERVING_PREFLIGHT_BIN", "aws-preflight")
    result = subprocess.run(
        [preflight_bin, str(needed_hours)],
        capture_output=True,
        text=True,
        env=aws.env,
        timeout=30,
        check=False,
    )
    if result.returncode:
        detail = redact((result.stdout + result.stderr).strip()).splitlines()
        summary = detail[-1] if detail else f"exit {result.returncode}"
        raise AuthError(f"aws-preflight returned {result.returncode}: {summary}")
    identity = aws.json("sts", "get-caller-identity")
    account = str(identity.get("Account", ""))
    if not re.fullmatch(r"\d{12}", account):
        raise AuthError("personal profile returned an invalid account identity")
    if not PIN_FILE.is_file():
        raise AuthError(f"missing account pin: {PIN_FILE}")
    expected = PIN_FILE.read_text(encoding="ascii").strip()
    actual = hashlib.sha256(account.encode("ascii")).hexdigest()
    if not expected or actual != expected:
        raise AuthError("personal profile does not match the pinned lab account")


def values(data: dict[str, Any], key: str) -> list[Any]:
    value = data.get(key, [])
    return value if isinstance(value, list) else []


def add(
    target: list[Finding],
    region: str,
    service: str,
    state: Any,
    identifier: Any,
    detail: str = "",
) -> None:
    target.append(
        Finding(region, service, str(state or "unknown"), safe_name(identifier), redact(detail))
    )


def scan_region(aws: Aws, region: str) -> list[Finding]:
    found: list[Finding] = []

    clusters = values(aws.json("eks", "list-clusters", region=region), "clusters")
    for cluster in clusters:
        description = aws.json("eks", "describe-cluster", "--name", str(cluster), region=region)
        meta = description.get("cluster", {})
        add(found, region, "EKS cluster", meta.get("status"), cluster, f"version={meta.get('version', 'unknown')}")
        nodegroups = values(
            aws.json("eks", "list-nodegroups", "--cluster-name", str(cluster), region=region),
            "nodegroups",
        )
        for nodegroup in nodegroups:
            ng = aws.json(
                "eks",
                "describe-nodegroup",
                "--cluster-name",
                str(cluster),
                "--nodegroup-name",
                str(nodegroup),
                region=region,
            ).get("nodegroup", {})
            scaling = ng.get("scalingConfig", {})
            add(
                found,
                region,
                "EKS node group",
                ng.get("status"),
                nodegroup,
                f"desired={scaling.get('desiredSize', 'unknown')} capacity={ng.get('capacityType', 'unknown')}",
            )

    ec2 = aws.json(
        "ec2",
        "describe-instances",
        "--filters",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        region=region,
    )
    for reservation in values(ec2, "Reservations"):
        for instance in values(reservation, "Instances"):
            add(
                found,
                region,
                "EC2 instance",
                instance.get("State", {}).get("Name"),
                instance.get("InstanceId"),
                f"type={instance.get('InstanceType', 'unknown')}",
            )

    for group in values(aws.json("autoscaling", "describe-auto-scaling-groups", region=region), "AutoScalingGroups"):
        add(
            found,
            region,
            "Auto Scaling group",
            f"desired={group.get('DesiredCapacity', 'unknown')}",
            group.get("AutoScalingGroupName"),
            f"min={group.get('MinSize')} max={group.get('MaxSize')}",
        )

    spot = aws.json(
        "ec2",
        "describe-spot-instance-requests",
        "--filters",
        "Name=state,Values=open,active",
        region=region,
    )
    for request in values(spot, "SpotInstanceRequests"):
        add(found, region, "Spot request", request.get("State"), request.get("SpotInstanceRequestId"))

    for fleet in values(aws.json("ec2", "describe-fleets", region=region), "Fleets"):
        if fleet.get("FleetState") != "deleted":
            add(found, region, "EC2 fleet", fleet.get("FleetState"), fleet.get("FleetId"))

    for fleet in values(aws.json("ec2", "describe-spot-fleet-requests", region=region), "SpotFleetRequestConfigs"):
        if fleet.get("SpotFleetRequestState") != "cancelled":
            add(found, region, "Spot fleet", fleet.get("SpotFleetRequestState"), fleet.get("SpotFleetRequestId"))

    for volume in values(aws.json("ec2", "describe-volumes", region=region), "Volumes"):
        add(
            found,
            region,
            "EBS volume",
            volume.get("State"),
            volume.get("VolumeId"),
            f"size_gib={volume.get('Size', 'unknown')} type={volume.get('VolumeType', 'unknown')}",
        )

    for snapshot in values(
        aws.json("ec2", "describe-snapshots", "--owner-ids", "self", region=region),
        "Snapshots",
    ):
        add(found, region, "EBS snapshot", snapshot.get("State"), snapshot.get("SnapshotId"), f"size_gib={snapshot.get('VolumeSize', 'unknown')}")

    for address in values(aws.json("ec2", "describe-addresses", region=region), "Addresses"):
        add(found, region, "Elastic IP", "associated" if address.get("AssociationId") else "idle", address.get("AllocationId") or address.get("PublicIp"))

    for gateway in values(aws.json("ec2", "describe-nat-gateways", region=region), "NatGateways"):
        if gateway.get("State") != "deleted":
            add(found, region, "NAT gateway", gateway.get("State"), gateway.get("NatGatewayId"))

    for lb in values(aws.json("elbv2", "describe-load-balancers", region=region), "LoadBalancers"):
        add(found, region, "Load balancer", lb.get("State", {}).get("Code"), lb.get("LoadBalancerName"), f"type={lb.get('Type', 'unknown')}")
    for lb in values(aws.json("elb", "describe-load-balancers", region=region), "LoadBalancerDescriptions"):
        add(found, region, "Classic load balancer", "active", lb.get("LoadBalancerName"))

    for filesystem in values(aws.json("efs", "describe-file-systems", region=region), "FileSystems"):
        file_system_id = filesystem.get("FileSystemId")
        mount_targets = aws.json("efs", "describe-mount-targets", "--file-system-id", str(file_system_id), region=region)
        add(
            found,
            region,
            "EFS filesystem",
            filesystem.get("LifeCycleState"),
            file_system_id,
            f"bytes={filesystem.get('SizeInBytes', {}).get('Value', 'unknown')} mount_targets={len(values(mount_targets, 'MountTargets'))}",
        )

    for stack in values(aws.json("cloudformation", "list-stacks", region=region), "StackSummaries"):
        if stack.get("StackStatus") != "DELETE_COMPLETE":
            add(found, region, "CloudFormation stack", stack.get("StackStatus"), stack.get("StackName"))

    for group in values(aws.json("logs", "describe-log-groups", region=region), "logGroups"):
        add(
            found,
            region,
            "CloudWatch log group",
            "retained",
            group.get("logGroupName"),
            f"stored_bytes={group.get('storedBytes', 'unknown')} retention_days={group.get('retentionInDays', 'never-expire')}",
        )

    for secret in values(
        aws.json("secretsmanager", "list-secrets", "--include-planned-deletion", region=region),
        "SecretList",
    ):
        add(found, region, "Secrets Manager secret", "scheduled-deletion" if secret.get("DeletedDate") else "active", secret.get("Name"))

    for key in values(aws.json("kms", "list-keys", region=region), "Keys"):
        key_id = key.get("KeyId")
        meta = aws.json("kms", "describe-key", "--key-id", str(key_id), region=region).get("KeyMetadata", {})
        if meta.get("KeyManager") == "CUSTOMER":
            add(found, region, "KMS customer key", meta.get("KeyState"), key_id, f"usage={meta.get('KeyUsage', 'unknown')}")

    for repo in values(aws.json("ecr", "describe-repositories", region=region), "repositories"):
        name = repo.get("repositoryName")
        images = aws.json("ecr", "describe-images", "--repository-name", str(name), region=region)
        image_details = values(images, "imageDetails")
        image_bytes = sum(int(item.get("imageSizeInBytes", 0) or 0) for item in image_details)
        add(found, region, "ECR repository", "retained", name, f"images={len(image_details)} compressed_bytes={image_bytes}")

    for vpc in values(
        aws.json("ec2", "describe-vpcs", "--filters", "Name=is-default,Values=false", region=region),
        "Vpcs",
    ):
        add(found, region, "Non-default VPC", vpc.get("State"), vpc.get("VpcId"), "residual; VPC alone is not billed")

    for vault in values(aws.json("backup", "list-backup-vaults", region=region), "BackupVaultList"):
        vault_name = vault.get("BackupVaultName")
        points = aws.json("backup", "list-recovery-points-by-backup-vault", "--backup-vault-name", str(vault_name), region=region)
        recovery_points = values(points, "RecoveryPoints")
        if recovery_points:
            add(found, region, "AWS Backup recovery points", "retained", vault_name, f"count={len(recovery_points)}")

    return found


def scan_s3(aws: Aws) -> list[Finding]:
    found: list[Finding] = []
    for bucket in values(aws.json("s3api", "list-buckets"), "Buckets"):
        name = bucket.get("Name")
        location = aws.json("s3api", "get-bucket-location", "--bucket", str(name)).get("LocationConstraint") or "us-east-1"
        add(found, str(location), "S3 bucket", "retained", name, "size not queried; presence can retain billable data")
    return found


def enabled_regions(aws: Aws) -> list[str]:
    data = aws.json("ec2", "describe-regions", "--all-regions", region="us-east-1")
    return sorted(
        item["RegionName"]
        for item in values(data, "Regions")
        if item.get("OptInStatus") != "not-opted-in"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity-only", action="store_true", help="only verify preflight and the pinned account")
    parser.add_argument("--needed-hours", type=int, default=4, help="minimum authenticated session duration")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        aws = Aws()
        preflight_and_identity(aws, args.needed_hours)
    except (AuthError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"authentication check failed: {redact(str(exc))}", file=sys.stderr)
        return 3

    if args.identity_only:
        print("identity verified: personal profile matches the pinned lab account")
        return 0

    try:
        regions = enabled_regions(aws)
    except ScanError as exc:
        print(f"incomplete scan: {redact(str(exc))}", file=sys.stderr)
        return 2

    findings: list[Finding] = []
    errors: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(scan_region, aws, region): region for region in regions}
        for future in concurrent.futures.as_completed(futures):
            region = futures[future]
            try:
                findings.extend(future.result())
            except AuthError as exc:
                errors.append(f"{region}: authentication expired")
            except ScanError as exc:
                errors.append(f"{region}: {redact(str(exc))}")

    try:
        findings.extend(scan_s3(aws))
    except ScanError as exc:
        errors.append(f"global S3: {redact(str(exc))}")

    if errors:
        print("incomplete scan: one or more read-only inventory calls failed", file=sys.stderr)
        for error in sorted(set(errors)):
            print(f"  {error}", file=sys.stderr)
        return 2

    if findings:
        print(f"resources found: {len(findings)}")
        for item in sorted(findings):
            detail = f" {item.detail}" if item.detail else ""
            print(f"  {item.region} | {item.service} | {item.state} | {item.identifier}{detail}")
        return 1

    print(f"clean: no billable or residual lab infrastructure found across {len(regions)} enabled regions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
