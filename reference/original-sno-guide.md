# **OpenShift Virtualization 4.21 Airgapped SNO Deployment & Compliance Guide**

## 

## **1\. Executive Summary & Architecture**

This guide provides an end-to-end deployment plan and technical procedure for evaluating **OpenShift Virtualization 4.21** in an airgapped environment using a **Single Node OpenShift (SNO)** architecture.

### **Key Architectural Highlights**

* **Cluster Topology:** Single Node OpenShift (SNO) deployed on high-performance bare metal.  
* **Storage Engine:** OpenShift Local Volume Manager Storage (LVMS / TopolVM) thin-provisioning the node’s local 11TB NVMe/SSD drive for low-latency VM performance.  
* **Security & Cryptography Baseline:** **FIPS 140-3 Mode Enabled globally** at cluster initialization, enforcing FIPS-validated cryptographic modules across the Red Hat Enterprise Linux CoreOS (RHCOS) kernel, etcd, and OpenShift API services.  
* **Compliance Framework:** Automated DISA-STIG alignment via the **Compliance Operator**, host file integrity monitoring via the **File Integrity Operator (AIDE)**


**Architecture Pivot Note:** In an SNO topology, cross-node VM Live Migration is not applicable due to single-node physical limits. The evaluation focuses on **raw storage IOPS using LVMS**, **CPU/Memory hot-plugging**, **declarative VM management**, and **disaster recovery snapshotting via OADP**.

## **2\. Project Schedule & Milestones**

| Phase | Milestone | Focus Areas | Duration |
| :---- | :---- | :---- | :---- |
| Phase 1 | Mirroring | Binary acquisition & oc-mirror execution. | Day 1-2 |
| Phase 2 | Registry | Local Quay setup and payload push. | Day 3 |
| Phase 3 | Deployment | Agent ISO generation & SNO installation. | Day 4 |
| Phase 4 | Hardening | Storage, Virt setup & STIG application. | Day 5-6 |
| Phase 5 | Handover | Validation and benchmarks. | Day 7 |

## 

## **3\. Directory Layout for Day-1 & Day-2 Lifecycle Management**

oc-mirror (v2) relies on persistent state files to calculate differentials during future updates. Maintaining separate cache, workspace, and export directories ensures fast, low-bandwidth Day-2 updates without re-downloading the entire base payload.

### 

### **Connected Bastion Host (Internet Access)**

Connected Bastion Host Directory Structure

```
~/ocp-airgap/
├── binaries/                  # oc, openshift-install, oc-mirror tools, pull-secret.json
├── config/                    # Source-of-truth imageset-config.yaml
├── cache/                     # PERSISTENT: Container layer cache (--cache-dir)
├── workspace/                 # PERSISTENT: Metadata & state tracking (--workspace)
└── exports/                   # Transfer archives generated per run
    ├── 2026-08-10_initial_sno/
    └── 2026-11-15_day2_patch/
```

### 

### **Disconnected Bastion Host (Airgapped Quay Registry)**

Disconnected Bastion Host Directory Structure

```
~/ocp-airgap/
├── binaries/                  # Extracted CLI executables
├── imports/                   # Landing folder for incoming transferred archives
│   └── 2026-08-10_initial_sno/
├── registry-data/             # Local Quay storage path (/opt/quay)
└── cluster-resources/         # Generated IDMS, ITMS, and CatalogSource manifests
```

## 

## 

## 

## **4\. Phase 1: Connected Host Preparation & Image Mirroring**

Perform these steps on an internet-connected RHEL 9 system.

### 

### **Step 1: Download Required Executables**

Create the workspace and download the required tool binaries:

Binary Acquisition

```sh
# Setup directories
mkdir -p ~/ocp-airgap/{binaries,config,cache,workspace,exports}
cd ~/ocp-airgap/binaries

# 1. OpenShift Client (oc)
curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.21/openshift-client-linux.tar.gz

# 2. OpenShift Mirror CLI Plugin v2 (oc-mirror)
curl -LO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.rhel9.tar.gz

# 3. Red Hat Mirror Registry (Standalone Quay)
curl -LO https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/mirror-registry/1.3.9/mirror-registry.tar.gz

# Extract tools to path
sudo tar -xzvf openshift-client-linux.tar.gz -C /usr/local/bin oc
sudo tar -xzvf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror


# handle FIPS
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update

```

Place your official Red Hat pull secret into \~/ocp-airgap/binaries/pull-secret.json. You can obtain your pull secret from: [https\://console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads) located at the bottom of the downloads list.

### 

### **Step 2: Create Size-Optimized** imageset-config.yaml

This configuration prunes unnecessary architectures and z-stream patch histories while including virtualization drivers, out-of-the-box boot sources, and STIG compliance operators.

imageset-config.yaml

```
cat <<EOF > ~/ocp-airgap/config/imageset-config.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    architectures:
      - "amd64"
    channels:
      - name: stable-4.21
        type: ocp
        minVersion: 4.21.26
        maxVersion: 4.21.26
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
      packages:
        - name: lvms-operator
          channels:
            - name: stable-4.21
        - name: kubevirt-hyperconverged
          channels:
            - name: stable
        - name: kubernetes-nmstate-operator
          channels:
            - name: stable
        - name: oadp-operator
          channels:
            - name: stable-1.4
        - name: openshift-gitops-operator
          channels:
            - name: latest
        - name: compliance-operator
          channels:
            - name: stable
        - name: file-integrity-operator
          channels:
            - name: stable
        - name: rhacs-operator
          channels:
            - name: stable
  additionalImages:
    - name: registry.redhat.io/rhel9/support-tools:latest
    - name: registry.redhat.io/rhel9/rhel-guest-image:latest
    - name: registry.redhat.io/openshift4/ose-must-gather:latest
    - name: registry.redhat.io/ubi9/ubi:latest
    - name: registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v4.21
    # The following are for the Boot Images for various VM OS's (For OpenShift Virtualization). Feel free to remove/update as needed
    - name: registry.redhat.io/rhel8/rhel-guest-image:8.4.0
    - name: registry.redhat.io/rhel8/rhel-guest-image:8.6.0
    - name: registry.redhat.io/rhel8/rhel-guest-image:8.8.0
    - name: registry.redhat.io/rhel8/rhel-guest-image:8.10.0
    - name: registry.redhat.io/rhel8/rhel-guest-image:latest
    - name: registry.redhat.io/rhel9/rhel-guest-image:9.2
    - name: registry.redhat.io/rhel9/rhel-guest-image:9.4
    - name: quay.io/containerdisks/centos:7-2009
    - name: quay.io/containerdisks/centos-stream:8-latest
    - name: quay.io/containerdisks/centos-stream:9-latest
EOF
```

### 

### **Step 3: Execute Initial Image Mirroring**

Execute oc-mirror pointing to the persistent cache and workspace directories:

Initial Mirroring

```sh
cd ~/ocp-airgap

# if tmux is available enable linger so our tmux session doesn't
# get killed if we lose connectivity
sudo loginctl enable-linger $USER
systemd-run --scope --user tmux new -s mirror

# run oc mirror 
oc-mirror --v2 --config config/imageset-config.yaml \
  --cache-dir cache \
  --authfile binaries/pull-secret.json \
  file://exports/2026-09-16_initial_sno

# if disconnected, reconnect and:
tmux attach -t mirror
```

Package the  exports/ along with binaries/ and config/  to your portable storage medium for transfer to the airgapped environment. 

Prepare tarball

```sh
cd ~

tar -czvf ocp-airgap-091626.tar.gz ocp-airgap/exports ocp-airgap/binaries ocp-airgap/config
```

**Verify the size of your archive and the amount of available space on the destination partition.** For future mirrors you will only need to transfer over the current export folder.

## 

## **5\. Phase 2: Airgapped Bastion Setup & Registry Population**

Perform these steps on the **Airgapped Bastion Host**. 

### 

### **Step 1: Install Red Hat Mirror Registry (Quay)**

Extract binaries and install the local container registry:

Registry Installation

```sh
cd /path/to/transferred/bundle/
tar -xzvf ocp-airgap-091626.tar.gz

cd ocp-airgap/binaries

tar -xzvf mirror-registry.tar.gz

# In order to get around STIG setting umask too restrictive we will use a system override to fix permissions on directories created by the install as part of the startup of the container that needs access to them
mkdir -p ~/.config/systemd/user/quay-app.service.d
cat > ~/.config/systemd/user/quay-app.service.d/fix-perms.conf << 'EOF'
[Service]
ExecStartPre=/bin/bash -c 'chmod -R 755 /data/quay/quay-config /data/quay/quay-rootCA; chmod 644 /data/quay/quay-config/* /data/quay/quay-rootCA/*'
EOF
systemctl --user daemon-reload

# Update firewall
firewall-cmd --add-port 8443/tcp --permanent
firewall-cmd --reload

# make sure to point --quayRoot at a partition with enough disk space (500GB min)
# replace bastion.airgap.local with your own preferred regsitry name
# umask is needed due to STIG umask being too restrictive
umask 0022 && ./mirror-registry install \
  --quayHostname bastion.airgap.local \
  --quayRoot /opt/quay \
  --initPassword '<REDACTED-SET-YOUR-OWN>'

# Add Quay RootCA to machines ca trust
# adjust paths if you changed quayRoot
sudo cp -v /data/quay/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/

sudo update-ca-trust
```

### 

### **Step 2: Create Mirror Registry Pull Secret**

Generate a mirror pull secret containing authentication for your local Quay instance:

Push to Local Registry

```sh
QUAY_AUTH=$(echo -n 'init:<REDACTED-SET-YOUR-OWN>' | base64 -w0)

echo "{\"auths\":{\"bastion.airgap.local:8443\":{\"auth\":\"$QUAY_AUTH\"}}}" > mirror-pull-secret.json

cd /path/to/transferred/bundle/ocp-airgap/binaries

# Extract tools to path
sudo tar -xzvf openshift-client-linux.tar.gz -C /usr/local/bin oc
sudo tar -xzvf oc-mirror.rhel9.tar.gz -C /usr/local/bin oc-mirror
sudo chown root:root /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo chmod 0755 /usr/local/bin/oc /usr/local/bin/oc-mirror


# handle FIPS
sudo restorecon -v /usr/local/bin/oc /usr/local/bin/oc-mirror
sudo fapolicyd-cli --file add /usr/local/bin/oc
sudo fapolicyd-cli --file add /usr/local/bin/oc-mirror
sudo fapolicyd-cli --update

# make sure to set a cache-dir to point at a location with a large amount of space (greater than 200GB)
umask 0022 && oc-mirror --v2 --from file:///path/to/transferred/ocp-airgap/exports/2026-08-10_initial_sno \
  docker://bastion.airgap.local:8443 \
  --authfile mirror-pull-secret.json -c ../config/imageset-config.yaml --cache-dir=/path/to/cache
```

## 

## 

## **6\. Phase 3: FIPS-Enabled SNO Installation**

Perform these steps on the **Airgapped Bastion Host**.

### 

### **Step 1: Extract the FIPS capable installation binary**

Use the oc adm release extract command to pull the openshift-install binary from your local mirror registry.

Extract FIPS capable Installer

```sh
# Set environment variables for your registry and version
export OCP_VERSION=4.21.26
export LOCAL_REGISTRY=bastion.airgap.local:8443
export LOCAL_REPO=openshift/release-images
export PULL_SECRET=/path/to/ocp-airgap/binaries/mirror-pull-secret.json

cd /path/to/ocp-airgap/binaries

# Extract the binary
oc adm release extract -a ${PULL_SECRET} \
  --command=openshift-install-fips \
  --from="${LOCAL_REGISTRY}/${LOCAL_REPO}:${OCP_VERSION}-x86_64" \
  --to="./" \
  --insecure=true \
--idms-file=exports/2026-09-16_initial_sno/working-dir/cluster-resources/idms-oc-mirror.yaml

# Make executable
chmod +x openshift-install-fips
```

### 

### **Step 2: Create Installation Configurations**

Create a dedicated deployment directory and construct your cluster manifests:

Create Configs

```
# from the root of your ocp-airgap tree
mkdir -p sno-installer && cd sno-installer
cat <<EOF > install-config.yaml
apiVersion: v1
baseDomain: airgap.local
metadata:
  name: ocp
fips: true
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.90.0.0/24
#   clusterNetwork:       # OPTIONAL: override default pod network
#   - cidr: 10.128.0.0/14
#     hostPrefix: 23
#   serviceNetwork:       # OPTIONAL: override default service CIDR
#   - 172.30.0.0/16
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
platform:
  none: {}
pullSecret: '$(cat /path/to/transferred/ocp-airgap/binaries/mirror-pull-secret.json)'
sshKey: '$(cat ~/.ssh/id_rsa.pub)'
additionalTrustBundle: |
$(cat /opt/quay/quay-rootCA/rootCA.pem | sed 's/^/  /')
EOF
```

### 

Edit the install-config.yaml for your particular use case and environment.

Create your agent-config.yaml for your particular hardware profile. Here is an example:

agent-config.yaml

```
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ocp
rendezvousIP: 10.0.2.100
hosts:
  - hostname: node-0.ocp.sandboxxxx.opentlc.com
    role: master
    interfaces:
      - name: enp1s0
        macAddress: <MAC_ADDRESS>
    rootDeviceHints:
      deviceName: /dev/vda
    networkConfig:
      interfaces:
        - name: enp1s0
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 10.0.2.100
                prefix-length: 24
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - 10.0.2.10
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.2.1
            next-hop-interface: enp1s0

```

### 

### **Step 3: Back Up Configurations (Mandatory)**

⚠️ **CRITICAL REQUIREMENT:** The openshift-install binary **consumes and deletes** install-config.yaml and agent-config.yaml during ISO generation. Back up your configuration files to a secure directory before proceeding.

Backup Configs

```sh
mkdir -p ~/sno-installer-backups

cp install-config.yaml ~/sno-installer-backups/install-config.yaml.bak

cp agent-config.yaml ~/sno-installer-backups/agent-config.yaml.bak

# Lock down once you have a working install
# chmod 600 ~/sno-installer-backups/*
```

### 

### **Step 4: Generate Boot ISO & Execute Installation**

1. Generate ISO

```sh
cd ~/sno-installer

openshift-install-fips agent create image --dir .
```

2. Mount the generated agent.x86\_64.iso to the bare metal target host via out-of-band management (**iDRAC / iLO / IPMI**).  
3. Boot the target server from Virtual Media.  
4. Monitor installation progress from the Bastion host:

Wait for Install

```

openshift-install-fips agent wait-for bootstrap-complete --dir ~/sno-installer

openshift-install-fips agent wait-for install-complete --dir ~/sno-installer

```

## 

## 

## **7\. Phase 4: Day-2 Storage, Virtualization, & STIG Hardening**

Set export KUBECONFIG=\~/sno-installer/auth/kubeconfig on the Bastion host.

### 

### **Step 1: Verify FIPS Mode Activation**

Confirm FIPS enforcement on both the cluster configuration and node OS kernel:

Bash \- Verification

```sh
oc get cm cluster-config-v1 -n kube-system -o json | jq -r '.data."install-config"' | grep -i "fips"

oc debug node/sno-node.airgap.local -- chroot /host && cat /proc/sys/crypto/fips_enabled
```

### 

### **Step 2: Apply Generated Cluster Resources & Configure Catalogs**

Apply the catalog sources and image digest mirror configurations generated during the mirroring process:

Apply Cluster Resources

```sh
export KUBECONFIG=~/sno-installer/auth/kubeconfig
cd ~/ocp-airgap/exports/2026-09-16_initial_sno/working-dir/cluster-resources/
oc apply -f .

# disable default catalog sources
oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true}}'
```

### **Step 3: Configure Local Volume Manager Storage (LVMS) for 11TB Drive**

Install the LVM Storage Operatoro

1. **Install the LVM Storage Operator:**  
   1. Navigate to **Ecosystem** \> **Software Catalog** in the left-hand navigation menu.  
   2. Search for **LVM Storage** (or LVMS) and click on the operator tile.  
   3. Click **Install**.  
   4. Under **Update channel**, select **stable-4.21**.  
   5. Ensure the **Installed Namespace** is set to the Operator recommended openshift-lvm-storage.  
   6. Click **Install** and wait for the installation status to report "Succeeded".  
2. **Configure the LVMCluster:**

Deploy the LVMCluster CR targeting the node's secondary 11TB local drive (e.g., /dev/nvme1n1 or /dev/sdb):

LVMCluster

```
oc apply -f - <<'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-lvm-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        deviceSelector:
          paths:
            - /dev/vdb
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
EOF

```

### 

### **Step 4: Deploy OpenShift Virtualization via Web Console**

1. **Install the Operator:**  
   1. Navigate to **Operators** \> **OperatorHub** in the left-hand navigation menu.  
   2. Search for **OpenShift Virtualization** and click on the operator tile.  
   3. Click **Install**.  
   4. Under **Update channel**, select **stable**.  
   5. Ensure the **Installation mode** is set to "A specific namespace on this cluster" and the **Installed Namespace** is set to the operator recommended openshift-cnv   
   6. Click **Install** and wait for the operator status to reach "Succeeded".  
2. **Deploy the HyperConverged Custom Resource:**  
   1. Click **Create HyperConverged**.  
   2. A Form/YAML view will appear; the defaults are optimized for evaluation. Click **Create** to initialize the deployment.  
   3. Monitor the status until the "Phase" changes to "Deployed".

**NOTE**: You will get logged out of the UI and the console will go down briefly during the creation of the HyperConverged resource. This is due to UI Plugin getting deployed to the cluster which requires a restart of the console pods.

### **Step 5: Create DataVolumes for Disconnected Boot Sources**

In airgapped or disconnected environments, default VM boot source image streams may fail to update or import from external registries. To resolve this, create DataVolumes pointing directly to your local mirror registry for each required boot image.

1. **Prerequisites:** Verify that required boot images are mirrored and tagged in your local registry (e.g., bastion.airgap.local:8443).  
2. **1\. Verify Mirrored Images and Tags:** Ensure local registry access and image availability for all target operating system boot sources.  
3. **2\. Disable Operator-Managed Boot Sources:** Patch the HyperConverged CR so operator-managed boot sources do not conflict with local DataVolumes:

```sh
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type merge -p '{"spec":{"featureGates":{"disablePreallocation":true},"dataImportCronTemplates":[]}}'
```

4. **3\. Identify the PVC Names:** Check expected PersistentVolumeClaim (PVC) names in the openshift-virtualization-os-images namespace to match your DataVolume definitions.

5. **4\. Create DataVolumes Matching PVC Names:** Apply DataVolume resources pointing directly to your local airgapped registry for CentOS Stream 9, CentOS Stream 8, CentOS 7, RHEL 9, and RHEL 8:

```
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: centos-stream9
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://bastion.airgap.local:8443/containerdisks/centos-stream:9-latest"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: centos-stream8
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://bastion.airgap.local:8443/containerdisks/centos-stream:8-latest"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: centos7
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://bastion.airgap.local:8443/containerdisks/centos:7-2009"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://bastion.airgap.local:8443/rhel9/rhel-guest-image:latest"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel8
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://bastion.airgap.local:8443/rhel8/rhel-guest-image:latest"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
EOF
```

6. **5\. Monitor DataVolume Import Progress:** Track the status of the image imports until all DataVolumes report Succeeded:

```sh
oc get dv -n openshift-virtualization-os-images
```

7. **6\. Verify DataSources Are Ready:** Confirm that the corresponding DataSources in the namespace reflect the imported volumes and are ready for VM provisioning:

```sh
oc get datasource -n openshift-virtualization-os-images
```

#### **Why Not DataImportCrons?**

While DataImportCrons provide automated polling for updated boot images, in strict airgapped environments they often continuously fail or conflict with local image naming conventions if external registries are unreachable. Deploying static DataVolumes directly referencing local registry endpoints ensures deterministic, reliable boot disk provisioning without unnecessary controller reconcile errors.

#### **Why IDMS/ITMS Don't Help Here**

ImageDigestMirrorSet (IDMS) and ImageTagMirrorSet (ITMS) configurations override registry locations for CRI-O container runtime image pulls (such as pod deployments). However, Containerized Data Importer (CDI) imports utilize explicit URL strings defined in DataImportCron or DataVolume specifications rather than standard container pull paths, so IDMS/ITMS mapping rules are not automatically applied during boot source imports.

### **Step 6: Automate DISA-STIG Scan & Hardening**

You can deploy the Compliance Operator and configure scanning either via the CLI or the OpenShift Web Console.  
**Option 1: Using the Web Console (Recommended for UI-based evaluation)**

* **Install the Operator:**  
  * Navigate to **Operators \> OperatorHub**.

  * Search for **Compliance Operator** and click on the tile.  
  * Click **Install**, ensuring the installation namespace is set to openshift-compliance.  
  * Click **Install** and wait for the operator to reach "Succeeded" status.  
* **Deploy the ScanSettingBinding:**  
  * Navigate to **Operators \> Installed Operators** and ensure the project is set to openshift-compliance.  
  * Click on the **Compliance Operator**.  
  * Select the **ScanSettingBinding** tab.  
  * Click **Create ScanSettingBinding**.  
  * Switch to the **YAML view** and replace the existing content with the configuration below, then click **Create**.

**Option 2: Using the CLI**  
Deploy the configuration directly via the terminal:

```json
cat <<EOF | oc apply -f -
apiVersion: compliance.openshift.io/v1alpha1
kind: ScanSettingBinding
metadata:
  name: sno-stig-enforcement
  namespace: openshift-compliance
profiles:
  - name: ocp4-stig
    kind: Profile
    apiGroup: compliance.openshift.io/v1alpha1
  - name: rhcos4-stig
    kind: Profile
    apiGroup: compliance.openshift.io/v1alpha1
settingsRef:
  name: default-auto-apply
  kind: ScanSetting
  apiGroup: compliance.openshift.io/v1alpha1
EOF
```

### 

### **Step 7: Initialize Host File Integrity Monitoring (AIDE)**

Deploy the File Integrity Operator to establish a baseline for system files (/etc, /usr, /boot):

File Integrity

```
cat <<EOF | oc apply -f -
apiVersion: fileintegrity.openshift.io/v1alpha1
kind: FileIntegrity
metadata:
  name: sno-node-aide
  namespace: openshift-file-integrity
spec:
  nodeSelect:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/master
            operator: Exists
EOF
```

## 

## **8\. Phase 5: Day-2 Lifecycle Management Workflow**

For future z-stream updates (e.g., upgrading 4.21.26 to 4.21.28) or adding new operators, follow this incremental workflow:

### 

### **On the Connected Bastion Host:**

1. Edit the existing \~/ocp-airgap/config/imageset-config.yaml (e.g., change maxVersion: 4.21.3).  
2. Run oc-mirror pointing to the **same** cache and workspace paths, outputting to a new export directory:  
   

 Delta Update

```

cd ~/ocp-airgap
oc-mirror --config config/imageset-config.yaml \
  --workspace file://workspace \
  --cache-dir cache \
  --authfile binaries/pull-secret.json \
  file://exports/2026-11-15_day2_patch

```

3. oc-mirror *automatically calculates the delta and downloads only the newly required layers.*

### 

### **On the Airgapped Bastion Host:**

1. Transfer exports/2026-11-15\_day2\_patch into imports/ on the airgapped bastion.  
2. Push the delta update to Quay:

Bash \- Push Delta

```

oc-mirror --from imports/2026-11-15_day2_patch \
  docker://bastion.airgap.local:8443 \
  --authfile mirror-pull-secret.json

```

3. Apply updated cluster manifests to the SNO cluster:

Bash

```

oc apply -f imports/2026-11-15_day2_patch/working-dir/cluster-resources/

```

## 

## 

## 

## 

## 

## 

## **9\. Evaluation Acceptance Checklist**

| Functional Area | Test / Verification Command | Expected Result | Status |
| :---- | :---- | :---- | :---- |
| **Cryptographic Baseline** | cat /proc/sys/crypto/fips\_enabled on node | Returns 1 | \[ \] Pass |
| **Local Storage** | oc get storageclass | lvms-vg1 is listed and default | \[ \] Pass |
| **Disk Performance** | Run fio workload inside guest VM on LVMS | High IOPS / low latency benchmark | \[ \] Pass |
| **Default Boot Sources** | oc get dv \-n openshift-virtualization-os-images | RHEL9 / CentOS templates show Succeeded | \[ \] Pass |
| **Windows Drivers** | Provision Windows VM with VirtIO container disk attached | Storage & network drivers recognized | \[ \] Pass |
| **STIG Scanning** | oc get compliancescan \-n openshift-compliance | Scans complete with auto-remediations | \[ \] Pass |
| **File Integrity** | oc get fileintegrity \-n openshift-file-integrity | Node status reports Active | \[ \] Pass |
| **Config Preservation** | Inspect \~/sno-installer-backups/ | Backed-up .bak config files present | \[ \] Pass |

