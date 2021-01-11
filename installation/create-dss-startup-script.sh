# This is a subscript for installation-steps.sh
# It creates a startup script for the DSS container to
# - mount the persistent volume
# - start DSS
# - download necessary Docker images from ECR
# - keep the container alive

STARTUP_SCRIPT=${HOME}/startup.sh

printf "%s\n" "#!/bin/bash" \
    "" \
    "cp commit-dss.sh /share/" \
    "" \
    "printf \"Making loop device available, a workaround to support ACL w/ Docker Desktop on Mac\n\"" \
    "printf \"Checking whether the DSS image is there to mount\n\"" \
    "" \
    "if [ ! -f \"${DSS_IMAGE}\" ];" \
    "then" \
    "    printf \"Could not find DSS image to mount ${DSS_IMAGE}, exiting...\n\"" \
    "    exit" \
    "fi" \
    "" \
    "LOOP_DEVICE=\$(sudo losetup -fP --show ${DSS_IMAGE})" \
    "sudo mount -v \${LOOP_DEVICE} ${DSS_ROOT}" \
    "# Note: DSS_ROOT is only a volume \"place holder\" to mount to and its content is not visible to the real volume (on the host)" \
    "" \
    "sudo chown ${DSS_USER}:${DSS_USER} ${DSS_ROOT}" \
    "" \
    "# Store loop device ID for pre-stop.sh" \
    "echo \"export LOOP_DEVICE=${LOOP_DEVICE}\" > ${DSS_START_ENV_FILE}" \
    "" \
    "printf \"Starting DSS\n\"" \
    "${DSS_DATA_DIR}/bin/dss start" \
    "" \
    "printf \"Pulling DSS base images from GitLab container registry\n\"" \
    "docker login ${CONTAINER_REGISTRY} -u \$(cat /gitlab-repo/credentials/GL_REG_USER) -p \$(cat /gitlab-repo/credentials/GL_REG_TOKEN)" \
    "" > ${STARTUP_SCRIPT}

if [ "${DSS_NODE_TYPE}" != "apideployer" ];
then
    printf "%s\n" \
        "docker pull ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE}" \
        "docker tag ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE} ${DKU_EXEC_BASE_IMAGE}" \
        "" \
        "docker pull ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE}" \
        "docker tag ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE} ${DKU_SPARK_BASE_IMAGE}" >> ${STARTUP_SCRIPT}
else
    printf "%s\n" \
        "docker pull ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE}" \
        "docker tag ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE} ${DKU_API_BASE_IMAGE}" >> ${STARTUP_SCRIPT}
fi

printf "%s\n" "" \
    "sleep infinity" >> ${STARTUP_SCRIPT}

chmod +x ${STARTUP_SCRIPT}
