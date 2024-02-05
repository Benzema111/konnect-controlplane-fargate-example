#!/bin/bash

echo "> We are in Konnect Region: '${KONNECT_REGION}'"

export KPAT=$(aws secretsmanager get-secret-value --secret-id ${KONNECT_PAT_SECRET_ARN} --output text --query 'SecretString')

# load array into a bash array
# output each entry as a single line json
readarray CONTROL_PLANES < <(yq -o=j -I=0 '.control_planes[]' control-planes.yaml )

if [ "$MODE" == "apply" ]
then
  echo -e "- control_planes:\n" > control_planes_konnect.json

  for CONTROL_PLANE in "${CONTROL_PLANES[@]}";
  do
    # identity mapping is a single json snippet representing a single entry
    export name=$(echo "$CONTROL_PLANE" | yq '.name' -)
    export desc=$(echo "$CONTROL_PLANE" | yq '.description' -)
    export aws_account=$(echo "$CONTROL_PLANE" | yq '.aws_account' -)
    export aws_region=$(echo "$CONTROL_PLANE" | yq '.aws_region' -)
    export ecs_cluster=$(echo "$CONTROL_PLANE" | yq '.ecs_cluster' -)

    echo ""
    echo "> Looking up control-plane: $name"
    export AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --request GET \
      --header 'Accept: application/json' \
      --header "Authorization: Bearer ${KPAT}" \
      --url "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes?filter%5Bname%5D%5Beq%5D=${name}")

    if [[ "$AUTH_STATUS" == 401 ]]
    then
      echo "!! Konnect PAT token is invalid, missing, or expired"
      exit 1
    fi

    export FOUND_STATUS=$(curl -s --request GET \
      --header 'Accept: application/json' \
      --header "Authorization: Bearer ${KPAT}" \
      --url "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes?filter%5Bname%5D%5Beq%5D=${name}" | yq -P e '.meta.page.total')

    if [[ "$FOUND_STATUS" < 1 ]]
    then
      echo "> Control Plane $name does not exist - creating it..."

      cat <<EOF > control_plane.json
{
  "name": "$name",
  "description": "$description",
  "cluster_type": "CLUSTER_TYPE_HYBRID",
  "labels": {
    "aws_region": "$aws_region",
    "aws_account": "$aws_account",
    "ecs_cluster": "$ecs_cluster"
  }
}
EOF

      export CREATED_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --request POST \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer ${KPAT}" \
        --url "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -d @control_plane.json)

      if [[ "$CREATED_STATUS" != 201 ]]
      then
        echo "!! Control Plane creation failed, status: $CREATED_STATUS"
        exit 1
      fi
    fi

    sleep 1

    echo "> Reading back new control plane info for Terraform"
    curl -s --request GET \
      --header 'Accept: application/json' \
      --header "Authorization: Bearer ${KPAT}" \
      --url "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes?filter%5Bname%5D%5Beq%5D=${name}" |
      yq -p=json - >> control_planes_konnect.json

  done

  
fi
