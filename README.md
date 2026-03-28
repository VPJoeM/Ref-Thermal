# Reflection Thermal Diagnostics

Automated GPU thermal diagnostics for Dell PowerEdge servers with NVIDIA H100 GPUs. Runs Dell's thermal stress test across your fleet in parallel, collects TSR reports, and uploads everything to Google Drive.

Single file, self-contained -- nothing to install or configure beforehand.

---

## Step-by-Step Guide

### 1. Prerequisites

On **your Mac/laptop** (where you run the script from):

- `pssh` installed: `brew install pssh`
- An SSH key that can reach your nodes (e.g. `~/.ssh/id_ed25519`)
- The Google Drive password (ask your team if you don't have it)

On **every GPU node** you want to test:

- Your SSH key's public key in `~/.ssh/authorized_keys` for the `ubuntu` user
- The `ubuntu` user must have **passwordless sudo**
- No GPU workloads running during the test

### 2. Verify SSH Access

Before running, confirm you can reach each node:

```
ssh -i ~/.ssh/your_key ubuntu@NODE_IP "hostname && sudo whoami"
```

You should see the hostname and `root`. If not, fix SSH access first.

### 3. Download and Run

Open a terminal on your Mac and run:

```
curl -sLO https://raw.githubusercontent.com/VPJoeM/Ref-Thermal/main/thermal-pssh-manager.sh && bash thermal-pssh-manager.sh
```

### 4. Enter the Google Drive Password

On first run, you'll be prompted for the Google Drive password. This is saved locally so you won't be asked again.

### 5. Follow the Menu

The script presents a simple menu:

```
1) Run Thermal Diagnostics  ← start here
2) Rerun Last               ← repeat previous run
```

Select **1** for a new run. You'll be asked:

1. **SSH user** -- press Enter for default (`ubuntu`)
2. **SSH key** -- pick from the list or enter a path
3. **Node IPs** -- paste your list of IPs (space or comma separated)

### 6. Wait ~30 Minutes

The script handles everything from here:

- Uploads the test script to all nodes
- Runs a 15-minute GPU stress test in parallel
- Collects Dell SupportAssist TSR reports from each node's iDRAC
- Merges GPU temperature, power, and clock data into CSV

You'll see live progress:

```
  05:23  1/10 done  0 failed |  g0799: GPU stress  g0890: TSR 45%
```

### 7. Results Upload

When all nodes finish, results are automatically:

1. Copied to the shared NFS (`/data/thermal-jm-VP-Diag/`) if available
2. Uploaded to the Reflection Google Team Drive

Each node produces one zip file. You'll see the Drive folder path when complete:

```
  UPLOADED TO GOOGLE DRIVE
  Drive:    thermal-results/sea1-20260328-142530/
  Uploaded: 10 nodes
  NFS:     /data/thermal-jm-VP-Diag/sea1-20260328-142530/
```

### 8. Next Run

Select **2) Rerun Last** from the menu to repeat with the same nodes and settings.

---

## Kubernetes Version

If your nodes are in a K8s cluster:

```
curl -sLO https://raw.githubusercontent.com/VPJoeM/Ref-Thermal/main/k8s-setup/thermal-k8s-manager.sh && bash thermal-k8s-manager.sh
```

Same flow -- provide the control plane IP and worker node IPs. The script deploys K8s Jobs instead of using pssh.

---

## CLI Mode

For automation or scripting, skip the menu:

```
bash thermal-pssh-manager.sh run \
  --user ubuntu \
  --key ~/.ssh/id_ed25519 \
  --nodes "10.0.1.50 10.0.1.51 10.0.1.52" \
  --output gdrive
```

Or load nodes from a file:

```
bash thermal-pssh-manager.sh run \
  --user ubuntu \
  --key ~/.ssh/id_ed25519 \
  --nodes-file fleet.txt \
  --output gdrive
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| SSH connection failed | Add your public key to `~/.ssh/authorized_keys` on the node |
| sudo password required | Add `ubuntu ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers` |
| Too many auth failures | Use `--key` to specify the exact key |
| SupportAssist job running | Wait or run `sudo racadm jobqueue delete -i JID_CLEARALL` on the node |
| Wrong Google Drive password | Delete `/tmp/.thermal-gdrive-pass` and re-enter |
