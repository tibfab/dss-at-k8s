# This is a subscript for installation-steps.sh
# It creates a script for the DooD container on a shared volume
# to commit the running DSS container to a new image

DSS_IMAGE_TAG=${DSS_VERSION}-$(date +%Y.%m.%d-%H.%M.%S);
COMMIT_SCRIPT=/share/commit-dss.sh
printf "%s\n" "#!/bin/sh" \
    "" \
    "# This script is designed to run in a container on a Kubernetes pod" \
    "# to create a new Docker image from the running DSS node itself." \
    "# Usage: kubectl exec -it \${POD_NAME} --container dood -- <this script> [DSS tag]" \
    "" \
    "if [ \"\$#\" -eq 0 ];" \
    "then" \
    "    DSS_IMAGE_TAG=${DSS_VERSION}-\$(date +%Y.%m.%d-%H.%M.%S)" \
    "else" \
    "    DSS_IMAGE_TAG=\$1" \
    "fi" \
    "" \
    "DSS_CONTAINER=\$(docker container ls | grep k8s_dss_dss-\${DSS_NODE_TYPE} | awk '{print \$NF}');" \
    "DOCKER_REGISTRY=${CONTAINER_REGISTRY};" \
    "IMAGE_NAME=${IMAGE_BASE_NAME}/dss-\${DSS_NODE_TYPE}-node:\${DSS_IMAGE_TAG};" \
    "" \
    "printf \"Commiting DSS container to image: ${IMAGE_NAME}\n\"" \
    "" \
    "docker login \${DOCKER_REGISTRY} -u \${GL_REG_USER} -p \${GL_REG_TOKEN}" \
    "docker commit \${DSS_CONTAINER} \${IMAGE_NAME};" \
    "docker push \${IMAGE_NAME};" > ${COMMIT_SCRIPT}

chmod +x ${COMMIT_SCRIPT}
cp ${COMMIT_SCRIPT} ${HOME}/commit-dss.sh