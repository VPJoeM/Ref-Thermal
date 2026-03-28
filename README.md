# Reflection Thermal Diagnostics

Automated GPU thermal diagnostics for Dell PowerEdge servers with NVIDIA GPUs. Runs Dell's dcgmprofrunner thermal stress test across a fleet of nodes in parallel, collects results, and uploads to Google Drive.

Two self-contained scripts -- no dependencies to install, no config files to manage. Each script is a single file that contains everything it needs.

---

## Quick Start

**You run these scripts from your laptop/workstation, NOT on the GPU nodes.** The scripts SSH into the nodes remotely to run the tests.

### Bare Metal (no Kubernetes)

```
curl -sLO https://raw.githubusercontent.com/VPJoeM/Ref-Thermal/main/thermal-pssh-manager.sh && bash thermal-pssh-manager.sh
```

### Kubernetes Cluster

```
curl -sLO https://raw.githubusercontent.com/VPJoeM/Ref-Thermal/main/k8s-setup/thermal-k8s-manager.sh && bash thermal-k8s-manager.sh
```

---

## Before You Run

### Bare Metal Version -- What You Need

1. **Your laptop/Mac** with `pssh` installed (`brew install pssh`)
2. **An SSH private key** on your laptop (e.g. `~/.ssh/id_ed25519`)
3. **That key's public key must be in `~/.ssh/authorized_keys` on EVERY node** you want to test
4. **The SSH user** (default: `ubuntu`) must have **passwordless sudo** on every node
5. **A list of node IPs** (or a file with one IP per line)
6. **No GPU workloads running** on the target nodes during testing

How to verify your setup before running:
```
ssh -i ~/.ssh/your_key ubuntu@NODE_IP "hostname && sudo whoami"
# should print the hostname and "root"
```

If that doesn't work on ANY node, the script will fail on that node.

### Kubernetes Version -- What You Need

1. **Your laptop/Mac** with SSH access to the K8s control plane node
2. **The control plane's public IP** (you'll enter it when prompted)
3. **The public IP for each worker node** (for collecting results after the test)
4. **Your SSH key's public key in `~/.ssh/authorized_keys`** on each node
5. **NVIDIA GPU Operator** running in the cluster
6. **Docker** installed on the nodes (the script builds a container image on first run)

---

## How It Works

1. You run the script **on your laptop**
2. The script connects to your nodes via SSH
3. It deploys and runs a ~15-minute GPU thermal stress test on all nodes in parallel
4. While the test runs, it collects Dell SupportAssist TSR reports
5. After completion, results are uploaded to Google Drive (or saved to NFS/node)

Total runtime: approximately 25-30 minutes per run.

---

## Output

Results are uploaded as individual per-node zips into a Google Drive folder:

```
thermal-results/sea1-20260327-124745/
  ├── g329-7871FZ3.zip       (hostname-ServiceTag)
  ├── g330-DV42FZ3.zip
  └── ...
```

Each node zip contains the full Dell thermal diagnostics package:
- `thermal_results.hostname.1004.900.date.csv` -- GPU temperature, power, clock data
- `dcgmproftester.log` -- GPU stress test log
- `tensor_active_0-7.results` -- per-GPU tensor activity results
- `TSR_SVCTAG_date.zip` -- Dell SupportAssist Technical Support Report

If NFS is available (`/data/thermal-jm-VP-Diag/`), results are also staged there for fast access.

---

## Output Destinations

| Option | What happens |
|--------|-------------|
| **Google Drive** (default) | Per-node zips uploaded to the Reflection Team Drive |
| **Local** | Results stay on each node at `/root/TDAS/` |
| **Node** | All results collected onto one designated node |
| **NFS** | If `/data/` is mounted, results are also staged on shared NFS automatically |

---

## CLI Mode

For automation or repeated runs, both scripts support non-interactive mode:

### Bare Metal
```
bash thermal-pssh-manager.sh run \
  --user ubuntu \
  --key ~/.ssh/id_ed25519 \
  --nodes "10.0.1.50 10.0.1.51 10.0.1.52" \
  --output gdrive
```

### Kubernetes
```
bash thermal-k8s-manager.sh run \
  --control-plane 10.0.1.50 \
  --nodes "node1 node2 node3" \
  --node-ips "node1:10.0.1.50,node2:10.0.1.51,node3:10.0.1.52" \
  --output gdrive
```

### Load nodes from a file
```
bash thermal-pssh-manager.sh run \
  --user ubuntu \
  --key ~/.ssh/id_ed25519 \
  --nodes-file fleet.txt \
  --output gdrive
```

Where `fleet.txt` has one IP per line.
