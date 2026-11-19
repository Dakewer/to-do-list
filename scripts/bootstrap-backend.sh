#!/bin/bash
# Crea (una sola vez) el bucket S3 que guarda el tfstate. Uso:
#   ./scripts/bootstrap-backend.sh <nombre-unico-de-bucket> [region]
set -euo pipefail

BUCKET="${1:?Uso: $0 <bucket> [region]}"
REGION="${2:-us-east-1}"

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION"
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Bucket listo: $BUCKET (guardalo como secret TF_STATE_BUCKET en GitHub)"
