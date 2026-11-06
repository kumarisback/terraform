#!/usr/bin/env bash
# Sets the value of a secret Terraform creates empty (01-infra main.tf,
# aws_secretsmanager_secret.out_of_band), so the value never passes through
# Terraform or its state.
#
#   ./scripts/set-secret.sh <env> mongodb           reads MONGO_URI from the terminal (not echoed)
#   ./scripts/set-secret.sh <env> jwt-signing-key   generates a new 2048-bit RSA key, and
#                                                   writes its public key to jwt-public-key
#                                                   (Kong checks tokens with it, step 17)
#   ./scripts/set-secret.sh <env> jwt-public-key    writes the public key of the signing key
#                                                   already there, without rotating it
#
# <env> is dev, staging or prod. Needs the AWS CLI with access to Secrets
# Manager in that environment's account, and openssl.
#
# Rotating the signing key signs everyone out: External Secrets copies the
# new key into the cluster within an hour (refreshInterval), user-service
# picks it up on its next restart, and tokens signed with the old key stop
# verifying. Kong checks tokens with the public key (gitops Secret
# user-service-jwt), refreshed on the same schedule: until it has the new
# one, it refuses the new tokens. To apply both at once, refresh both, then
# restart user-service:
#   kubectl annotate externalsecret jwt-signing-key user-service-jwt -n <namespace> force-sync="$(date +%s)" --overwrite
#   kubectl rollout restart deployment user-service -n <namespace>
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|prod> <mongodb|jwt-signing-key|jwt-public-key>" >&2; exit 2; }
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
    openssl pkey -in "${workdir}/value" -pubout -out "${workdir}/public"
    ;;
  jwt-public-key)
    # From the signing key in Secrets Manager; the private key stays in
    # this temporary directory, never on the terminal.
    (umask 077 && aws secretsmanager get-secret-value --region "${REGION}" \
      --secret-id "microservices/${ENV}/jwt-signing-key" --query SecretString --output text > "${workdir}/private")
    openssl pkey -in "${workdir}/private" -pubout -out "${workdir}/value"
    ;;
  *) usage ;;
esac

aws secretsmanager put-secret-value --region "${REGION}" --secret-id "${SECRET_ID}" \
  --secret-string "file://${workdir}/value" --query VersionId --output text > /dev/null
echo "✅ ${SECRET_ID} updated."

# The public half goes with it, so Kong never checks tokens with an old key.
if [ -f "${workdir}/public" ]; then
  aws secretsmanager put-secret-value --region "${REGION}" --secret-id "microservices/${ENV}/jwt-public-key" \
    --secret-string "file://${workdir}/public" --query VersionId --output text > /dev/null
  echo "✅ microservices/${ENV}/jwt-public-key updated."
fi
