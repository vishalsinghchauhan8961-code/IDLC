#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Completes device identity setup: uploads the signing CA to DPS and creates an
# X.509 enrollment group.
#
# Why this is a script and not Terraform: the azurerm provider has no
# enrollment-group resource (only the DPS instance and certificate). Rather than
# have someone create the enrollment group in the portal, it is declared here and
# run by the pipeline. Idempotent - safe to re-run on every deploy.
#
# This is what makes acceptance criterion 5 true: attestation is X.509 only, so
# each device presents its own leaf certificate. Symmetric-key enrollment - the
# shared-key path - is never created.
#
# The CA PEM is pulled from Key Vault at run time; it is never committed and
# never printed.
#
# Usage:
#   ./bootstrap-dps.sh <resource-group> <dps-name> <key-vault-name> [secret-name]
# ---------------------------------------------------------------------------
set -euo pipefail

RESOURCE_GROUP="${1:?resource group required}"
DPS_NAME="${2:?dps name required}"
KEY_VAULT="${3:?key vault name required}"
SECRET_NAME="${4:-device-root-ca-pem}"
CERT_NAME="device-root-ca"
ENROLLMENT_GROUP="dosing-devices-x509"

TMP_PEM="$(mktemp)"
trap 'rm -f "${TMP_PEM}"' EXIT

echo "==> Fetching signing CA from Key Vault ${KEY_VAULT}/${SECRET_NAME}"
az keyvault secret show \
  --vault-name "${KEY_VAULT}" \
  --name "${SECRET_NAME}" \
  --query value -o tsv > "${TMP_PEM}"

echo "==> Ensuring CA certificate ${CERT_NAME} is registered with ${DPS_NAME}"
if az iot dps certificate show \
      --resource-group "${RESOURCE_GROUP}" \
      --dps-name "${DPS_NAME}" \
      --certificate-name "${CERT_NAME}" >/dev/null 2>&1; then
  echo "    already present"
else
  az iot dps certificate create \
    --resource-group "${RESOURCE_GROUP}" \
    --dps-name "${DPS_NAME}" \
    --certificate-name "${CERT_NAME}" \
    --path "${TMP_PEM}" \
    --verified true
fi

echo "==> Ensuring X.509 enrollment group ${ENROLLMENT_GROUP}"
if az iot dps enrollment-group show \
      --resource-group "${RESOURCE_GROUP}" \
      --dps-name "${DPS_NAME}" \
      --enrollment-id "${ENROLLMENT_GROUP}" >/dev/null 2>&1; then
  echo "    already present"
else
  az iot dps enrollment-group create \
    --resource-group "${RESOURCE_GROUP}" \
    --dps-name "${DPS_NAME}" \
    --enrollment-id "${ENROLLMENT_GROUP}" \
    --ca-name "${CERT_NAME}" \
    --provisioning-status enabled \
    --allocation-policy hashed \
    --edge-enabled false
fi

echo "==> Done. Devices provision with their own leaf certificate; no shared key exists."
