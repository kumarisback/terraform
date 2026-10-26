#!/usr/bin/env bash
# Sets the value of a secret Terraform creates empty (01-infra main.tf,
# aws_secretsmanager_secret.out_of_band), so the value never passes through
# Terraform or its state.
#
#   ./scripts/set-secret.sh <env> mongodb           reads MONGO_URI from the terminal (not echoed)
#   ./scripts/set-secret.sh <env> jwt-signing-key   generates a new 2048-bit RSA key
#
# <env> is dev, staging or prod. Needs the AWS CLI with access to Secrets
# Manager in that environment's account, and openssl.
#
# Rotating the signing key signs everyone out: External Secrets copies the
# new key into the cluster within an hour (refreshInterval), user-service
# picks it up on its next restart, and tokens signed with the old key stop
# verifying. Restart user-service to apply it at once:
#   kubectl rollout restart deployment user-service -n <namespace>
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|prod> <mongodb|jwt-signing-key>" >&2; exit 2; }
[ $# -eq 2 ] || usage
ENV="$1"; NAME="$2"
case "${ENV}" in dev|staging|prod) ;; *) usage ;; esac
SECRET_ID="microservices/${ENV}/${NAME}"
REGION="${AWS_REGION:-us-east-1}"

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
chmod 700 "${workdir}"

case "${NAME}" in
  mongodb)
    read -r -s -p "MONGO_URI for ${ENV}: " uri
    echo
    [ -n "${uri}" ] || { echo "empty MONGO_URI" >&2; exit 1; }
    # JSON-encoded by ruby so quotes or backslashes in the URI can't break it.
    MONGO_URI="${uri}" ruby -rjson -e 'print({ "MONGO_URI" => ENV.fetch("MONGO_URI") }.to_json)' > "${workdir}/value"
    ;;
  jwt-signing-key)
    (umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${workdir}/value" 2>/dev/null)
    ;;
  *) usage ;;
esac

aws secretsmanager put-secret-value --region "${REGION}" --secret-id "${SECRET_ID}" \
  --secret-string "file://${workdir}/value" --query VersionId --output text > /dev/null
echo "✅ ${SECRET_ID} updated."
