#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function check_mirror_registry () {
    if test -s "${SHARED_DIR}/mirror_registry_url" ; then
        export MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        echo "This is not a disconnected environment as no mirror registry url found. Skipping rest of steps..."
        exit 0
    fi
}

function prepare_oc_mirror () {
    echo "Downloading the latest oc-mirror client..."
    run_command "curl -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
    run_command "./oc-mirror version --output=yaml"

    echo "Prepareing pull secrets for oc-mirror..."
    oc extract secret/pull-secret -n openshift-config --confirm --to ${TMP_DIR}
    run_command "cat ${TMP_DIR}/.dockerconfigjson" # debug
    registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
    jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${TMP_DIR}/.dockerconfigjson" > ${XDG_RUNTIME_DIR}/containers/auth.json
    run_command "cat ${XDG_RUNTIME_DIR}/containers/auth.json" # debug

    # echo "Retrieving the 'registry.stage.redhat.io' auth config from shared credentials..."
    # local stage_registry_path="/var/run/vault/mirror-registry/registry_stage.json"
    # local stage_auth_user stage_auth_password stage_auth_config
    # stage_auth_user=$(jq -r '.user' $stage_registry_path)
    # stage_auth_password=$(jq -r '.password' $stage_registry_path)
    # stage_auth_config=$(echo -n " " "$stage_auth_user":"$stage_auth_password" | base64 -w 0)
    # echo "Updating the image pull secret with the auth config..."
    # oc extract secret/pull-secret -n openshift-config --confirm --to /tmp
    # local new_dockerconfig="/tmp/.new-dockerconfigjson"
    # jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_auth_config\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" >"$new_dockerconfig"
    # oc set data secret pull-secret -n openshift-config --from-file=.dockerconfigjson=$new_dockerconfig
}

function mirror_catalog_and_operator() {
    echo "Listing available packages in the given index image '${INDEX_IMG}'..."
    ./oc-mirror list operators --catalog=${INDEX_IMG} --package=openshift-cert-manager-operator

    echo "Creaing ImageSetConfiguration..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${INDEX_IMG}
    packages:
    - name: openshift-cert-manager-operator
  additionalImages:
  - name: quay.io/openshifttest/hello-openshift@sha256:4200f438cf2e9446f6bcff9d67ceea1f69ed07a2f83363b7fb52529f7ddd8a83
  - name: alpine/helm:latest
  - name: hashicorp/vault:latest
EOF

    echo "Publishing the images to the mirror registry..."
    run_command "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --workspace=${TMP_DIR} docker://${MIRROR_REGISTRY_HOST}"

    echo "Checking and applying the generated configuration files..."
    local working_dir=${TMP_DIR}/working-dir/cluster-resources/
    run_command "find ${working_dir} -type f -exec cat {} \;"
    run_command "oc apply -f ${working_dir}"

    echo "Waiting the applied catalog source to become READY..."
    run_command "oc get catalogsource -A"
    # CATSRC="cs-redhat-operator-index"
    # if wait_for_state "catalogsource/${CATSRC}" "jsonpath={.status.connectionState.lastObservedState}=READY" "5m" "openshift-marketplace"; then
    #     echo "CatalogSource is ready"
    # else
    #     echo "Timed out after 5m. Dumping resources for debugging..."
    #     run_command "oc get pod -n openshift-marketplace"
    #     run_command "oc get pod -n openshift-marketplace -l=olm.catalogSource=$CATSRC -o=yaml"
    #     run_command "oc get event -n openshift-marketplace | grep ${CATSRC}"
    #     exit 1
    # fi

    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: adhoc-icsp
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/hashicorp/vault
    source: registry.connect.redhat.com/hashicorp/vault
EOF
    run_command "ls /var/run/vault/mirror-registry/" # debug
}

timestamp
set_proxy
check_mirror_registry

export TMP_DIR=/tmp/disconnected
export XDG_RUNTIME_DIR="${TMP_DIR}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$TMP_DIR"

prepare_oc_mirror
mirror_catalog_and_operator
