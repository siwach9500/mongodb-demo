# MongoDB 3-Node Replica Set: Terraform + Ansible + Jenkins + SSM

A demo project that builds a highly available MongoDB replica set on AWS with one click.

- **Terraform** creates the servers, IAM role and S3 bucket.
- **Ansible** installs MongoDB and builds the replica set.
- **Jenkins** runs everything from one pipeline.
- **AWS Systems Manager (SSM)** is used for access. There is **no SSH, no key pair and no bastion host**, and no inbound ports are open.
- The Ansible inventory is **dynamic**. It asks AWS for the running instances every run, so after `terraform destroy` and `terraform apply` the new instance IDs and IPs are picked up automatically.

> **Demo only.** MongoDB authentication is disabled and data lives on the root disk.
> Do not use this setup for real data.

## Architecture

```
Jenkins job
   |
   |-- 1. terraform apply
   |        3 x EC2 (Ubuntu 22.04, one per subnet) + IAM role for SSM
   |        + S3 bucket (used by Ansible's SSM connection)
   |
   |-- 2. wait until all 3 instances are "Online" in SSM
   |
   |-- 3. ansible-playbook (dynamic inventory, connection over SSM)
   |        install MongoDB 7.0, write config, rs.initiate, insert demo doc
   |
   '-- 4. result: 1 PRIMARY + 2 SECONDARY
```

| Part | Detail |
|---|---|
| Region | ap-south-1 |
| Network | Default VPC, security group allows port 27017 only between the 3 nodes |
| Servers | 3 x t3.small, Ubuntu 22.04 |
| MongoDB | 7.0, replica set name `rs0` |
| Access | SSM Session Manager only |

## Project structure

```
mongo-demo/
|-- Jenkinsfile              # pipeline: terraform -> wait for SSM -> ansible
|-- .gitignore
|-- README.md
|-- terraform/
|   `-- main.tf              # EC2, security group, IAM role, S3 bucket
`-- ansible/
    |-- ansible.cfg
    |-- aws_ec2.yml          # dynamic inventory (reads live EC2 data)
    `-- site.yml             # installs MongoDB and builds the replica set
```

## How the automatic inventory works

Nothing about the servers is stored in a file. `ansible/aws_ec2.yml` queries the EC2 API every run
and selects instances tagged `Project=mongo-demo` that are `running`. From the tags and instance data it builds:

| Variable | Source | Used for |
|---|---|---|
| `ansible_host` | instance ID | SSM connection target |
| `mongo_private_ip` | private IP | MongoDB bind address and replica set member list |
| `ansible_aws_ssm_bucket_name` | `SsmBucket` tag | file transfer bucket |
| `mongo_node_index` | `NodeIndex` tag | chooses node 1 for replica set setup |

After `destroy` and `apply` the instances have new IDs and IPs, and the inventory finds them on its own.

## Prerequisites

On the machine that runs Jenkins (as the `jenkins` user):

- AWS credentials with rights for EC2, IAM, S3 and SSM
- Terraform, AWS CLI v2, `jq`
- Session Manager plugin
- Python venv with Ansible and the AWS collections

```bash
# AWS credentials for the jenkins user
sudo su jenkins -s /bin/bash
aws configure                      # region: ap-south-1
aws sts get-caller-identity        # must print your account

# Ansible environment
python3 -m venv /var/lib/jenkins/ansible-venv
source /var/lib/jenkins/ansible-venv/bin/activate
pip install --upgrade pip
pip install ansible-core boto3 botocore
ansible-galaxy collection install amazon.aws community.aws --force

# Session Manager plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o ssm.deb
sudo dpkg -i ssm.deb
```

The default VPC must exist:

```bash
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region ap-south-1 --query 'Vpcs[0].VpcId'
# if it prints null:
aws ec2 create-default-vpc --region ap-south-1
```

## Run it manually (without Jenkins)

```bash
source ~/ansible-venv/bin/activate

# 1. Infrastructure
cd terraform
terraform init
terraform apply

# 2. Wait ~2 minutes, then check all 3 are Online
aws ssm describe-instance-information --region ap-south-1 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table

# 3. Inventory check
cd ../ansible
ansible-inventory --graph
ansible role_mongodb -c community.aws.aws_ssm -m ping

# 4. Build the replica set
ansible-playbook site.yml
```

## Run it from Jenkins

1. Create a **Pipeline** job named `mongo-demo`.
2. Pipeline definition: *Pipeline script from SCM*, Git, branch `*/main`, script path `Jenkinsfile`.
3. Click **Build with Parameters**.
   - `ACTION = apply` creates everything.
   - `ACTION = destroy` deletes everything.

Do not clean the Jenkins workspace between runs, because the Terraform state file is stored there.

## Demo: replication

Find the instance IDs:

```bash
aws ec2 describe-instances --region ap-south-1 \
  --filters "Name=tag:Project,Values=mongo-demo" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PrivateIpAddress]' \
  --output table
```

Open a session (no SSH) and check the members:

```bash
aws ssm start-session --target <instance-id> --region ap-south-1
mongosh --quiet
```
```javascript
rs.status().members.forEach(m => print(m.name + "  ->  " + m.stateStr))
```

On the **PRIMARY**:

```javascript
use shop
db.orders.insertOne({ item: "laptop", qty: 1 })
```

On a **SECONDARY** (in a second terminal):

```javascript
db.getMongo().setReadPref("secondaryPreferred")
use shop
db.orders.find()
```

The document appears on the secondary. A write attempted on the secondary fails with `not primary`.

## Demo: primary failover

**Graceful switch.** On the primary:

```javascript
rs.stepDown(60)
```

**Crash simulation.** On the primary's shell:

```bash
sudo systemctl stop mongod
```

On another node, run the status command again. After about 5 to 15 seconds another node becomes `PRIMARY`.
Insert a document on the new primary to show writes continue.
Bring the old node back with `sudo systemctl start mongod`. It rejoins as a `SECONDARY` and catches up.

Never stop two of the three nodes at once. Without a majority no primary can be elected.

## Demo: rebuild with a fresh inventory

1. Run the Jenkins job with `ACTION = destroy`.
2. Run it again with `ACTION = apply`.
3. In the console output, `ansible-inventory --graph` now lists the new instances,
   and the replica set is rebuilt with the new IPs. No file was edited.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `ansible-inventory` shows no hosts | Instances not running yet, or the `Project=mongo-demo` tag is missing |
| Ping fails with a plugin error | Session Manager plugin or `community.aws` collection missing for that user |
| Ping times out | SSM agent not online yet. Wait 1-3 minutes and re-check |
| `NoCredentials` in Jenkins | The `jenkins` user has no AWS credentials. Run `aws configure` as `jenkins` |
| `apt` errors on instances | Instance has no outbound internet. Check `associate_public_ip_address = true` |
| Playbook waits forever for PRIMARY | Nodes cannot reach each other on 27017. Check the security group self rule |
| `Cannot send input after starting communication` | Old system `community.aws` collection. Use the venv install above |
| Warning: `tags` host variable is deprecated | Use `ec2_tags` in `aws_ec2.yml` (already done) |
| `git push` rejected, file over 100 MB | `.terraform/` was committed. Check `.gitignore` and remove it from Git |

## Cleanup

```bash
# from Jenkins: ACTION = destroy
# or manually:
cd terraform && terraform destroy
```

Also delete any IAM user and access key you created only for this demo.

## Known limitations (demo choices)

- No MongoDB authentication or TLS
- Data is on the root EBS disk and is deleted on destroy
- Terraform state is local to the Jenkins workspace
- Single region, default VPC, public IPs for outbound internet only (no inbound rules)
