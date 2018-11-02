#!/usr/bin/env bash

source "$TOP_DIR/common/utils.sh"
source "$TOP_DIR/common/configs.sh"

function _repo_epel() {
    if [[ "$*" == "starting" ]]; then
        _PARAMS=" > /dev/null 2>&1"
    else
        _PARAMS=""
    fi

    if [ ! -e "$OS_GPG_KEYS_PATH/$EPEL_GPG_KEY" ] && [ -e "$LOCAL_GPG_KEYS_PATH/$EPEL_GPG_KEY" ]; then
        eval "yes | cp ${LOCAL_GPG_KEYS_PATH}/${EPEL_GPG_KEY} ${OS_GPG_KEYS_PATH}/.$_PARAMS"
    fi
    eval "yum install -y epel-release$_PARAMS"
}


function _repo() {
    yum clean metadata
    yum update -y
    _repo_epel
    yum install -y centos-release-openstack-$INS_OPENSTACK_RELEASE
    if [ $? -ne 0 ]; then
        echo "## Fail to add Openstack repo centos-release-openstack-$INS_OPENSTACK_RELEASE"
        exit 7
    fi
    if [[ ${REPO_MIRROR_ENABLE^^} == 'TRUE' ]]; then
        for REPO_MIRROR in "${!REPO_MIRROR_URLS[@]}"; do
            eval _REPO_FILE="${REPO_FILES[$REPO_MIRROR]}"
            eval _REPO_URL="${REPO_MIRROR_URLS[$REPO_MIRROR]}"

            if [[ $REPO_MIRROR == 'base' ]] || [[ $REPO_MIRROR == 'epel' ]]; then
                crudini --set ${_REPO_FILE} $REPO_MIRROR baseurl ${_REPO_URL}
                crudini --del ${_REPO_FILE} $REPO_MIRROR mirrorlist
            elif [[ $REPO_MIRROR == 'cloud' ]]; then
                crudini --set ${_REPO_FILE} centos-openstack-$INS_OPENSTACK_RELEASE baseurl ${_REPO_URL}
            elif [[ $REPO_MIRROR == 'virt' ]]; then
                crudini --set ${_REPO_FILE} centos-qemu-ev baseurl ${_REPO_URL}
            fi
        done
        yum clean metadata
        yum update -y
    fi
}


function _ntp() {

    yum install -y ntp net-tools sntp ntpdate

    systemctl enable ntpd.service
    systemctl enable sntp.service
    systemctl enable ntpdate.service
    systemctl stop ntpd.service

    if [ ${NTPSERVER^^} == TRUE ]; then
        # use canadian ntp server
        sed -i.bak "s/centos.pool/ca.pool/g" /etc/ntp.conf
        cat /etc/ntp.conf |grep "fudge 127.127.1.0 stratum 16"
        if [ $? -eq 1 ]; then
            echo "server 127.127.1.0 iburst" >> /etc/ntp.conf
            echo "fudge 127.127.1.0 stratum 16" >> /etc/ntp.conf
        fi
    else
        sed -i.bak "s/^server 0.centos.pool.ntp.org iburst/server $NTPSRV/g" /etc/ntp.conf
        sed -i 's/^server 1.centos.pool.ntp.org iburst/# server 1.centos.pool.ntp.org iburst/g' /etc/ntp.conf
        sed -i 's/^server 2.centos.pool.ntp.org iburst/# server 2.centos.pool.ntp.org iburst/g' /etc/ntp.conf
        sed -i 's/^server 3.centos.pool.ntp.org iburst/# server 3.centos.pool.ntp.org iburst/g' /etc/ntp.conf
    fi
    systemctl restart sntp.service
    systemctl restart ntpdate.service
    systemctl restart ntpd.service
}


function _base() {
    trap '_ERRTRAP $LINENO $?' ERR

    set -o xtrace

    _repo

    _import_config

    # set installed Kernel limits(INS_KERNELS, default 2) and clean up old Kernels
    crudini --set /etc/yum.conf main installonly_limit $INS_KERNELS
    cur_kernels=$(rpm -q kernel | wc -l)
    if [ "$cur_kernels" -gt "$INS_KERNELS" ]; then
        yum install -y yum-utils wget
        package-cleanup -y --oldkernels --count=$INS_KERNELS
    fi

    yum autoremove -y firewalld
    # install essential packages and tools
    yum install -y psmisc tcpdump

    yum install -y openstack-selinux python-pip python-openstackclient
    pip install --upgrade pip

    _ntp

    for service in $SERVICES; do
        eval DB_USER_${service^^}=$service
        eval DB_PWD_${service^^}=$service
     done

     for service in $SERVICES $SERVICES_NODB; do
        eval KEYSTONE_U_${service^^}=$service
        eval KEYSTONE_U_PWD_${service^^}=$service
    done

    cat > ~/openrc << EOF
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=$KEYSTONE_T_NAME_ADMIN
export OS_USERNAME=$KEYSTONE_U_ADMIN
export OS_PASSWORD=$KEYSTONE_U_ADMIN_PWD
export OS_AUTH_URL=http://$CTRL_MGMT_IP:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
    source ~/openrc
}


# check service existence before installing it.
function service_check() {
# $1 is the service name, e.g. database
# $2 is the listening port when the service was running, e.g. 3306
# if the service is running return 0 else return 1
    netstat -anp|grep ":$2" > /dev/nul
    if [ $? -eq 0 ]; then
        echo "Skip $1 installation, because the $1 service is running."
        return 0
    else
        echo "Installing $1..."
        return 1
    fi
}


function database() {
    service_check database 3306 && return
    if [[ ${DB_HA^^} == 'TRUE' ]]; then
        yum install -y mariadb-galera-server galera percona-xtrabackup socat
    else
        yum install -y mariadb mariadb-server MySQL-python python-openstackclient
    fi
    # generate config file
cat > ~/my.cnf << EOF
[mysqld]
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
# Disabling symbolic-links is recommended to prevent assorted security risks
symbolic-links=0
# Settings user and group are ignored when systemd is used.
# If you need to run mysqld under a different user or group,
# customize your systemd unit file for mariadb according to the
# instructions in http://fedoraproject.org/wiki/Systemd
bind-address = $MGMT_IP
default-storage-engine = innodb
# innodb_file_per_table = 1
collation-server = utf8_general_ci
init-connect = 'SET NAMES utf8'
character-set-server = utf8


[mysqld_safe]
log-error=/var/log/mariadb/mariadb.log
pid-file=/var/run/mariadb/mariadb.pid

#
# include all files from the config directory
#
!includedir /etc/my.cnf.d

EOF

    systemctl enable mariadb.service
    systemctl start mariadb.service

    (mysqlshow -uroot -p$MYSQL_ROOT_PASSWORD 2>&1) > /dev/nul

    if [ $? -ne 0 ]; then
        yum install -y expect

        # initialize database
        SECURE_MYSQL=$(expect -c "
set timeout 3

spawn mysql_secure_installation

expect \"Enter current password for root (enter for none):\"
send \"$MYSQL\r\"

expect \"Change the root password?\"
send \"y\r\"

expect \"New password:\"
send \"$MYSQL_ROOT_PASSWORD\r\"

expect \"Re-enter new password:\"
send \"$MYSQL_ROOT_PASSWORD\r\"

expect \"Remove anonymous users?\"
send \"y\r\"

expect \"Disallow root login remotely?\"
send \"n\r\"

expect \"Remove test database and access to it?\"
send \"y\r\"

expect \"Reload privilege tables now?\"
send \"y\r\"

expect eof
")

        echo "$SECURE_MYSQL"

        yum erase -y expect
    fi

    # Enable root remote access MySQL
    mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
    mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "GRANT ALL ON *.* TO 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
    mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "grant all on *.* to 'galera'@'localhost' identified by '$DB_XTRABACKUP_PASSWORD';"

    _start_options=''
    if [[ ${DB_HA^^} == 'TRUE' ]]; then
        crudini --set $DB_HA_CONF galera wsrep_on ON
        crudini --set $DB_HA_CONF galera wsrep_provider "$DB_WSREP_PROVIDER"
        crudini --set $DB_HA_CONF galera wsrep_cluster_address "gcomm://$DB_CLUSTER_IP_LIST"
        crudini --set $DB_HA_CONF galera binlog_format row
        crudini --set $DB_HA_CONF galera default_storage_engine InnoDB
        crudini --set $DB_HA_CONF galera innodb_autoinc_lock_mode 2
        crudini --set $DB_HA_CONF galera bind-address "$MGMT_IP"
        crudini --set $DB_HA_CONF galera wsrep_cluster_name "$DB_CLUSTER_NAME"
        crudini --set $DB_HA_CONF galera wsrep_sst_auth "$DB_WSREP_SST_AUTH"
        crudini --set $DB_HA_CONF galera wsrep_sst_method "$DB_WSREP_SST_METHOD"
        crudini --set $DB_HA_CONF galera wsrep_node_address "$MGMT_IP"
        crudini --set $DB_HA_CONF galera wsrep_node_name $(hostname -s)
        crudini --set $DB_HA_CONF galera wsrep_slave_threads $(grep -c ^processor /proc/cpuinfo)
        crudini --set $DB_HA_CONF galera innodb_flush_log_at_trx_commit 0

        DB_CLUSTER_IP_LIST=$(echo $DB_CLUSTER_IP_LIST | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
        read -ra DB_CLUSTER_IP_LIST <<< $DB_CLUSTER_IP_LIST
        primary_ip=${DB_CLUSTER_IP_LIST[0]}
        other_ips=${DB_CLUSTER_IP_LIST[1]}

        if [ -z "$other_ips" ]; then
            echo "Error: multiply ips required at the option 'DB_CLUSTER_IP_LIST' for database HA."
            exit 30
        fi

        systemctl stop mariadb.service
        systemctl disable mariadb.service

        # run at backend to avoid any hangout
        nohup mysql_install_db --defaults-file=$DB_HA_CONF --user=mysql >/dev/null 2>&1 &
        _wait 8s

        ip address | grep "$primary_ip"
        if [ $? -eq 0 ]; then
            _start_options="--wsrep-new-cluster"
        fi
        # run at backend to avoid any hangout
        nohup mysqld_safe --defaults-file=$DB_HA_CONF --user=mysql $_start_options >/dev/null 2>&1 &
        _wait 5s

        # check the cluster status, show how many nodes in the cluster
        if [ ! -z "$_start_options" ]; then
            _wait 20s
        fi
        mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
    fi

    if [ ! -z "$_start_options" ] || [[ ${DB_HA^^} == 'FALSE' ]]; then
        _services_db_creation
    fi
}

function services_db_creation() {
    _services_db_creation
}

function mq() {
    service_check rabbitmq-server 5672 && return
    ## install rabbitmq
    yum install -y rabbitmq-server
    systemctl enable rabbitmq-server.service

    sed -i.bak "s#%% {tcp_listeners, \[5672\]},#{tcp_listeners, \[{\"$MGMT_IP\", 5672}\]}#g" /etc/rabbitmq/rabbitmq.config

    if [[ ${RABBIT_HA^^} == 'TRUE' ]]; then
        declare -p RABBIT_CLUSTER > /dev/null 2>&1
        if [ $? -eq 1 ]; then
            echo "rabbitmq ha required to define RABBIT_CLUSTER, but it was not defined" && exit 30
        fi

        if [ ! -z "$ERLANG_COOKIE" ]; then
            echo "$ERLANG_COOKIE" > /var/lib/rabbitmq/.erlang.cookie
        else
            echo "Error: the option ERLANG_COOKIE is empty."
            exit 20
        fi
        chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie
        chmod 400 /var/lib/rabbitmq/.erlang.cookie

        systemctl restart rabbitmq-server.service

        rabbitmqctl set_cluster_name openstack
        rabbitmqctl set_policy ha-all '^(?!amq\.).*' '{"ha-mode": "all"}'
        RABBIT_LIST=''
        _first_node=True
        for node in "${!RABBIT_CLUSTER[@]}"; do
            node_info=${RABBIT_CLUSTER[$node]}
            grep "$node_info" /etc/hosts || echo "$node_info" >> /etc/hosts
            read -ra node_info <<< "$node_info"
            _ip="${node_info[0]}"
            _hostname="${node_info[1]}"
            if [ -z "$RABBIT_LIST" ]; then
                RABBIT_LIST="$RABBIT_USER:$RABBIT_PASS@$_ip:$RABBIT_PORT"
            else
                RABBIT_LIST="$RABBIT_USER:$RABBIT_PASS@$_ip:$RABBIT_PORT,$RABBIT_LIST"
            fi
            if [[ "${_first_node^^}" == 'TRUE' ]]; then
                _first_node="$_hostname"
            fi
        done

        hostname -s | grep $_first_node
        if [[ "$?" -ne 0 ]]; then
            rabbitmqctl stop_app
            rabbitmqctl join_cluster --ram "rabbit@$_first_node"
            rabbitmqctl start_app
            rabbitmqctl cluster_status | grep "rabbit@$_first_node"
            _wait 5s
        fi

    else
        systemctl restart rabbitmq-server.service
    fi
    rabbitmqctl change_password "$RABBIT_USER" "$RABBIT_PASS"
}


function _memcached() {
    service_check memcached 11211 && return
    yum install -y memcached
    pip install --upgrade python-memcached
    crudini --set /etc/sysconfig/memcached '' OPTIONS "\"-l $MGMT_IP\""
    systemctl restart memcached
}


function _httpd() {
    service_check httpd 80 && return
    yum install -y httpd
    sed -i "s#^ServerName www.example.com:80#ServerName 127.0.0.1#g" /etc/httpd/conf/httpd.conf
    systemctl enable httpd.service
    systemctl restart httpd.service
}


function keystone() {
    # install keystone
    yum install -y openstack-keystone mod_wsgi

    _httpd
    #_memcached
    _keystone_configure

}


function glance() {
    ## glance
    yum install -y openstack-glance
    _memcached

    if [ -z "$KEYSTONE_T_ID_SERVICE" ]; then
        export KEYSTONE_T_ID_SERVICE=$(openstack project show service | grep '| id' | awk '{print $4}')
    fi

    _glance_configure

    su -s /bin/sh -c "glance-manage db_sync" glance

    systemctl enable openstack-glance-api.service openstack-glance-registry.service
    systemctl restart openstack-glance-api.service openstack-glance-registry.service

    [[ -e ~/openrc ]] && source ~/openrc
    openstack image show $IMAGE_NAME >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        if [ ! -e /tmp/images/$IMAGE_FILE ]; then
            mkdir -p /tmp/images
            wget -P /tmp/images $IMAGE_URL
        fi

        local _COUNT=0
        while true; do
            _wait 5s
            (netstat -anp|grep 9292) && (netstat -anp|grep 9191)
            if [ $? -eq 0 ]; then
                break
            fi
            if [ ${_COUNT} -gt 10 ]; then
                echo "glance service cannot work properly."
                exit 10
            fi
            let $((_COUNT++))
        done
        openstack image create --file /tmp/images/$IMAGE_FILE \
          --disk-format qcow2 --container-format bare --public $IMAGE_NAME
        openstack image list

        #rm -rf /tmp/images
    fi
}


function nova_ctrl() {
    ## nova controller
    yum install -y openstack-nova-api openstack-nova-conductor \
                   openstack-nova-console openstack-nova-novncproxy \
                   openstack-nova-scheduler openstack-nova-placement-api

    _nova_configure nova_ctrl

    systemctl enable openstack-nova-api.service \
      openstack-nova-consoleauth.service openstack-nova-scheduler.service \
      openstack-nova-conductor.service openstack-nova-novncproxy.service
    systemctl restart openstack-nova-api.service \
      openstack-nova-consoleauth.service openstack-nova-scheduler.service \
      openstack-nova-conductor.service openstack-nova-novncproxy.service
    _create_initial_flavors

}


function nova_compute() {
    yum install -y openstack-nova-compute sysfsutils

    _nova_configure nova_compute
    # for resizing and migration
    _nova_ssh_key_login
    systemctl enable libvirtd.service openstack-nova-compute.service
    systemctl restart libvirtd.service openstack-nova-compute.service
    _nova_map_hosts_cell0
}


function neutron_ctrl() {
    # neutron
    yum install -y openstack-neutron openstack-neutron-ml2 which

    _neutron_configure neutron_ctrl

    su -s /bin/sh -c "neutron-db-manage --config-file $NEUTRON_CONF --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

    systemctl enable neutron-server.service
    systemctl restart neutron-server.service
}


function neutron_compute() {
    # if neutron_dhcp is running with neutron_compute, this may
    # cause the second role to be left unconfigured
    unset _NEUTRON_CONFIGED
    # install neutron components on compute nodes
    yum install -y openstack-neutron-ml2 openstack-neutron-openvswitch ipset

    systemctl enable openvswitch.service
    systemctl restart openvswitch.service

    _neutron_configure neutron_compute

    systemctl restart openstack-nova-compute.service
    systemctl enable neutron-openvswitch-agent.service
    systemctl restart neutron-openvswitch-agent.service

}

function neutron_dhcp() {
    # if neutron_dhcp is running with neutron_compute, this may
    # cause the second role to be left unconfigured
    unset _NEUTRON_CONFIGED
    # install neutron dhcp agent on controller or compute nodes
    yum install -y openstack-neutron

    _neutron_configure neutron_dhcp

    systemctl enable neutron-dhcp-agent.service
    systemctl restart neutron-dhcp-agent.service
}

function neutron_network() {
    yum install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

    systemctl enable openvswitch.service
    systemctl restart openvswitch.service

    _neutron_configure neutron_network

    systemctl enable neutron-openvswitch-agent.service neutron-l3-agent.service \
    neutron-dhcp-agent.service neutron-metadata-agent.service neutron-ovs-cleanup.service

    systemctl restart neutron-openvswitch-agent.service neutron-l3-agent.service \
    neutron-dhcp-agent.service neutron-metadata-agent.service
}


function cinder_ctrl() {
    # cinder ctrl
    yum install -y openstack-cinder

    _cinder_configure cinder_ctrl

    su -s /bin/sh -c "cinder-manage db sync" cinder

    systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
    systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service
}


function _lvm_volume() {
    _pv=$(pvdisplay | grep 'PV Name' | grep $CINDER_VOL_DEV | awk '{print $3}')
    if [[ "$_pv" != "$CINDER_VOL_DEV" ]]; then
        if [[ -e $CINDER_VOL_DEV ]]; then
            pvcreate "$CINDER_VOL_DEV"
        else
            # if no cinder volume disk assigned, create a file as volume instead
            # This creates a 2GB file as the physical volume
            losetup -a | grep "$CINDER_VOL_FILE" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                [[ -e "$CINDER_VOL_FILE" ]] || dd if=/dev/zero of="$CINDER_VOL_FILE" bs=1 count=0 seek="$CINDER_VOL_FILE_SIZE"G
                losetup -a | grep $CINDER_VOL_DEV || losetup "$CINDER_VOL_DEV" "$CINDER_VOL_FILE"
                pvcreate -y $CINDER_VOL_DEV
            fi

            # file volume need to re-attach after reboot
            grep -r "losetup $CINDER_VOL_DEV $CINDER_VOL_FILE" /etc/rc.d/rc.local || echo "losetup $CINDER_VOL_DEV $CINDER_VOL_FILE" >>  /etc/rc.d/rc.local
            chmod u+x /etc/rc.d/rc.local
            _state=$(systemctl list-unit-files rc-local.service | grep rc-local.service | awk '{print $2}')

            if [[ "${_state^^}" == 'DISABLE' ]]; then
                systemctl enable rc-local.service
            fi
        fi
    fi

    vgdisplay | grep 'VG Name' | grep "$CINDER_VG_NAME" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        vgcreate "$CINDER_VG_NAME" "$CINDER_VOL_DEV"
    fi
}


function cinder_storage() {
    # cinder volume
    yum install -y lvm2 device-mapper-persistent-data openstack-cinder targetcli python-keystone

    _lvm_volume

    update_lvm_filter

    _cinder_configure cinder_storage

    systemctl enable openstack-cinder-volume.service target.service
    systemctl start openstack-cinder-volume.service target.service
}


function dashboard() {
    yum install -y openstack-dashboard

    # need to install httpd first
    _httpd
    _memcached
    _horizon_configure

    systemctl enable httpd.service memcached.service
    systemctl restart httpd.service memcached.service

}


function allinone() {
    database
    mq
    keystone
    glance
    nova_ctrl
    neutron_ctrl
    cinder_ctrl
    dashboard
    nova_compute
    neutron_compute
    neutron_network
}


function controller() {
    database
    mq
    keystone
    nova_ctrl
    neutron_ctrl
    cinder_ctrl
    glance
    dashboard
}

function shared() {
    database
    mq
}

function api() {
    keystone
    glance
    nova_ctrl
    neutron_ctrl
    cinder_ctrl
    dashboard
}

function network() {
    neutron_network
}


function compute() {
    nova_compute
    neutron_compute
}


function main {
    _help $@
    shift $?
    _log
    _display starting
    _installation $@ | _timestamp
    _display completed
}
