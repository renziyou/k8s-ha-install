#!/usr/bin/env bash


function 0_add_k8s_node_script_prepare {
    # 检测是否为 root 用户，否则退出脚本
    # 检测是否为支持的 Linux 版本，否则退出脚本
    [[ $(uname) != "Linux" ]] && ERR "not support !" && exit $EXIT_FAILURE
    [[ $(id -u) -ne 0 ]] && ERR "not root !" && exit $EXIT_FAILURE
    source /etc/os-release
    K8S_NODE_OS=${ID}
    if [[ "$ID" == "centos" || "$ID" == "rhel" ]]; then
        INSTALL_MANAGER="yum"
    elif [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
        INSTALL_MANAGER="apt-get"
    else
        ERR "not support !"
        EXIT $EXIT_FAILURE; fi

    # 检查网络是否可用，否则退出脚本
    # 检查新增节点是否可达，否则退出脚本
    if ! timeout 2 ping -c 2 -i 1 114.114.114.114 &> /dev/null; then ERR "no network" && exit $EXIT_FAILURE; fi
    for NODE in "${ADD_WORKER_IP[@]}"; do
        if ! timeout 2 ping -c 1 -i 1 ${NODE}; then
            ERR "worker node ${NODE} can't access"
            exit $EXIT_FAILURE; fi; done
}


# 当前运行的 master 节点对新的 worker 节点的 ssh 免密登录
function 1_configure_ssh_public_key_authentication {
    MSG1 "1. configure ssh public key authentication"

    # 生成新的 hosts 文件
    for HOST in "${!ADD_WORKER[@]}"; do
        local IP=${ADD_WORKER[$HOST]}
        sed -r -i "/(.*)${IP}(.*)${HOST}(.*)/d" /etc/hosts
        echo "${IP} ${HOST}" >> /etc/hosts; done

    # ssh 免密钥登录
    for NODE in "${!ADD_WORKER[@]}"; do
        ssh-keyscan "${NODE}" >> /root/.ssh/known_hosts 2> /dev/null; done
    for NODE in "${!ADD_WORKER[@]}"; do
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_rsa.pub root@"${NODE}"
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ecdsa.pub root@"${NODE}"
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ed25519.pub root@"${NODE}"; done
}


# 设置新节点的主机名
function 2_copy_hosts_file_to_all_k8s_node {
    MSG1 "2. copy hosts file to all k8s node"

    # 设置新添加的 worker 节点主机名
    for NODE in "${!ADD_WORKER[@]}"; do
        ssh ${NODE} "hostnamectl set-hostname ${NODE}"; done

    # 将新的 hosts 文件复制到所有 k8s 节点上
    for NODE in "${ALL_NODE[@]}"; do
        scp /etc/hosts ${NODE}:/etc/hosts; done

    # 将新的 hosts 文件复制到所有新添加的 worker 节点上
    for NODE in "${ADD_WORKER[@]}"; do
        scp /etc/hosts ${NODE}:/etc/hosts; done
}


# 初始化新添加的节点
function 3_run_stage_one_two_three {
    MSG1 "3. run stage [one,two,three]"

    local stage_one_script_path
    local stage_two_script_path
    local stage_three_script_path
    source /etc/os-release
    case "$ID" in
        "centos" | "rhel")
            stage_one_script_path="centos/1_prepare_for_server.sh"
            stage_two_script_path="centos/2_prepare_for_k8s.sh"
            stage_three_script_path="centos/3_install_docker.sh" ;;
        "ubuntu")
            stage_one_script_path="ubuntu/1_prepare_for_server.sh"
            stage_two_script_path="ubuntu/2_prepare_for_k8s.sh" 
            stage_three_script_path="ubuntu/3_install_docker.sh" ;;
        "debian" )
            stage_one_script_path="debian/1_prepare_for_server"
            stage_two_script_path="debian/2_prepare_for_k8s.sh"
            stage_three_script_path="debian/3_install_docker" ;;
    esac

    for NODE in "${!ADD_WORKER[@]}"; do
        MSG2 "*** ${NODE} *** is Preparing for Linux Server"
        ssh ${NODE} "bash -s" < "${stage_one_script_path}" &> /dev/null &
    done
    MSG2 "Please Waiting ..."
    wait

    for NODE in "${!ADD_WORKER[@]}"; do
        MSG2 "*** ${NODE} *** is Preparing for Kubernetes"
        ssh ${NODE} "bash -s" < "${stage_two_script_path}" &> /dev/null &
    done
    MSG2 "Please Waiting ..."
    wait


    for NODE in "${!ADD_WORKER[@]}"; do
        MSG2 "*** ${NODE} *** is Installing Docker"
        ssh ${NODE} "bash -s" < "${stage_three_script_path}" &> /dev/null &
    done
    MSG2 "Please Waiting ..."
    wait
}


# 复制二进制文件 kubelet kube-proxy kubectl
function 4_copy_bnary_file_to_new_worker_node {
    MSG1 "4. copy binary file to new worker node"

    # 1. 解压二进制文件
    mkdir -p ${K8S_DEPLOY_LOG_PATH}/bin
    tar -xvf bin/${K8S_VERSION}/kube-proxy.tar.xz   -C ${K8S_DEPLOY_LOG_PATH}/bin/
    tar -xvf bin/${K8S_VERSION}/kubelet.tar.xz      -C ${K8S_DEPLOY_LOG_PATH}/bin/
    tar -xvf bin/${K8S_VERSION}/kubectl.tar.xz      -C ${K8S_DEPLOY_LOG_PATH}/bin/

    # 2. 将 k8s 二进制文件拷贝到新添加的 worker 节点上
    for NODE in "${ADD_WORKER[@]}"; do
        for PKG in \
            ${K8S_DEPLOY_LOG_PATH}/bin/kube-proxy \
            ${K8S_DEPLOY_LOG_PATH}/bin/kubelet \
            ${K8S_DEPLOY_LOG_PATH}/bin/kubectl; do
            scp ${PKG} ${NODE}:/usr/local/bin/
        done
    done
}


# 从第一个 worker 节点上把相关的：
#   1、k8s 证书文件
#   2、kubelet 和 kube-proxy 自启动文件
#   3、kublet 和 kube-proxy 配置文件
# 拷贝到新的 worker 节点上
function 5_copy_certs_and_config_file_to_new_worker_noe {
    MSG1 "5. copy certs and config file to new worker node"
    
    local WORKER_IP
    local ADD_NODE_PATH="/root/add_node"
    mkdir -p ${ADD_NODE_PATH}

    # 获取任何一个 worker 节点的 ip 地址
    for IP in "${WORKER[@]}"; do
        WORKER_IP=${IP}
        break; done

    # 将 worker 节点的 k8s 证书和配置文件先拷贝到当前主机上
    scp -r root@${WORKER_IP}:/etc/kubernetes/ ${ADD_NODE_PATH}
    scp -r root@${WORKER_IP}:/etc/etcd/ ${ADD_NODE_PATH}
    scp -r root@${WORKER_IP}:/etc/systemd/system/kubelet.service.d/ ${ADD_NODE_PATH}
    scp root@${WORKER_IP}:/lib/systemd/system/kubelet.service ${ADD_NODE_PATH}
    scp root@${WORKER_IP}:/lib/systemd/system/kube-proxy.service ${ADD_NODE_PATH}

    for NODE in "${ADD_WORKER[@]}"; do
        # 将复制过来的 k8s 证书和配置文件拷贝到新添加的 worker 节点上
        scp -r ${ADD_NODE_PATH}/kubernetes root@${NODE}:/etc/
        scp -r ${ADD_NODE_PATH}/etcd root@${NODE}:/etc/
        scp -r ${ADD_NODE_PATH}/kubelet.service.d root@${NODE}:/etc/systemd/system/
        scp ${ADD_NODE_PATH}/kubelet.service root@${NODE}:/lib/systemd/system/
        scp ${ADD_NODE_PATH}/kube-proxy.service root@${NODE}:/lib/systemd/system/

        #ssh root@${NODE} "mkdir -p /etc/cni/bin /var/lib/kubelet /var/log/kubernetes"
        # 为新添加的 worker 节点创建所需目录
        #for DIR_PATH in \
            #"/var/lib/kubelet" \
            #"/var/lib/kube-proxy" \
            #"/var/log/kubernetes"; do
            #ssh ${NODE} "mkdir -p ${DIR_PATH}"
    done
}


# enabled kublet, kube-proxy service
function 6_enable_kube_service {
    MSG1 "6. Enbled kubelet kube-proxy service"

    for NODE in "${ADD_WORKER[@]}"; do
        ssh root@${NODE} "systemctl daemon-reload"
        ssh root@${NODE} "systemctl enable --now docker"
        ssh root@${NODE} "systemctl enable kubelet"
        ssh root@${NODE} "systemctl restart kubelet"
        ssh root@${NODE} "systemctl enable kube-proxy"
        ssh root@${NODE} "systemctl restart kube-proxy" 
    done
}

function add_k8s_node {
    MSG1 "Adding k8s worker node ..."
    0_add_k8s_node_script_prepare
    1_configure_ssh_public_key_authentication
    2_copy_hosts_file_to_all_k8s_node
    3_run_stage_one_two_three
    4_copy_bnary_file_to_new_worker_node
    5_copy_certs_and_config_file_to_new_worker_noe
    6_enable_kube_service
}
