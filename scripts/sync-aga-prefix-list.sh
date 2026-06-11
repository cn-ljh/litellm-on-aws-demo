#!/usr/bin/env bash
# Sync the AGA GLOBAL edge CIDRs from AWS ip-ranges.json into the
# customer-managed prefix list used by the LiteLLM ALB security group.
#
# WHY: AWS Global Accelerator has NO AWS-managed prefix list (unlike CloudFront),
# so we maintain our own. With client IP preservation OFF (NAT mode), the ALB
# sees AGA edge IPs as the source, and the SG locks to this list.
#
# CIDR SET: GLOBAL anycast ranges + the accelerator's HOME region (us-west-2,
# the AGA control-plane region where the accelerator + its IPs are allocated).
# NAT forwarding source IPs come from the accelerator region, not the endpoint
# region -- verified via VPC Flow Log (ALB saw 13.248.112.0/24 = us-west-2).
#
# Run on a schedule (e.g. weekly cron) to pick up AWS range changes.
# Idempotent: only adds/removes the delta, bumps the PL version when changed.
#
# Usage:
#   PROJECT_NAME=litellm-gw AWS_REGION=us-east-1 AGA_REGION=us-west-2 ./scripts/sync-aga-prefix-list.sh
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
REGION="${AWS_REGION:-us-east-1}"
AGA_REGION="${AGA_REGION:-us-west-2}"
PL_NAME="${PROJECT_NAME}-aga-global"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

PL_ID=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
  --filters "Name=prefix-list-name,Values=${PL_NAME}" \
  --query "PrefixLists[0].PrefixListId" --output text 2>/dev/null)

if [ -z "$PL_ID" ] || [ "$PL_ID" = "None" ]; then
  log "ERROR: prefix list '${PL_NAME}' not found in ${REGION}. Deploy cfn/06-global-accelerator.yaml first."
  exit 1
fi
log "Prefix list: ${PL_ID} (${PL_NAME})"

# Desired CIDRs = GLOBALACCELERATOR / (region=GLOBAL OR region=accelerator region)
DESIRED=$(curl -sf https://ip-ranges.amazonaws.com/ip-ranges.json | AGA_REGION="$AGA_REGION" python3 -c "
import sys,json,os
d=json.load(sys.stdin)
reg=os.environ['AGA_REGION']
print('\n'.join(sorted(set(p['ip_prefix'] for p in d['prefixes']
      if p['service']=='GLOBALACCELERATOR' and p['region'] in ('GLOBAL',reg)))))
")
[ -n "$DESIRED" ] || { log "ERROR: failed to fetch GLOBAL CIDRs"; exit 1; }

# Current CIDRs in the prefix list
CURRENT=$(aws ec2 get-managed-prefix-list-entries --region "$REGION" \
  --prefix-list-id "$PL_ID" --query "Entries[].Cidr" --output text 2>/dev/null \
  | tr '\t' '\n' | sort)

ADD=$(comm -23 <(echo "$DESIRED") <(echo "$CURRENT"))
DEL=$(comm -13 <(echo "$DESIRED") <(echo "$CURRENT"))

if [ -z "$ADD" ] && [ -z "$DEL" ]; then
  log "No changes. Prefix list is up to date ($(echo "$DESIRED" | wc -l) CIDRs)."
  exit 0
fi

log "To add: $(echo "$ADD" | grep -c . 2>/dev/null || echo 0) | To remove: $(echo "$DEL" | grep -c . 2>/dev/null || echo 0)"

VER=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
  --prefix-list-ids "$PL_ID" --query "PrefixLists[0].Version" --output text)

ADD_JSON="[]"; DEL_JSON="[]"
[ -n "$ADD" ] && ADD_JSON=$(echo "$ADD" | python3 -c "import sys,json;print(json.dumps([{'Cidr':l.strip()} for l in sys.stdin if l.strip()]))")
[ -n "$DEL" ] && DEL_JSON=$(echo "$DEL" | python3 -c "import sys,json;print(json.dumps([{'Cidr':l.strip()} for l in sys.stdin if l.strip()]))")

ARGS=(--region "$REGION" --prefix-list-id "$PL_ID" --current-version "$VER")
[ "$ADD_JSON" != "[]" ] && ARGS+=(--add-entries "$ADD_JSON")
[ "$DEL_JSON" != "[]" ] && ARGS+=(--remove-entries "$DEL_JSON")

aws ec2 modify-managed-prefix-list "${ARGS[@]}" >/dev/null
log "Prefix list ${PL_ID} updated (was v${VER}). New CIDR count: $(echo "$DESIRED" | wc -l)."
