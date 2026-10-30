pipeline {
  agent any

  parameters {
    choice(name: 'ACTION', choices: ['apply', 'backup', 'destroy'],
           description: 'apply = build + backup, backup = backup only, destroy = delete servers')
  }

  environment {
    AWS_DEFAULT_REGION = 'ap-south-1'
    PATH = "/var/lib/jenkins/ansible-venv/bin:${env.PATH}"
  }

  options { disableConcurrentBuilds() }

  stages {
    stage('Terraform') {
      when { expression { params.ACTION in ['apply', 'destroy'] } }
      steps {
        dir('terraform') {
          sh 'terraform init -input=false'
          sh "terraform ${params.ACTION} -auto-approve -input=false"
        }
      }
    }

    stage('Wait for SSM') {
      when { expression { params.ACTION == 'apply' } }
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          dir('terraform') {
            sh '''
              IDS=$(terraform output -json instance_ids | jq -r 'join(",")')
              until [ "$(aws ssm describe-instance-information \
                  --filters Key=InstanceIds,Values=$IDS \
                  --query 'length(InstanceInformationList[?PingStatus==`Online`])' \
                  --output text)" = "3" ]; do
                echo "waiting for 3 servers to come online in SSM..."
                sleep 15
              done
            '''
          }
        }
      }
    }

    stage('Ansible playbook') {
      when { expression { params.ACTION == 'apply' } }
      steps {
        dir('ansible') {
          sh 'ansible-inventory --graph'
          sh 'ansible-playbook site.yml'
        }
      }
    }

    stage('Backup to S3') {
      when { expression { params.ACTION in ['apply', 'backup'] } }
      steps {
        dir('ansible') {
          sh 'ansible-playbook backup.yml'
        }
      }
    }
  }
}
