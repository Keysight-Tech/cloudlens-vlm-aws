#!/usr/bin/env bash
# =============================================================================
#  Keysight CloudLens vLM  -  Premium AWS Deployment Wizard
# =============================================================================
#  Interactive, first-class deployer for the CloudLens Virtual License Manager.
#  It walks you through a few friendly questions, builds the AMI if you need
#  one, launches your vLM instances, and hands back a clean access summary.
#
#  Works in BOTH commercial AWS and AWS GovCloud (partition detected
#  automatically: aws or aws-us-gov).
#
#  Run it:
#     ./deploy-cloudlens-vlm.sh                 # full interactive wizard
#     ./deploy-cloudlens-vlm.sh --profile govcloud --region us-gov-west-1
#     ./deploy-cloudlens-vlm.sh --yes ...       # accept defaults, no prompts
#
#  Requirements: aws CLI v2, qemu-img (only if building from a .qcow2).
# =============================================================================
set -uo pipefail

# ---- palette ---------------------------------------------------------------
if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[38;5;197m'; GRN=$'\033[38;5;42m'; CYN=$'\033[38;5;44m'
  YEL=$'\033[38;5;220m'; NAVY=$'\033[38;5;68m'; GREY=$'\033[38;5;245m'
else R=""; B=""; DIM=""; RED=""; GRN=""; CYN=""; YEL=""; NAVY=""; GREY=""; fi

banner(){
  printf '\n%s' "$RED"
  printf '  ╔══════════════════════════════════════════════════════════════╗\n'
  printf '  ║                                                              ║\n'
  printf '  ║      %sKEYSIGHT%s   CloudLens vLM   %sAWS Deployment Wizard%s      %s║\n' "$B$YEL" "$R$RED" "$B" "$R$RED" "$RED"
  printf '  ║                                                              ║\n'
  printf '  ╚══════════════════════════════════════════════════════════════╝%s\n\n' "$R"
}
hr(){ printf '  %s────────────────────────────────────────────────────────────%s\n' "$GREY" "$R"; }
step(){ printf '\n  %s%s  %s%s\n' "$B$NAVY" "$1" "$2" "$R"; }
ok(){   printf '  %s✔%s %s\n' "$GRN" "$R" "$1"; }
warn(){ printf '  %s▲%s %s\n' "$YEL" "$R" "$1"; }
fail(){ printf '  %s✘ %s%s\n' "$RED" "$1" "$R"; exit 1; }
note(){ printf '     %s%s%s\n' "$DIM" "$1" "$R"; }

ask(){ # ask VAR "Prompt" "default"
  local __v=$1 __p=$2 __d=${3:-} __in
  if $ASSUME_YES && [[ -n "$__d" ]]; then printf -v "$__v" '%s' "$__d"; printf '  %s?%s %s %s[%s]%s\n' "$CYN" "$R" "$__p" "$DIM" "$__d" "$R"; return; fi
  if [[ -n "$__d" ]]; then read -r -p "  ${CYN}?${R} ${__p} ${DIM}[${__d}]${R}: " __in; else read -r -p "  ${CYN}?${R} ${__p}: " __in; fi
  printf -v "$__v" '%s' "${__in:-$__d}"
}
menu(){ # menu VAR "Prompt" default_index  "label1|value1" "label2|value2" ...
  local __v=$1 __p=$2 __def=$3; shift 3; local opts=("$@") i
  printf '  %s?%s %s\n' "$CYN" "$R" "$__p"
  for i in "${!opts[@]}"; do
    local lbl=${opts[$i]%%|*}; local mark=""
    [[ $((i+1)) -eq $__def ]] && mark=" ${GRN}(recommended)${R}"
    printf '      %s%d)%s %s%s\n' "$B" $((i+1)) "$R" "$lbl" "$mark"
  done
  local __c
  if $ASSUME_YES; then __c=$__def; printf '     %schose %d%s\n' "$DIM" "$__def" "$R"
  else read -r -p "     select [${__def}]: " __c; __c=${__c:-$__def}; fi
  printf -v "$__v" '%s' "${opts[$((__c-1))]##*|}"
}
confirm(){ $ASSUME_YES && return 0; local a; read -r -p "  ${CYN}?${R} $1 ${DIM}[y/N]${R}: " a; [[ "$a" == [Yy]* ]]; }
readlines(){ local __arr=$1 __l; eval "$__arr=()"; while IFS= read -r __l; do [[ -n "$__l" ]] && eval "$__arr+=(\"\$__l\")"; done; }

# ---- args ------------------------------------------------------------------
PROFILE=""; REGION=""; ASSUME_YES=false; IMAGE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;;
  --region)  REGION="$2"; shift 2;;
  --image)   IMAGE="$2"; shift 2;;
  --yes|-y)  ASSUME_YES=true; shift;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown arg: $1"; exit 1;;
esac; done
AWSP=(); [[ -n "$PROFILE" ]] && AWSP=(--profile "$PROFILE")
aws_(){ aws "${AWSP[@]}" --region "$REGION" "$@"; }

banner

# ---- 1. cloud + auth -------------------------------------------------------
step "1." "Choose your AWS cloud"
if [[ -z "$REGION" ]]; then
  menu CLOUD "Which AWS partition are you deploying to?" 1 \
    "Commercial AWS  (us-east-1, us-west-2 ...)|commercial" \
    "AWS GovCloud    (us-gov-west-1, us-gov-east-1)|govcloud"
  if [[ "$CLOUD" == govcloud ]]; then
    menu REGION "GovCloud region" 1 "us-gov-west-1|us-gov-west-1" "us-gov-east-1|us-gov-east-1"
  else
    ask REGION "Commercial region" "us-east-1"
  fi
fi
if [[ -z "$PROFILE" ]]; then
  ask PROFILE "AWS CLI profile to use (blank = default/env)" ""
  [[ -n "$PROFILE" ]] && AWSP=(--profile "$PROFILE")
fi
note "checking credentials ..."
CALLER="$(aws_ sts get-caller-identity --output json 2>/dev/null)" || {
  warn "not authenticated for region $REGION."
  note "Commercial SSO:  aws sso login --profile ${PROFILE:-<profile>}"
  note "GovCloud:        configure a GovCloud profile, then re-run with --profile <that>"
  fail "authenticate and re-run"
}
ACCOUNT=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["Account"])' <<<"$CALLER")
ARN=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["Arn"])' <<<"$CALLER")
PARTITION=$(cut -d: -f2 <<<"$ARN")
ok "Account ${B}${ACCOUNT}${R}   partition ${B}${PARTITION}${R}   region ${B}${REGION}${R}"

# ---- 2. AMI: reuse or build ------------------------------------------------
step "2." "vLM image (AMI)"
readlines EXIST < <(aws_ ec2 describe-images --owners self \
   --filters "Name=tag:Product,Values=CloudLens-vLM" \
   --query 'reverse(sort_by(Images,&CreationDate))[].[ImageId,Name]' --output text 2>/dev/null)
AMI=""
if [[ ${#EXIST[@]} -gt 0 && -n "${EXIST[0]}" ]]; then
  ok "found existing CloudLens vLM AMIs in this account:"
  for e in "${EXIST[@]}"; do note "$e"; done
  DEFAMI=$(awk '{print $1}' <<<"${EXIST[0]}")
  menu AMICHOICE "Use an existing AMI or build a fresh one?" 1 \
    "Use most recent: $DEFAMI|$DEFAMI" "Build a new AMI from the vLM image|BUILD"
  AMI="$AMICHOICE"
else
  note "no CloudLens vLM AMI found in this account/region"
  AMI="BUILD"
fi

if [[ "$AMI" == "BUILD" ]]; then
  [[ -z "$IMAGE" ]] && ask IMAGE "Path to the vLM image (.qcow2 / .vhd / .vmdk)" "$HOME/Downloads/CloudLens-Virtual-License-Manager-1.7.qcow2"
  [[ -f "$IMAGE" ]] || fail "image not found: $IMAGE"
  step " " "Building the AMI (this runs the full import, about 20 minutes)"
  ENGINE="$(dirname "$0")/create-cloudlens-vlm-ami.sh"
  [[ -x "$ENGINE" ]] || fail "engine not found: $ENGINE (keep create-cloudlens-vlm-ami.sh beside this script)"
  BUILD_ARGS=(--image "$IMAGE" --region "$REGION"); [[ -n "$PROFILE" ]] && BUILD_ARGS+=(--profile "$PROFILE")
  AMI=$("$ENGINE" "${BUILD_ARGS[@]}" | tee /dev/stderr | awk '/AMI ready:/{print $3; exit}')
  [[ "$AMI" == ami-* ]] || fail "AMI build did not return an id"
fi
ok "using AMI ${B}${AMI}${R}"

# ---- 3. instance shape -----------------------------------------------------
step "3." "Instance size and count"
menu ITYPE "Instance size for each vLM" 2 \
  "t3.medium   2 vCPU   4 GB   - minimal|t3.medium" \
  "t3.large    2 vCPU   8 GB   - recommended (matches the appliance)|t3.large" \
  "m5.large    2 vCPU   8 GB   - general purpose|m5.large" \
  "c5.xlarge   4 vCPU   8 GB   - higher throughput|c5.xlarge" \
  "custom (type your own)|custom"
[[ "$ITYPE" == custom ]] && ask ITYPE "Enter the instance type" "t3.large"
ask COUNT "How many vLM instances?" "1"
[[ "$COUNT" =~ ^[0-9]+$ ]] || fail "count must be a number"

# ---- 4. key pair -----------------------------------------------------------
step "4." "SSH key pair"
readlines KEYS < <(aws_ ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n')
if [[ ${#KEYS[@]} -gt 0 && -n "${KEYS[0]}" ]]; then
  note "existing key pairs: ${KEYS[*]}"
  ask KEY "Key pair name" "${KEYS[0]}"
else
  ask KEY "No key pairs found. Enter a name to create one" "cloudlens-vlm-key"
  aws_ ec2 create-key-pair --key-name "$KEY" --query 'KeyMaterial' --output text > "$HOME/.ssh/$KEY.pem" 2>/dev/null \
    && { chmod 600 "$HOME/.ssh/$KEY.pem"; ok "created key, saved to ~/.ssh/$KEY.pem"; }
fi

# ---- 5. network ------------------------------------------------------------
step "5." "Network placement"
readlines SUBS < <(aws_ ec2 describe-subnets \
  --query 'Subnets[?MapPublicIpOnLaunch==`true`].[SubnetId,AvailabilityZone,CidrBlock,VpcId]' --output text 2>/dev/null)
if [[ ${#SUBS[@]} -eq 0 || -z "${SUBS[0]}" ]]; then
  readlines SUBS < <(aws_ ec2 describe-subnets --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,VpcId]' --output text 2>/dev/null)
fi
[[ ${#SUBS[@]} -gt 0 && -n "${SUBS[0]}" ]] || fail "no subnets found in $REGION"
note "available subnets:"; for s in "${SUBS[@]}"; do note "$s"; done
DEFSUB=$(awk '{print $1}' <<<"${SUBS[0]}"); DEFVPC=$(awk '{print $4}' <<<"${SUBS[0]}")
ask SUBNET "Subnet to launch into" "$DEFSUB"
VPC=$(aws_ ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].VpcId' --output text 2>/dev/null)

MYIP=$(curl -s https://checkip.amazonaws.com 2>/dev/null)
step "6." "Who can reach the vLM"
menu ACCESS "Allow HTTPS (443) and SSH (22) from" 1 \
  "Just my IP  ${MYIP}/32  (safest)|${MYIP}/32" \
  "A CIDR I will type|custom" \
  "Anywhere 0.0.0.0/0  (not recommended)|0.0.0.0/0"
[[ "$ACCESS" == custom ]] && ask ACCESS "Enter allowed CIDR" "${MYIP}/32"

SG=$(aws_ ec2 create-security-group --group-name "cloudlens-vlm-$RANDOM" \
      --description "CloudLens vLM access" --vpc-id "$VPC" --query GroupId --output text 2>/dev/null)
for p in 443 22; do aws_ ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port $p --cidr "$ACCESS" >/dev/null 2>&1; done
ok "security group $SG  (443, 22 from $ACCESS)"

# ---- 7. review -------------------------------------------------------------
step "7." "Review"
hr
printf '     %-16s %s\n' "Cloud"         "$PARTITION / $REGION (account $ACCOUNT)"
printf '     %-16s %s\n' "AMI"           "$AMI"
printf '     %-16s %s\n' "Instance size" "$ITYPE"
printf '     %-16s %s\n' "How many"      "$COUNT"
printf '     %-16s %s\n' "Key pair"      "$KEY"
printf '     %-16s %s\n' "Subnet / VPC"  "$SUBNET / $VPC"
printf '     %-16s %s\n' "Access from"   "$ACCESS"
hr
confirm "Launch now?" || { warn "cancelled (nothing launched); security group $SG left in place"; exit 0; }

# ---- 8. launch -------------------------------------------------------------
step "8." "Launching ${COUNT} vLM instance(s)"
IIDS=$(aws_ ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" --count "$COUNT" \
  --key-name "$KEY" --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cloudlens-vlm},{Key=Product,Value=CloudLens-vLM}]' \
  --query 'Instances[].InstanceId' --output text 2>&1) || fail "run-instances failed: $IIDS"
ok "launched: $IIDS"
note "waiting for running state ..."
aws_ ec2 wait instance-running --instance-ids $IIDS 2>/dev/null

# ---- 9. summary ------------------------------------------------------------
step "9." "Deployment summary"
printf '\n  %s╔════════════════════════════════════════════════════════════╗%s\n' "$GRN" "$R"
printf '  %s║   CloudLens vLM is deploying. Access details below.        ║%s\n' "$GRN" "$R"
printf '  %s╚════════════════════════════════════════════════════════════╝%s\n\n' "$GRN" "$R"
for id in $IIDS; do
  pub=$(aws_ ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
  prv=$(aws_ ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null)
  printf '  %s%s%s\n' "$B" "$id" "$R"
  printf '     %s🌐 vLM UI %s  https://%s\n' "$CYN" "$R" "$pub"
  printf '     %s🔑 Login  %s  admin / admin   %s(change on first login)%s\n' "$CYN" "$R" "$DIM" "$R"
  printf '     %s🔒 Private%s  %s   %s(point your vPBs here to license)%s\n' "$CYN" "$R" "$prv" "$DIM" "$R"
done
echo
note "The vLM web app takes ~2 to 4 minutes after boot to answer on 443."
note "Teardown:  aws ec2 terminate-instances --instance-ids $IIDS ; aws ec2 delete-security-group --group-id $SG"
printf '\n  %s🚀  Done.%s\n\n' "$GRN$B" "$R"
