#!/usr/bin/env bash
# Provision the AWS side of the cloud gaming PC: IAM role, key pair, security
# group, instance, Elastic IP and idle-stop alarm. Run once for a fresh build;
# then run setup.ps1 on the instance (see README).
set -euo pipefail

export AWS_PROFILE=${AWS_PROFILE:-m5mbp}
export AWS_REGION=${AWS_REGION:-us-east-1}

NAME=gaming-pc
INSTANCE_TYPE=${INSTANCE_TYPE:-g6e.4xlarge}
# Pick an AZ that also offers g7e so the instance can be resized to it later
AZ=${AZ:-us-east-1a}
DISK_GB=1000
# gp3 is set to 16000 IOPS / 2000 MB/s, but g6e.4xlarge and g7e.4xlarge cap EBS at 1000 MB/s
KEY_PATH=~/.ssh/cloud-gaming.pem
TAGS='{Key=Project,Value=cloud-gaming}'

here=$(cd "$(dirname "$0")" && pwd)

# IAM: SSM for remote setup, read access to NVIDIA's gaming driver bucket
aws iam create-role --role-name cloud-gaming-ec2 \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --tags "Key=Project,Value=cloud-gaming" >/dev/null
aws iam attach-role-policy --role-name cloud-gaming-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name cloud-gaming-ec2 --policy-name nvidia-gaming-driver \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::nvidia-gaming","arn:aws:s3:::nvidia-gaming/*"]}]}'
aws iam create-instance-profile --instance-profile-name cloud-gaming-ec2 >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name cloud-gaming-ec2 --role-name cloud-gaming-ec2
sleep 10 # instance profile propagation

# Key pair: only used to decrypt the Windows Administrator password
aws ec2 create-key-pair --key-name cloud-gaming --key-type rsa \
  --query KeyMaterial --output text >"$KEY_PATH"
chmod 600 "$KEY_PATH"

# Security group: nothing public except Tailscale's WireGuard port, which keeps
# tailnet connections direct instead of relayed. Moonlight/Apollo go over Tailscale.
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --group-name cloud-gaming --description "Cloud gaming PC (Moonlight)" \
  --vpc-id "$VPC" --tag-specifications "ResourceType=security-group,Tags=[$TAGS]" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  'IpProtocol=udp,FromPort=41641,ToPort=41641,IpRanges=[{CidrIp=0.0.0.0/0,Description=tailscale-direct}]' >/dev/null

# Instance: Windows Server 2022 (the NVIDIA cloud gaming driver targets it)
AMI=$(aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
  --query Parameter.Value --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=availability-zone,Values="$AZ" \
  Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
  --key-name cloud-gaming --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --iam-instance-profile Name=cloud-gaming-ec2 \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,Iops=16000,Throughput=2000,DeleteOnTermination=false}" \
  --metadata-options HttpTokens=required \
  --instance-initiated-shutdown-behavior stop \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},$TAGS]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$NAME-c},$TAGS]" \
  --query 'Instances[0].InstanceId' --output text)
echo "Instance: $IID"
aws ec2 wait instance-running --instance-ids "$IID"

# Fixed public IP so Tailscale's direct endpoint doesn't change between starts
ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME},$TAGS]" --query AllocationId --output text)
aws ec2 associate-address --allocation-id "$ALLOC" --instance-id "$IID" >/dev/null

# Backup idle stop. The primary idle check runs on the instance (idle.ps1), since
# CloudWatch can't attach EC2 stop actions to a metric-math (in+out) alarm.
aws cloudwatch put-metric-alarm --alarm-name "$NAME-idle-stop-backup" \
  --alarm-description "Backup: stop $NAME after 2h of near-zero outbound traffic" \
  --namespace AWS/EC2 --metric-name NetworkOut --dimensions Name=InstanceId,Value="$IID" \
  --statistic Sum --period 300 --threshold 5000000 --comparison-operator LessThanThreshold \
  --evaluation-periods 24 --datapoints-to-alarm 24 --treat-missing-data notBreaching \
  --alarm-actions "arn:aws:automate:$AWS_REGION:ec2:stop"

# Weekly C: snapshots (Mondays 09:00 UTC), keep the last 4
aws dlm create-default-role --resource-type snapshot >/dev/null 2>&1 || true
DLM_ROLE=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text)
aws dlm create-lifecycle-policy --description "$NAME weekly snapshots keep 4" --state ENABLED \
  --execution-role-arn "$DLM_ROLE" --tags Project=cloud-gaming \
  --policy-details "{\"PolicyType\":\"EBS_SNAPSHOT_MANAGEMENT\",\"ResourceTypes\":[\"VOLUME\"],
    \"TargetTags\":[{\"Key\":\"Name\",\"Value\":\"$NAME-c\"}],
    \"Schedules\":[{\"Name\":\"weekly\",\"CopyTags\":true,\"TagsToAdd\":[{\"Key\":\"Project\",\"Value\":\"cloud-gaming\"}],
      \"CreateRule\":{\"CronExpression\":\"cron(0 9 ? * MON *)\"},\"RetainRule\":{\"Count\":4}}]}" >/dev/null

echo "Done. Next: run setup.ps1 on $IID (see README), then update IID in gpc."
