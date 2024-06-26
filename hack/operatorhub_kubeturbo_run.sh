#!/usr/bin/env bash

################## CMD ALIAS ##################
KUBECTL=$(command -v oc)
KUBECTL=${KUBECTL:-$(command -v kubectl)}
if ! [ -x "${KUBECTL}" ]; then
    echo "ERROR: Command 'oc' and 'kubectl' are not found, please install either of them first!" >&2 && exit 1
fi

################## CONSTANT ##################
CARALOG_SOURCE="certified-operators"
CARALOG_SOURCE_NS="openshift-marketplace"

DEFAULT_RELEASE="stable"
DEFAULT_NS="turbo"
DEFAULT_KUBETURBO_NAME="kubeturbo-release"
DEFAULT_TARGET_NAME="JS_Fyre_OCP_Cluster"

RETRY_INTERVAL=10 # in seconds
MAX_RETRY=10

################## ARGS ##################
TARGET_HOST=""
OAUTH_CLIENT_ID=""
OAUTH_CLIENT_SECRET=""

ACTION=${ACTION:-"create"}
XL_USERNAME=${XL_USERNAME:-"kubeturbo1"}
XL_PASSWORD=${XL_PASSWORD:-"kubeturbo1"}
OPERATOR_NS=${OPERATOR_NS:-${DEFAULT_NS}}
TARGET_NAME=${TARGET_NAME:-${DEFAULT_TARGET_NAME}}
TARGET_RELEASE=${TARGET_RELEASE:-${DEFAULT_RELEASE}}
KUBETURBO_NAME=${KUBETURBO_NAME:-${DEFAULT_KUBETURBO_NAME}}

################## DYNAMIC VARS ##################
CERT_KUBETURBO_OP_NAME="<EMPTY>"
CERT_KUBETURBO_OP_RELEASE="<EMPTY>"
CERT_KUBETURBO_OP_VERSION="<EMPTY>"

################## FUNCTIONS ##################
function validate_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --host) shift; TARGET_HOST="$1"; [ -n "${TARGET_HOST}" ] && shift;;
            --clientId) shift; OAUTH_CLIENT_ID="$1"; [ -n "${OAUTH_CLIENT_ID}" ] && shift;;
            --clientSecret) shift; OAUTH_CLIENT_SECRET="$1"; [ -n "${OAUTH_CLIENT_SECRET}" ] && shift;;
            -*|--*) echo "ERROR: Unknown option $1" >&2; usage; exit 1;;
            *) shift;;
        esac
    done

    if [ -z "${TARGET_HOST}" ] || [ -z "${OAUTH_CLIENT_ID}" ] || [ -z "${OAUTH_CLIENT_SECRET}" ]; then
        echo "ERROR: Missing require fields or values" >&2; usage; exit 1
    fi
}

function usage() {
   echo "This program helps to install Kubeturbo to the cluster via the OperatorHub"
   echo "Syntax: ./$0 --host <IP> --clientId <OAUTH CLIENT ID> --clientSecret <OAUTH CLIENT SECRET>"
   echo
   echo "options:"
   echo "--host         <VAL>    host ip      of the Turbonomic instance (required)"
   echo "--clientId     <VAL>    oauth id     of the Turbonomic instance (required)"
   echo "--clientSecret <VAL>    oauth secret of the Turbonomic instance (required)"
   echo
}

function main() {
    echo "Creating ${OPERATOR_NS} namespace to deploy Certified Kubeturbo operator"
    ${KUBECTL} create ns ${OPERATOR_NS}

    select_cert_kubeturbo_op_from_operatorhub
    select_cert_kubeturbo_op_channel_from_operatorhub

    if [ ${ACTION} == "delete" ]; then
        apply_kubeturbo
        apply_kubeturbo_op_subscription
    else
        apply_kubeturbo_op_subscription
        apply_kubeturbo
    fi

    echo "Successfully ${ACTION} Kubeturbo in ${OPERATOR_NS} namespace!"
    ${KUBECTL} -n ${OPERATOR_NS} get OperatorGroup,Subscription,kt,pod,deploy
}

function select_cert_kubeturbo_op_from_operatorhub() {
    echo "Fetching Openshift certified Kubeturbo operator from OperatorHub ..."
    local cert_kubeturbo_ops=$(${KUBECTL} get packagemanifests -o jsonpath="{range .items[*]}{.metadata.name} {.status.catalogSource} {.status.catalogSourceNamespace}{'\n'}{end}" | grep -e "kubeturbo" | grep -e "${CARALOG_SOURCE}.*${CARALOG_SOURCE_NS}" | awk '{print $1}')
    local cert_kubeturbo_ops_count=$(echo "${cert_kubeturbo_ops}" | wc -l | awk '{print $1}')
    if [ -z ${cert_kubeturbo_ops} ] || [ ${cert_kubeturbo_ops_count} -lt 1 ]; then
        echo "There aren't any certified Kubeturbo operator in the Operatorhub, please contact administrator for more information!" && exit 1
    elif [ ${cert_kubeturbo_ops_count} -gt 1 ]; then
        PS3="Fetched mutiple certified Kubeturbo operators in the Operatorhub, please select a number to proceed OR type 'exit' to exit: "
        select opt in ${cert_kubeturbo_ops[@]}; do
            validate_select_input ${cert_kubeturbo_ops_count} ${REPLY}
            if [ $? -eq 0 ]; then
                cert_kubeturbo_ops=${opt}
                break;
            fi
        done
    fi
    CERT_KUBETURBO_OP_NAME=${cert_kubeturbo_ops}
    echo "Using Openshift certified Kubeturbo operator: ${CERT_KUBETURBO_OP_NAME}"
}

function select_cert_kubeturbo_op_channel_from_operatorhub() {
    echo "Fetching Openshift certified Kubeturbo operator channels from OperatorHub ..."
    local cert_kubeturbo_op_name=${1-${CERT_KUBETURBO_OP_NAME}}
    local channels=$(${KUBECTL} get packagemanifests ${cert_kubeturbo_op_name} -o jsonpath="{range .status.channels[*]}{.name}:{.currentCSV}{'\n'}{end}" | grep "${TARGET_RELEASE}")
    local channel_count=$(echo "${channels}" | wc -l | awk '{print $1}')
    if [ -z "${channels}" ] || [ ${channel_count} -lt 1 ]; then
        echo "There aren't any channel created for ${cert_kubeturbo_op_name}, please contact administrator for more information!" && exit 1
    elif [ ${channel_count} -gt 1 ]; then
        PS3="Fetched mutiple releases, please select a number to proceed OR type 'exit' to exit: "
        select opt in ${channels[@]}; do
            validate_select_input ${channel_count} ${REPLY}
            if [ $? -eq 0 ]; then
                channels=${opt}
                break;
            fi
        done
    fi
    CERT_KUBETURBO_OP_RELEASE=$(echo ${channels} | awk -F':' '{print $1}')
    CERT_KUBETURBO_OP_VERSION=$(echo ${channels} | awk -F':' '{print $2}')
    echo "Using Openshift certified Kubeturbo ${CERT_KUBETURBO_OP_RELEASE} channel, version ${CERT_KUBETURBO_OP_VERSION}"
}

function apply_kubeturbo_op_subscription() {
    echo "${ACTION} Certified Kubeturbo operator subscription ..."
    if [ ${ACTION} == "delete" ]; then
        ${KUBECTL} -n ${OPERATOR_NS} delete Subscription ${CERT_KUBETURBO_OP_NAME}
        ${KUBECTL} -n ${OPERATOR_NS} delete csv ${CERT_KUBETURBO_OP_VERSION}
        ${KUBECTL} -n ${OPERATOR_NS} delete OperatorGroup ${CERT_KUBETURBO_OP_NAME}
        return
    fi
    cat <<-EOF | ${KUBECTL} ${ACTION} -f -
	---
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${CERT_KUBETURBO_OP_NAME}
	  namespace: ${OPERATOR_NS}
	spec:
	  targetNamespaces:
	  - ${OPERATOR_NS}
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${CERT_KUBETURBO_OP_NAME}
	  namespace: ${OPERATOR_NS}
	spec:
	  channel: ${CERT_KUBETURBO_OP_RELEASE}
	  installPlanApproval: Automatic
	  name: ${CERT_KUBETURBO_OP_NAME}
	  source: ${CARALOG_SOURCE}
	  sourceNamespace: ${CARALOG_SOURCE_NS}
	  startingCSV: ${CERT_KUBETURBO_OP_VERSION}
	---
	EOF
    wait_for_deployment ${OPERATOR_NS} "kubeturbo-operator"
}

function apply_kubeturbo() {
    echo "${ACTION} Kubeturbo CR ..."
    cat <<-EOF | ${KUBECTL} ${ACTION} -f -
	---
	kind: Kubeturbo
	apiVersion: charts.helm.k8s.io/v1
	metadata:
	  name: ${KUBETURBO_NAME}
	  namespace: ${OPERATOR_NS}
	spec:
	  serverMeta:
	    turboServer: ${TARGET_HOST}
	  targetConfig:
	    targetName: ${TARGET_NAME}
	---
	apiVersion: v1
	kind: Secret
	metadata:
	  name: turbonomic-credentials
	  namespace: ${OPERATOR_NS}
	type: Opaque
	data:
	  username: $(base64 <<< ${XL_USERNAME})
	  password: $(base64 <<< ${XL_PASSWORD})
	  clientid: $(base64 <<< ${OAUTH_CLIENT_ID})
	  clientsecret: $(base64 <<< ${OAUTH_CLIENT_SECRET})
	---
	EOF
    wait_for_deployment ${OPERATOR_NS} ${KUBETURBO_NAME}
}

function validate_select_input() {
    local opts_count=$1 && local opt=$2
    if [ "${opt}" == "exit" ]; then
        echo "Exiting the program ..." >&2 && exit 0
    elif ! [[ "${opt}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Input not a number: ${opt}" >&2 && return 1
    elif [ ${opt} -le 0 ] || [ ${opt} -gt ${opts_count} ]; then
        echo "ERROR: Input out of range [1 - ${opts_count}]: ${opt}" >&2 && return 1
    fi
}

function wait_for_deployment() {
    if [ ${ACTION} == "delete" ]; then return; fi
    local namespace=$1 && local deploy_name=$2
    
    echo "Waiting for deployment '${deploy_name}' to start..."
    local retry_count=0
    while true; do
        local full_deploy_name=$(${KUBECTL} -n ${namespace} get deploy -o name | grep ${deploy_name})
        if [ -n "${full_deploy_name}" ]; then
            local deploy_status=$(${KUBECTL} -n ${namespace} rollout status ${full_deploy_name} | grep "successfully")
            echo "${deploy_status}"
            if [ -n "${deploy_status}" ]; then
                local deploy_name=$(awk -F '/' '{print $2}' <<< ${full_deploy_name})
                for pod in $(${KUBECTL} -n ${namespace} get pods -o name | grep ${deploy_name}); do
                    ${KUBECTL} -n ${namespace} wait --for=condition=Ready ${pod}
                done
                break
            fi
        fi
        ((++ retry_count)) && retry ${retry_count}
    done
}

function retry() {
    local attempts=${1:--999}
    if [ ${attempts} -ge ${MAX_RETRY} ]; then
        echo "ERROR: Resource is not ready in ${MAX_RETRY} attempts." >&2 && exit 1
    else
        attempt_str=$([ ${attempts} -ge 0 ] && echo " (${attempts}/${MAX_RETRY})") 
        echo "Resource is not ready, re-attempt after ${RETRY_INTERVAL}s ...${attempt_str}"
        sleep ${RETRY_INTERVAL}
    fi
}

################## MAIN ##################
validate_args $@ && main
