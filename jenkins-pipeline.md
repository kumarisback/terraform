# Jenkins pipeline for Terraform

This repository now includes a Jenkins pipeline definition in Jenkinsfile.

## What it does

- checks out the repository
- runs terraform fmt -check -recursive
- runs terraform init -backend=false
- runs terraform validate
- runs terraform plan for the dev environment

## Jenkins setup

Create a Jenkins pipeline job and point it to this repository.

Use the repository root as the workspace and let Jenkins run the Jenkinsfile automatically.
