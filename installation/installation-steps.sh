#!/bin/bash

# Uncomment for debug
#set -x

# This script is designed to run in a container on a Kubernetes pod to either
# - install a new DSS node specified by DSS_NODE_TYPE and VERSION
# - or to migrate an existing DSS installation of type DSS_NODE_TYPE and VERSION to a new host.
# Eventually, a new DSS host image is created by committing the running container.
# Prerequisites: - Volume mounted to the container w/ or w/o an existing DSS installation.
#                - Command line tools docker, kubectl installed, configured and available for the DSS user.

# DSS_NODE_TYPE has to come from the environment
if [ -z "${DSS_NODE_TYPE}" ];
then
    printf "%s\n" "" "DSS node type is not defined, set the environment variable DSS_NODE_TYPE to one of design | automation | apideployer" ""
    exit
fi

if [ "${DSS_NODE_TYPE}" != "design" ] && [  "${DSS_NODE_TYPE}" != "automation" ] && [  "${DSS_NODE_TYPE}" != "apideployer" ];
then
    printf "%s\n" "" "DSS_NODE_TYPE is invalid '${DSS_NODE_TYPE}'; none of design | automation | apideployer"
    exit
fi

# Set some variables to work with
VERSION=8.0.3
DSS_VERSION=dss-${VERSION}
DSS_ROOT=/media/dss-${DSS_NODE_TYPE}-node
DSS_DATA_DIR=${DSS_ROOT}/dss_data
DSS_INSTALL_DIR=${DSS_ROOT}/dataiku-${DSS_VERSION}
DSS_PORT=11000
DSS_USER=ubuntu

SCRIPT_HOME_DIR=$( cd ${0%/*} && pwd -P )

# Make loop device available, a workaround to support ACL w/ Docker Desktop on Mac
# Check whether DSS image is there to mount
DSS_IMAGE=${DSS_ROOT}/dss-${DSS_NODE_TYPE}-node.img

if [ ! -f "${DSS_IMAGE}" ];
then
    printf "%s\n" "Couldn't find DSS image to mount ${DSS_IMAGE}, exiting..."
    exit
fi

LOOP_DEVICE=$(sudo losetup -fP --show ${DSS_IMAGE})
sudo mount -v ${LOOP_DEVICE} ${DSS_ROOT}
# Note: DSS_ROOT is only a volume "place holder" to mount to and its content is not visible to the real volume (on the host)
sudo chown ${DSS_USER}:${DSS_USER} ${DSS_ROOT}


# Preliminary checks/decisions about installation/migration, versions
printf "%s\n" "" "Looking for an existing DSS ${DSS_NODE_TYPE} node ${VERSION} in the directory '${DSS_DATA_DIR}'"
sleep 3s


install_dss_dependencies () {
    printf "%s\n" "" \
        "-------------------------" \
        "Installing DSS dependencies" \
        "-------------------------"
    sleep 3s

    sudo -i ${DSS_INSTALL_DIR}/scripts/install/install-deps.sh -yes;
}


if [ -d "${DSS_DATA_DIR}" ];
then
    THE_JOB=MIGRATION

    # Installation found so get the installed node type and check configuration
    # Probably the same as in the path
    INSTALLED_NODE_TYPE=$(grep nodetype ${DSS_DATA_DIR}/install.ini | awk '{print $NF}')

    # Get the version
    INSTALLED_VERSION=$(grep product_version ${DSS_DATA_DIR}/dss-version.json | awk -F\" '{print $4}')
    
    printf "%s\n" "" "Found DSS ${INSTALLED_NODE_TYPE} node ${INSTALLED_VERSION}"

    # There is no need to check whether node types match
    # they always do since the node type is part of the path DSS_DATA_DIR
    # but check whether the versions match
    if [ "${INSTALLED_VERSION}" != "${VERSION}" ];
    then
        printf "%s\n" "" "Version mismatch, ${VERSION} differs from what is already installed ${INSTALLED_VERSION}" \
            "Exiting" ""
        exit
    fi

    printf "%s\n" "" "Migrating existing installation to the current host"

    install_dss_dependencies
else
    printf "%s\n" "" \
        "-------------------------" \
        "No DSS ${DSS_NODE_TYPE} node found." \
        "Installing DSS ${DSS_NODE_TYPE} node ${VERSION} into the directory '${DSS_DATA_DIR}'" ""
    sleep 3s

    THE_JOB=INSTALLATION

    # set the right owner and user id permission for the DSS root directory
    sudo chown ${DSS_USER}:${DSS_USER} ${DSS_ROOT}
    sudo chmod 2771 ${DSS_ROOT}
    sudo ls -l /media

    printf "%s\n" "" "Getting the DSS tarball and installing incl. dependencies"

    wget -q https://cdn.downloads.dataiku.com/public/dss/${VERSION}/dataiku-${DSS_VERSION}.tar.gz -P ${DSS_ROOT}
    tar xzf ${DSS_ROOT}/dataiku-${DSS_VERSION}.tar.gz -C ${DSS_ROOT}
    rm ${DSS_ROOT}/dataiku-${DSS_VERSION}.tar.gz

    install_dss_dependencies

    DEPENDENCIES_DIR=${SCRIPT_HOME_DIR}/../dependencies

    if [ ! -z "${DSS_LICENSE_FILE}" ];
    then
        LICENSE_OPTION="-l ${DEPENDENCIES_DIR}/${DSS_LICENSE_FILE}"
    fi

    ${DSS_INSTALL_DIR}/installer.sh -d ${DSS_DATA_DIR} -p ${DSS_PORT} -P python3.6 -t ${DSS_NODE_TYPE} ${LICENSE_OPTION} -y

    if [ "${DSS_NODE_TYPE}" != "apideployer" ];
    then
        printf "%s\n" "" \
            "-------------------------" \
            "Installing Spark integration" \
            "-------------------------"
        sleep 3s

        printf "%s\n" "" "Getting the Spark tarballs"
        HADOOP_LIB_TARBALL=dataiku-dss-hadoop-standalone-libs-generic-hadoop3-${VERSION}.tar.gz
        SPARK_TARBALL=dataiku-dss-spark-standalone-${VERSION}-2.4.5-generic-hadoop3.tar.gz

        wget -q https://downloads.dataiku.com/public/dss/${VERSION}/${HADOOP_LIB_TARBALL} -P ${DSS_ROOT};
        wget -q https://downloads.dataiku.com/public/dss/${VERSION}/${SPARK_TARBALL} -P ${DSS_ROOT};

        cd ${DSS_DATA_DIR}
        ./bin/dssadmin install-hadoop-integration -standaloneArchive ${DSS_ROOT}/${HADOOP_LIB_TARBALL};
        ./bin/dssadmin install-spark-integration -standaloneArchive ${DSS_ROOT}/${SPARK_TARBALL} -forK8S;

        rm ${DSS_ROOT}/${HADOOP_LIB_TARBALL}
        rm ${DSS_ROOT}/${SPARK_TARBALL}
    fi

    # Copy default users
    cp ${DEPENDENCIES_DIR}/users.json ${DSS_DATA_DIR}/config/
fi

# Append environment variables to DSS env-site.sh for containerized execution and Spark
DSS_ENV_SITE=${DSS_DATA_DIR}/bin/env-site.sh
if ! grep -q "DKU_BACKEND_EXT_HOST" ${DSS_ENV_SITE};
then
    printf "%s\n" "" "export DKU_BACKEND_EXT_HOST=\$(hostname -I | cut -d' ' -f1)" >> ${DSS_ENV_SITE}
fi


# kind of block comment
#: '
printf "%s\n" "" \
    "-------------------------" \
    "Activating DSS UIF (User Impersonation Framework)" \
    "-------------------------"
sleep 3s


# Clean up exitisting security directory
DSS_SECURITY_CONFIG_DIR=/etc/dataiku-security
if [ -d "${DSS_SECURITY_CONFIG_DIR}" ];
then
    sudo rm -fr ${DSS_SECURITY_CONFIG_DIR}
fi

sudo -i ${DSS_DATA_DIR}/bin/dssadmin install-impersonation ${DSS_USER};
sudo chmod 711 ${DSS_ROOT};
sudo chmod 711 ${DSS_DATA_DIR};
sudo chmod 711 ${DSS_INSTALL_DIR};

# Create a group for dss users and add all DSS users to that group
# This is to support UIF
DSS_USERS_GROUP=dss-users;
sudo groupadd -g 1001 ${DSS_USERS_GROUP};
sudo usermod -a -G ${DSS_USERS_GROUP} ubuntu; 

# Add the group to the allowed_user_groups in the DSS UIF configuration
DSS_INSTALL_ID=$(sudo ls ${DSS_SECURITY_CONFIG_DIR});
DSS_SECURITY_CONFIG_FILE=${DSS_SECURITY_CONFIG_DIR}/${DSS_INSTALL_ID}/security-config.ini
if ! sudo grep -q ${DSS_USERS_GROUP} ${DSS_SECURITY_CONFIG_FILE};
then
    sudo sed -i "/allowed_user_groups =/s/$/ ${DSS_USERS_GROUP}/" ${DSS_SECURITY_CONFIG_FILE}
fi
#'


printf "%s\n" "" \
    "-------------------------" \
    "Building DSS Docker base images" \
    "-------------------------"
sleep 3s

# Login to container registry first
CONTAINER_REGISTRY=registry.gitlab.com
docker login ${CONTAINER_REGISTRY} -u $(cat /gitlab-repo/credentials/GL_REG_USER) -p $(cat /gitlab-repo/credentials/GL_REG_TOKEN);
IMAGE_BASE_NAME=${CONTAINER_REGISTRY}/tibor_fabian/dku-dss-k8s

printf "DSS node type: ${DSS_NODE_TYPE}\n"

if [ "${DSS_NODE_TYPE}" != "apideployer" ];
then
    # Find the DSS installation ID
    DSS_INSTALL_ID=$(grep installid ${DSS_DATA_DIR}/install.ini | awk '{print $NF}');
    DSS_INSTALL_ID=${DSS_INSTALL_ID,,}; # to lower case

    # Check whether there is a base image already
    DKU_EXEC_BASE=dku-exec-base-${DSS_INSTALL_ID};
    DKU_EXEC_BASE_IMAGE=${DKU_EXEC_BASE}:${DSS_VERSION};

    printf "Looking for image ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE}\n"
    
    # First pull the image, then check
    docker image pull ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE} 2> /dev/null

    if [ "$(docker image inspect ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE} 2> /dev/null)" == "[]" ];
    then
        printf "%s\n" "" \
            "-------------------------" \
            "Building the DSS Docker base image for containerized execution" \
            "-------------------------"
        sleep 3s

        cd ${DSS_DATA_DIR}
        ./bin/dssadmin build-base-image --type container-exec --without-r;

        printf "%s\n" "" \
            "-------------------------" \
            "Pushing the base image for containerized execution to image registry" \
            "-------------------------"
        sleep 3s

        # Now push the base image to the container image registry
        docker tag ${DKU_EXEC_BASE_IMAGE} ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE};
        docker push ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE_IMAGE};
    else
        printf "%s\n" "" \
            "-------------------------" \
            "The Docker base image for containerized execution already exists ${IMAGE_BASE_NAME}/${DKU_EXEC_BASE}" \
            "-------------------------"
        sleep 3s
    fi

    # Check whether there is a SPARK image already
    DKU_SPARK_BASE=dku-spark-base-${DSS_INSTALL_ID};
    DKU_SPARK_BASE_IMAGE=${DKU_SPARK_BASE}:${DSS_VERSION}

    printf "Looking for image ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE}\n"

    # First pull the image, then check
    docker image pull ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE} 2> /dev/null

    if [ "$(docker image inspect ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE} 2> /dev/null)" == "[]" ];
    then
        printf "%s\n" "" \
            "-------------------------" \
            "Building the Docker base image for Spark on K8S" \
            "-------------------------"
        sleep 3s

        ./bin/dssadmin build-base-image --type spark --without-r;

        printf "%s\n" "" \
            "-------------------------" \
            "Pushing the base image for Spark on K8S to image registry" \
            "-------------------------"
        sleep 3s

        docker tag ${DKU_SPARK_BASE_IMAGE} ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE};
        docker push ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE_IMAGE};
    else
        printf "%s\n" "" \
            "-------------------------" \
            "The Docker base image for Spark on K8S already exists ${IMAGE_BASE_NAME}/${DKU_SPARK_BASE}" \
            "-------------------------"
        sleep 3s
    fi

else
    # Check whether there is an API image already
    DKU_API_BASE=dku-apideployer-apinode-base;
    DKU_API_BASE_IMAGE=${DKU_API_BASE}:${DSS_VERSION}

    printf "Looking for image ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE}\n"

    # First pull the image, then check
    docker image pull ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE} 2> /dev/null

    if [ "$(docker image inspect ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE} 2> /dev/null)" == "[]" ];
    then
        printf "%s\n" "" \
            "-------------------------" \
            "Building the Docker base image for API Deployer on K8S" \
            "-------------------------"
        sleep 3s

        cd ${DSS_DATA_DIR}
        ./bin/dssadmin build-base-image --type api-deployer --without-r;

        printf "%s\n" "" \
            "-------------------------" \
            "Pushing the API Deployer base image to image registry" \
            "-------------------------"
        sleep 3s

        docker tag ${DKU_API_BASE_IMAGE} ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE};
        docker push ${IMAGE_BASE_NAME}/${DKU_API_BASE_IMAGE};
    else
        printf "%s\n" "" \
            "-------------------------" \
            "The Docker base image for the API Deployer already exists ${IMAGE_BASE_NAME}/${DKU_API_BASE}" \
            "-------------------------"
        sleep 3s
    fi
fi


printf "%s\n" "" \
    "-------------------------" \
    "Creating startup script" \
    "-------------------------"
sleep 2s

# Used by both start and stop scripts
DSS_START_ENV_FILE=dss-start-env.sh

source ${SCRIPT_HOME_DIR}/create-dss-startup-script.sh

printf "%s\n" "" \
    "-------------------------" \
    "Creating pre-stop script" \
    "-------------------------"
sleep 2s

PRE_STOP_SCRIPT=${HOME}/pre-stop.sh

printf "%s\n" "#!/bin/bash" \
    "" \
    "printf \"Stopping DSS ${DSS_NODE_TYPE} node\n\"" \
    "${DSS_DATA_DIR}/bin/dss stop" \
    "" \
    "# Free image mount, read LOOP_DEVICE first" \
    ". ${DSS_START_ENV_FILE}" \
    "sudo umount -v ${DSS_ROOT}" \
    "sudo losetup -d \${LOOP_DEVICE}" > ${PRE_STOP_SCRIPT}

chmod +x ${PRE_STOP_SCRIPT}


printf "%s\n" "" \
    "-------------------------" \
    "Committing the installation state of the running DSS container; using DooD sidecar for that" \
    "-------------------------"
sleep 3s

source ${SCRIPT_HOME_DIR}/create-dood-commit-script.sh

kubectl exec -it ${POD_NAME} --container dood -- ${COMMIT_SCRIPT} ${DSS_IMAGE_TAG}

printf "%s\n" "" "" \
    "-------------------------" \
    "${THE_JOB} DONE" \
    "-------------------------"


printf "%s\n" "" "Updating the Git repo with the new image tag"

# Patch dss-deployment.yaml with the new image DSS_IMAGE_TAG
sed -i -r "s/(newTag: )(.*)/\1${DSS_IMAGE_TAG}/" ${SCRIPT_HOME_DIR}/../deployment/${DSS_NODE_TYPE}/kustomization.yaml

# Commit DSS image update
cd ${SCRIPT_HOME_DIR}/..
git config user.email "installer@dku.dss"                                                                                                                                  
git config user.name "DSS installer"

git add .
git commit . -m "updated DSS ${DSS_NODE_TYPE} node image"
git push

# Also tag the Git repo
git tag -a ${DSS_IMAGE_TAG} -m "DSS ${DSS_NODE_TYPE} node installation done"
git push --tags

# Free image mount
sudo umount -v ${DSS_ROOT}
sudo losetup -d ${LOOP_DEVICE}

# If needed, terminate the current installation and start the new DSS deployment
if [ "${AUTO_DEPLOYMENT}" == "true" ];
then
    printf "%s\n" "" \
        "-------------------------" \
        "Deploying DSS ${DSS_NODE_TYPE} node" \
        "-------------------------"
    sleep 2s

    kubectl apply -k ${SCRIPT_HOME_DIR}/../deployment/${DSS_NODE_TYPE}/

    printf "%s\n" "" "Exiting pod $POD_NAME" ""
    kubectl delete pod $POD_NAME
else
    sleep infinity
fi
