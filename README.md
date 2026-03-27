# Reflection Thermal Diagnostics

Automated GPU thermal diagnostics tooling for Dell PowerEdge servers with NVIDIA GPUs. Runs Dell's dcgmprofrunner thermal stress test across a fleet of nodes in parallel, collects results, and uploads to Google Drive.

Two versions are provided depending on the infrastructure:

- **PSSH version** -- for bare-metal nodes without Kubernetes (uses parallel-ssh)
- **K8s version** -- for nodes managed by a Kubernetes cluster (uses K8s Jobs)

Both produce identical output: a single rollup zip containing per-node result zips in Dell's format.

---

## Output Format

```
sea1-20260327-124745.zip
  |-- g329-7871FZ3.zip       (hostname-ServiceTag)
  |-- g330-DV42FZ3.zip
```

Each node zip contains:
- `thermal_results.hostname.1004.900.date.csv` -- GPU thermal data
- `dcgmproftester.log` -- stress test log
- `tensor_active_0-7.results` -- per-GPU tensor results
- `TSR_SVCTAG_date.zip` -- Dell SupportAssist Technical Support Report

---

## Prerequisites

### Common
- macOS or Linux workstation
- `sshv` (Voltage Park SSH wrapper) or standard SSH access to nodes
- Nodes must have: NVIDIA GPUs, racadm (Dell iDRAC), ipmitool
- No running GPU workloads on target nodes during testing

### PSSH Version
- `pssh` (parallel-ssh): `brew install pssh`
- SSH key authorized on every target node
- User with passwordless sudo on each node

### K8s Version
- Working Kubernetes cluster with NVIDIA GPU Operator
- `sshv` access to the control plane node
- Container image built and imported on all nodes (the script handles this automatically)

---

## Setup

### 1. Clone this repo

```
git clone https://github.com/VPJoeM/Ref-Thermal.git
cd Ref-Thermal
```

### 2. Google Drive (optional)

To upload results to Google Drive, place your service account JSON key file:

- PSSH version: `gdrive-sa.json` next to `thermal-pssh-manager.sh`
- K8s version: `k8s-setup/gdrive-sa.json` next to `thermal-k8s-manager.sh`

To create the key:
1. Google Cloud Console > IAM > Service Accounts > Create
2. Download JSON key
3. Share the Team Drive with the service account email as Contributor
4. Place the JSON file as described above

The scripts install rclone on the node temporarily for upload, then remove it.

### 3. SSH Key Setup (PSSH version)

Ensure your SSH key is authorized on every node:

```
ssh-copy-id -i ~/.ssh/your_key user@node_ip
```

Or use sshv to push a temporary key:

```
sshv vpsupport@node_ip "mkdir -p ~/.ssh && echo 'your_public_key' >> ~/.ssh/authorized_keys"
```

### 4. K8s Container Image (K8s version)

The K8s script builds and distributes the container image automatically on first run. It needs Docker installed on the nodes. If the image is already present, it skips this step.

---

## Usage: PSSH Version

### Interactive Menu

```
cd Ref-Thermal
bash thermal-pssh-manager.sh
```

The menu walks through:
1. SSH username, key selection, and node IPs
2. Output destination (Local / Node / Google Drive / FTP)

Then runs hands-off across the entire fleet.

### CLI Mode

```
bash thermal-pssh-manager.sh run \
  --user vpsupport \
  --key ~/.ssh/my_key \
  --nodes "10.0.1.50 10.0.1.51 10.0.1.52" \
  --output gdrive
```

Or load nodes from a file:

```
bash thermal-pssh-manager.sh run \
  --user root \
  --key ~/.ssh/id_ed25519 \
  --nodes-file fleet.txt \
  --output node --collect-node 10.0.1.50
```

### CLI Options

```
--user USER           SSH username
--key PATH            SSH private key path
--nodes "ip1 ip2"     Target node IPs (space or comma separated)
--nodes-file FILE     Load node IPs from file (one per line)
--output MODE         local | node | gdrive | ftp
--collect-node IP     Collection node IP (node mode)
--gdrive-folder NAME  Google Drive folder name (gdrive mode)
--ftp-host HOST       FTP host (ftp mode)
--ftp-user USER       FTP user (ftp mode)
--ftp-pass PASS       FTP password (ftp mode)
```

---

## Usage: K8s Version

### Interactive Menu

```
cd Ref-Thermal/k8s-setup
bash thermal-k8s-manager.sh
```

The menu walks through:
1. Connection method (sshv or kubeconfig)
2. Auto-detects all GPU nodes in the cluster
3. Output destination

### CLI Mode

```
bash thermal-k8s-manager.sh run \
  --control-plane 147.185.41.203 \
  --nodes "g329 g330" \
  --node-ips "g329:147.185.41.203,g330:147.185.41.204" \
  --output gdrive
```

### CLI Options

```
--control-plane IP       Control plane public IP (sshv mode)
--kubeconfig FILE        Path to kubeconfig (kubeconfig mode)
--nodes "n1 n2"          K8s node hostnames
--all-gpu-nodes          Auto-detect all GPU nodes
--node-ips "h1:ip1,..."  Hostname-to-public-IP mapping for result collection
--output MODE            local | node | gdrive | nfs | ftp
--collect-node HOST      Collection node hostname (node mode)
--gdrive-folder NAME     Google Drive folder (gdrive mode)
```

---

## SSH Proxy / Jump Host

Some nodes may only be reachable via a jump host using private IPs. Both scripts auto-detect this:

1. Direct SSH is tried first
2. If it fails, you are prompted for the node's private IP
3. The script routes through the jump host (10.9.231.200) automatically

No manual proxy configuration needed.

---

## Output Destinations

| Mode | Where results go |
|------|-----------------|
| `local` | Results stay on each node at `/root/TDAS/` |
| `node` | All results collected to one designated node |
| `gdrive` | Uploaded to Google Team Drive via rclone (installed/removed automatically) |
| `ftp` | Uploaded to an FTP server |
| `nfs` | Written to NFS mount (K8s version only) |

---

## File Structure

```
Ref-Thermal/
  thermal-pssh-manager.sh          -- PSSH version (main script)
  thermal-diagnostics-2.6.2-vp.sh  -- Dell thermal test script
  k8s-setup/
    thermal-k8s-manager.sh         -- K8s version (main script)
    Dockerfile                     -- Container image build
    entrypoint.sh                  -- Container entrypoint
    job-template.yaml              -- K8s Job template
    namespace.yaml                 -- thermal-diagnostics namespace
    gdrive-sa.json                 -- Google Drive service account key
```
