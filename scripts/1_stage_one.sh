#!/usr/bin/env bash

function stage_one {
    MSG1 "=================== Stage 1: Prepare for Linux Server =========================";

    source /etc/os-release
    case ${ID} in
        centos|rhel)
            stage_one_script_path="centos/1_prepare_for_server.sh"
            stage_two_script_path="centos/2_prepare_for_k8s.sh"
            stage_three_script_path="centos/3_install_docker.sh" ;;
        ubuntu)
            stage_one_script_path="ubuntu/1_prepare_for_server.sh"
            stage_two_script_path="ubuntu/2_prepare_for_k8s.sh"
            stage_three_script_path="ubuntu/3_install_docker.sh" ;;
        debian)
            stage_one_script_path="debian/1_prepare_for_server.sh"
            stage_two_script_path="debian/2_prepare_for_k8s.sh"
            stage_three_script_path="debian/3_install_docker.sh" ;;
        *)
            ERR "Not Support Linux !" && exit $EXIT_FAILURE ;;
    esac


    mkdir -p "${K8S_DEPLOY_LOG_PATH}/logs-stage-one"
    for NODE in "${ALL_NODE[@]}"; do
        MSG2 "*** ${NODE} *** is Preparing for Linux Server"
        ssh "${NODE}" "bash -s" < "${stage_one_script_path}" | tee ${K8S_DEPLOY_LOG_PATH}/logs-stage-one/${NODE}.log &> /dev/null &
    done
    MSG2 "Please Waiting... (multitail -f ${K8S_DEPLOY_LOG_PATH}/logs-stage-one/*.log)"
    wait
}
