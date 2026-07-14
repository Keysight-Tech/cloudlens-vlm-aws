#!/usr/bin/env bash
# =============================================================================
# create-cloudlens-vlm-ami.sh
# Build an AWS AMI for the Keysight CloudLens Virtual License Manager (vLM)
# from a source appliance image, in a commercial OR GovCloud account.
#
# Works end to end: convert image -> S3 bucket -> vmimport role -> import-image
# -> AMI. Partition-aware, so the same script runs in commercial (aws) and
# GovCloud (aws-us-gov). Idempotent: safe to re-run.
#
# USAGE
#   ./create-cloudlens-vlm-ami.sh \
#       --image  ~/Downloads/CloudLens-Virtual-License-Manager-1.7.qcow2 \
#       --region us-east-1 \
#       [--profile autopilot] [--bucket NAME] [--ami-name NAME] [--dry-run]
#
#   GovCloud example:
#   ./create-cloudlens-vlm-ami.sh \
#       --image ~/Downloads/CloudLens-vLM-1.7.vmdk \
#       --region us-gov-west-1 --profile govcloud
#
# PREREQUISITES
#   - aws CLI v2, and qemu-img (only if the source is .qcow2 and needs convert)
#   - Credentials for the target account with IAM + EC2 + S3 admin rights
#   - VM Import/Export is enabled in the account/region (default in most)
# =============================================================================
set -euo pipefail

IMAGE=""; REGION=""; PROFILE=""; BUCKET=""; AMI_NAME="CloudLens-vLM-1.7"
DRY_RUN=false
DESC="Keysight CloudLens Virtual License Manager 1.7"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)    IMAGE="$2"; shift 2;;
    --region)   REGION="$2"; shift 2;;
    --profile)  PROFILE="$2"; shift 2;;
    --bucket)   BUCKET="$2"; shift 2;;
    --ami-name) AMI_NAME="$2"; shift 2;;
    --dry-run)  DRY_RUN=true; shift;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

[[ -z "$IMAGE"  ]] && { echo "ERROR: --image is required" >&2; exit 1; }
[[ -z "$REGION" ]] && { echo "ERROR: --region is required" >&2; exit 1; }
[[ -f "$IMAGE"  ]] || { echo "ERROR: image not found: $IMAGE" >&2; exit 1; }

AWS=(aws --region "$REGION")
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

say(){ printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok(){  printf '\033[0;32m[ok]\033[0m %s\n' "$*"; }
run(){ if $DRY_RUN; then echo "  DRY: $*"; else "$@"; fi; }

# ---- 0. Identity + partition (commercial vs GovCloud) -----------------------
CALLER_JSON="$("${AWS[@]}" sts get-caller-identity --output json)"
ACCOUNT="$(printf '%s' "$CALLER_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Account"])')"
ARN="$(printf '%s' "$CALLER_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Arn"])')"
PARTITION="$(printf '%s' "$ARN" | cut -d: -f2)"   # aws or aws-us-gov
say "Account $ACCOUNT  partition $PARTITION  region $REGION"

[[ -z "$BUCKET" ]] && BUCKET="cloudlens-vlm-import-${ACCOUNT}"

# ---- 1. Convert to a VM Import friendly format if needed ---------------------
# VM Import accepts VMDK, VHD, VHDX, OVA, raw. qcow2 is NOT accepted, so convert.
EXT="${IMAGE##*.}"; UPLOAD="$IMAGE"; FMT="$EXT"
if [[ "$EXT" == "qcow2" ]]; then
  command -v qemu-img >/dev/null || { echo "ERROR: qemu-img needed to convert qcow2" >&2; exit 1; }
  UPLOAD="${IMAGE%.qcow2}.vmdk"; FMT="vmdk"
  if [[ ! -f "$UPLOAD" ]]; then
    say "Converting qcow2 -> streamOptimized VMDK"
    run qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized "$IMAGE" "$UPLOAD"
  fi
  ok "VMDK ready: $UPLOAD"
elif [[ "$EXT" == "vhd" ]]; then FMT="vhd"
elif [[ "$EXT" == "vmdk" ]]; then FMT="vmdk"
elif [[ "$EXT" == "vhdx" ]]; then FMT="vhdx"
elif [[ "$EXT" == "raw" || "$EXT" == "img" ]]; then FMT="raw"
else echo "ERROR: unsupported image format .$EXT" >&2; exit 1; fi
KEY="$(basename "$UPLOAD")"

# ---- 2. S3 bucket -----------------------------------------------------------
say "S3 bucket $BUCKET"
if ! "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [[ "$REGION" == "us-east-1" ]]; then
    run "${AWS[@]}" s3api create-bucket --bucket "$BUCKET"
  else
    run "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" \
        --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi
ok "bucket ready"

# ---- 3. vmimport service role (partition-aware ARNs) ------------------------
say "vmimport IAM role"
TRUST=$(cat <<JSON
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"vmie.amazonaws.com"},"Action":"sts:AssumeRole",
  "Condition":{"StringEquals":{"sts:Externalid":"vmimport"}}}]}
JSON
)
POLICY=$(cat <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:GetObject","s3:ListBucket","s3:PutObject","s3:GetBucketAcl"],
   "Resource":["arn:${PARTITION}:s3:::${BUCKET}","arn:${PARTITION}:s3:::${BUCKET}/*"]},
  {"Effect":"Allow","Action":["ec2:ModifySnapshotAttribute","ec2:CopySnapshot","ec2:RegisterImage","ec2:Describe*"],
   "Resource":"*"}]}
JSON
)
if ! "${AWS[@]}" iam get-role --role-name vmimport >/dev/null 2>&1; then
  run "${AWS[@]}" iam create-role --role-name vmimport --assume-role-policy-document "$TRUST"
fi
run "${AWS[@]}" iam put-role-policy --role-name vmimport --policy-name vmimport-vlm --policy-document "$POLICY"
ok "vmimport role ready"

# ---- 4. Upload the disk -----------------------------------------------------
say "Uploading $KEY ($(du -h "$UPLOAD" 2>/dev/null | cut -f1 || echo "?")) to s3://$BUCKET/"
run "${AWS[@]}" s3 cp "$UPLOAD" "s3://${BUCKET}/${KEY}" --only-show-errors
ok "uploaded"

# ---- 5. import-image --------------------------------------------------------
say "Starting import-image"
CONTAINERS=$(cat <<JSON
[{"Description":"${DESC}","Format":"${FMT}","UserBucket":{"S3Bucket":"${BUCKET}","S3Key":"${KEY}"}}]
JSON
)
if $DRY_RUN; then echo "  DRY: import-image with $CONTAINERS"; exit 0; fi
TASK=$("${AWS[@]}" ec2 import-image --description "$DESC" --disk-containers "$CONTAINERS" \
        --query 'ImportTaskId' --output text)
ok "import task: $TASK"

# ---- 6. Poll to completion --------------------------------------------------
say "Waiting for conversion (this can take 15 to 60 minutes)"
prev=""
while true; do
  read -r ST MSG IMG < <("${AWS[@]}" ec2 describe-import-image-tasks --import-task-ids "$TASK" \
      --query 'ImportImageTasks[0].[Status,StatusMessage,ImageId]' --output text | tr '\t' ' ')
  cur="$ST | $MSG"
  [[ "$cur" != "$prev" ]] && { echo "    $(date +%H:%M:%S)  $cur"; prev="$cur"; }
  case "$ST" in
    completed) echo; ok "AMI created: $IMG"; break;;
    deleted|deleting) echo "ERROR: import failed: $MSG" >&2; exit 2;;
  esac
  sleep 30
done

# ---- 7. Tag + report --------------------------------------------------------
run "${AWS[@]}" ec2 create-tags --resources "$IMG" \
    --tags Key=Name,Value="$AMI_NAME" Key=Product,Value=CloudLens-vLM Key=Version,Value=1.7
echo
echo "============================================================"
echo " AMI ready:  $IMG"
echo " Region:     $REGION   Account: $ACCOUNT   Partition: $PARTITION"
echo " Launch it, then license the vPBs against its private IP."
echo "============================================================"
