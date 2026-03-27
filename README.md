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
# test SSH to a node
ssh -i ~/.ssh/your_key ubuntu@NODE_IP "hostname && sudo whoami"
# should print the hostname and "root"
```

If that doesn't work on ANY node, the script will fail on that node.

### Kubernetes Version -- What You Need

1. **Your laptop/Mac** with SSH access to the K8s control plane node
2. **The control plane's public IP** (you'll enter it when prompted)
3. **The public IP for each worker node** (for collecting results after the test)
4. **Your SSH key's public key in `~/.ssh/authorized_keys`** on each node (needed for result collection -- K8s handles the actual test execution)
5. **NVIDIA GPU Operator** running in the cluster
6. **Docker** installed on the nodes (the script builds a container image on first run)

The K8s version uses sshv (if available) or standard SSH to reach nodes. It auto-detects which method works.

---

## How It Works

1. You run the script **on your laptop**
2. The script connects to your nodes via SSH
3. It deploys and runs a 15-minute GPU thermal stress test on all nodes in parallel
4. While the test runs, it collects Dell SupportAssist TSR reports
5. After completion, it packages all results into a single zip
6. Optionally uploads the zip to Google Drive

Total runtime: approximately 25-30 minutes per run.

---

## Output Format

The script produces one zip file containing individual per-node zips:

```
sea1-20260327-124745.zip
  |-- g329-7871FZ3.zip       (hostname-ServiceTag)
  |-- g330-DV42FZ3.zip
```

Each node zip contains the full Dell thermal diagnostics package:
- `thermal_results.hostname.1004.900.date.csv` -- GPU temperature, power, clock data
- `dcgmproftester.log` -- GPU stress test log
- `tensor_active_0-7.results` -- per-GPU tensor activity results
- `TSR_SVCTAG_date.zip` -- Dell SupportAssist Technical Support Report

This output format is compatible with Dell's thermal analysis tools.

---

## Output Destinations

When prompted for output destination, you can choose:

| Option | What happens |
|--------|-------------|
| **Local** | Results stay on each node at `/root/TDAS/` -- you collect manually |
| **Node** | All results are collected onto one designated node |
| **Google Drive** | Results are uploaded to the Reflection Team Drive (password required) |
| **FTP** | Results are uploaded to an FTP server you specify |

### Google Drive Password

When you select Google Drive as the output, you'll be prompted for a password on first use. This password decrypts the embedded Google Drive credentials. The password is saved locally so you won't be asked again on subsequent runs.

Contact your team lead for the password.

---

## SSH Proxy / Jump Host

Some nodes can't be reached via their public IP and require a jump host. Both scripts handle this automatically:

1. The script tries direct SSH to each node
2. If direct SSH fails, it prompts you for the node's **private IP**
3. It then routes through the jump host using that private IP
4. This is cached for the session -- you only enter it once per node

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

---

## Troubleshooting

**"SSH connection failed"** -- Your SSH key isn't authorized on the node. Add your public key to `~/.ssh/authorized_keys` on that node.

**"sudo password required"** -- The SSH user needs passwordless sudo. Add `ubuntu ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers` on the node.

**"Too many authentication failures"** -- Too many SSH keys in your agent. Use `--key` to specify the exact key.

**"Wrong Google Drive password"** -- Contact your team lead for the correct password.

**"SupportAssist job already running"** -- A previous TSR collection is still running on the iDRAC. Wait for it to finish or clear it with `sudo racadm jobqueue delete -i JID_CLEARALL` on the node.
