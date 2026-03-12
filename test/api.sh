#!/bin/bash

URL="https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus"
TOKEN=$(gcloud auth print-access-token)

curl -s -X GET "$URL?pageSize=5000" \
     -H "Authorization: Bearer $TOKEN" | \
     jq '.skus[] | select(.serviceRegions[] == "us-central1" and (.description | contains("Spot")) and (.description | contains("A100") or contains("A2 Instance")))'

curl -s -X GET "$URL?pageSize=5000" \
     -H "Authorization: Bearer $TOKEN" | \
     jq -r '.skus[] |
     select(.serviceRegions[] == "us-central1" and (.description | contains("Spot"))) |
     [
       .description,
       ((.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.units | tonumber) +
        (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos / 1000000000)),
       .pricingInfo[0].pricingExpression.usageUnit
     ] | @tsv' | column -t -s $'\t'

