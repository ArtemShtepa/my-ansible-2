#!/usr/bin/env bash
export TF_VAR_YC_CLOUD_ID=$(yc config get cloud-id)
export TF_VAR_YC_FOLDER_ID=$(yc config get folder-id)
export TF_VAR_YC_ZONE=$(yc config get compute-default-zone)

init() {
    terraform init
}

apply() {
    terraform apply --auto-approve
}

destroy() {
    terraform destroy --auto-approve
}

clear() {
    terraform destroy --auto-approve
    rm -rf .terraform*
    rm terraform.tfstate*
}

run() {
    ansible-playbook -i inventory/prod.yml site.yml
}

lint() {
    ansible-lint site.yml
}

if [ $1 ]; then
    $1
else
    echo "Possible commands:"
    echo "  init - Terraform init"
    echo "  apply - Terraform apply"
    echo "  destroy - Terraform destroy"
    echo "  clear - Clear files from Terraform"
    echo "  run - Run Absible playbook"
    echo "  lint - Run Ansible-Lint"
fi
