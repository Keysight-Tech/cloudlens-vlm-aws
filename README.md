# CloudLens vLM on AWS

Build the **Keysight CloudLens Virtual License Manager (vLM)** as an AWS AMI and deploy it in **commercial AWS or GovCloud**, with one interactive command. The vLM is the network license server that standalone Virtual Packet Brokers (vPBs) pull their capacity licenses from.

🌐 **Docs (web):** https://keysight-tech.github.io/cloudlens-vlm-aws/
📘 **Runbook:** [PDF](docs/CloudLens_vLM_AMI_AWS_GovCloud_Runbook.pdf) · [DOCX](docs/CloudLens_vLM_AMI_AWS_GovCloud_Runbook.docx)

---

## Quick start

```bash
git clone https://github.com/Keysight-Tech/cloudlens-vlm-aws.git
cd cloudlens-vlm-aws
chmod +x *.sh

# Download the official CloudLens vLM image from the Keysight portal
#   https://software.keysight.com   (qcow2 or vhd)

# Run the interactive wizard
./deploy-cloudlens-vlm.sh --profile <your-aws-profile>
```

The wizard asks a few friendly questions (cloud or GovCloud, region, reuse or build the AMI, instance size, how many, key pair, subnet, who can access), builds the AMI if needed, launches the vLM, and prints the URL and login.

## GovCloud

Same script, no code changes. It auto-detects the `aws-us-gov` partition:

```bash
./deploy-cloudlens-vlm.sh --profile <govcloud-profile> --region us-gov-west-1
```

## What is here

| File | Purpose |
|------|---------|
| `deploy-cloudlens-vlm.sh` | Interactive wizard: build AMI and launch vLM instances (commercial or GovCloud) |
| `create-cloudlens-vlm-ami.sh` | Non-interactive engine: builds only the AMI (CI or scripted) |
| `docs/` | Full deployment runbook (DOCX + PDF) and the web page |

## How it works

```
Keysight vLM image (qcow2/vhd)  ->  convert to streamOptimized VMDK  ->  S3
   ->  aws ec2 import-image (vmimport role)  ->  AMI  ->  launch  ->  license the vPBs
```

## Requirements

- AWS CLI v2, credentials for the target account (IAM, EC2, S3)
- `qemu-img` (only if the source image is qcow2 and needs converting)
- The official CloudLens vLM image from **software.keysight.com** (do not use an unofficial image)

## Important

- Download the vLM image **only** from the official Keysight software download portal, and match the version to your CloudLens and vPB deployment.
- Restrict the security group to trusted sources; the vLM needs to be reachable only by administrators and the vPBs that license against it.
