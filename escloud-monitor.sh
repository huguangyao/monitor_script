#!/bin/sh

# Version:v1.0
# Author:huguangyao. 
# Email:guangyao.hu@easystack.cn.
# Copyright EasyStack, Inc.
# All Rights Reserved.

NODES=""
MASTER_NODE="node-1"
IS_CONTROLLER_NODES=""
SERVICE="mysql haproxy rabbitmq mongo nova-api nova-novncproxy nova-objectstor nova-consoleaut \
         nova-conductor nova-cert nova-scheduler neutron-openvsw neutron-rootwra \
         neutron-metadat neutron-server neutron-ns-meta neutron-dhcp-ag neutron-l3-agen \
         cinder-backup cinder-api cinder-volume cinder-schedule 
         "

fatal () {
  echo -e "\033[31;40;1m$0:[`date +%D-%T`]: [ERROR]\033[0m" "\033[31;40;1m$@\033[0m" >> /root/cloud_error_log
  title_echo=$@
  fail_echo=$@
#  do_alarm "$title_echo" "$fail_echo" 1
}

usage () {
  echo -e "\033[31;40;1mUsage:\033[0m"
  echo -e "\033[31;40;1mIllegal option\033[0m"
}

warn_echo () {
  echo -e "\e[2;33m $1...[WARN]\n\e[0m"
}

succ_echo () {
  echo -e "\e[2;32m $1...[OK]\n\e[0m"
}

check_privilege () {
  if [[ `whoami` != "root" ]]; then
    fatal "Need root privilege"
  else
    succ_echo "Check current user is root..."
  fi
}

do_alarm () {
  hostname=$(hostname | awk -F '.' '{printf "%s.%s.%s", $1, $2, $3}')
  subject="["$hostname"] "$1
  content="["$hostname"] "$2
  dosms=$3
  ie="utf8"
  alarmCenter=""
  nowTime=`date +%Y%m%d%T`
  curl -d "ie=$ie" -d "group_name=$ALARM_GROUP" -d "subject=$subject" -d "content=$content" $alarmCenter -s
}

check_nodes () {
  NODES=$(cat /etc/hosts | grep node | awk -F " " '{printf "%s ", $2}')
  IS_CONTROLLER_NODES=$(cat /etc/haproxy/conf.d/020-keystone-1.cfg | grep server | awk '{print $2}')
}

check_uptime () {
  for node in $NODES; do
    uptime=$(ssh -o LogLevel=quiet $node 'uptime' | awk -F "days" '{print $1}' | awk -F " " '{print $3}') >/dev/null 2>&1
    if [ $uptime -le 0 ]; then
      fatal "$node uptime $uptime days, This node has recently been restarted"
    else
      succ_echo "$node uptime $uptime days..."
    fi
  done
}

check_memory () {
  for node in $NODES; do
    free_mem=$(ssh -o LogLevel=quiet $node 'free -g | sed -n "2, 1p"'|awk '{printf "%s %s",$4,$7}'|awk '{sum=$1+$2} END{print sum}')
    if [ $free_mem -le 8 ]; then
      fatal "$node free memory and cached memory total left $free_mem GB"
    else
      succ_echo "$node free memory and cached memory total left $free_mem GB..."
    fi
  done
}

check_network () {
  hostname=$(hostname | awk -F '.' '{printf "%s", $1}')
  is_master=$( [[ $hostname == $MASTER_NODE ]] && echo "true" || echo "false" )
  if [ ${is_master} == "true" ]; then
    for node in $NODES ; do
      ping -c 2 $node > /dev/null 2>&1 && succ_echo "OpenStack $node Connected..." || \
        fatal "Openstack node $node can not be connected"
    done
  else
    fatal "Please run this script on $MASTER_NODE"
  fi
}

get_port_status () {
  MASTER_NODE=$1
  port=$2
  (echo >/dev/tcp/$MASTER_NODE/$port) &>/dev/null
  if [ $? -eq 0 ]; then
    succ_echo "$MASTER_NODE:$port is open ..."
  else
    fatal "Master $MASTER_NODE:$port is closed"
  fi
}

check_db () {
  get_port_status $MASTER_NODE "3307"
  binary_log_size=`echo "SHOW BINARY LOGS;" | mysql -uroot  | tail -1 | awk -F " " '{print $2}'`
  if [[ -n $binary_log_size && $binary_log_size > 100000000  ]]; then
    succ_echo "Check binary logs size in  MySQL database"
  else
    fatal "Check binary logs size in MySQL database"
  fi
}

check_escloud_service () {
  for node in $NODES; do
    echo $IS_CONTROLLER_NODES | grep $node >/dev/null 2>&1
    if [ $? -ne 0 ];then
      COMPUTE_SERVICE="libvirt nova-compute neutron-openv"
      for i in $COMPUTE_SERVICE ; do
        status=`ssh -o LogLevel=quiet $node 'ps -A' | grep ${i} | wc -l`
        if [ $status -gt 0 ] ; then
          succ_echo "$node ${i}-serveice..."
        else
          fatal "Please make sure ${i}-service on $node is running"
        fi
      done
    else
      for i in $SERVICE ; do
        status=`ssh -o LogLevel=quiet $node 'ps -A' | grep ${i} | wc -l`
        if [ $status -gt 0 ] ; then
          succ_echo "$node ${i}-serveice..."
        else
          fatal "Please make sure ${i}-service on $node is running"
        fi
      done
    fi
  done
}

check_ceph_cluster () {
   ceph_health_stat=$(ceph health detail)
   if [ $ceph_health_stat == "HEALTH_OK" ]; then
     succ_echo "The ceph cluster health check..."
   else
     fatal "The ceph cluster health check failed $ceph_health_stat"
   fi
}

check_osd_stat () {
  for node in $NODES; do
    node_position_count=`ceph osd tree | grep -n -w $node | awk -F: '{print $1}'`
    if [[ $node_position_count -ne "0" ]]; then
      node_osd_state=`ceph osd tree|sed -n $(($node_position_count+1)),$(($node_position_count+9))p | grep down | wc -l`
      if [[ $node_osd_state -ne "0" ]]; then
        fatal "$node_osd_state osd down on $node"
      fi
    fi
  done
}

check_crm_stat () {
  crm_status=$(crm status|grep Online|cut -c 9-)
  crm_node_count=$(echo $crm_status | awk -F[ '{print $2}'|awk -F] '{print $1}'|awk '{print NF}')
  con_node_count=$(echo $IS_CONTROLLER_NODES | awk '{print NF}')
  if [[ $crm_node_count -lt $con_node_count ]]; then
    fatal "crm cluster has one or more nodes offline"
  else
    succ_echo "crm cluster status is..."
  fi
}

check_rabbitmq () {
  con_node_count=$(echo $IS_CONTROLLER_NODES | awk '{print NF}')
  rabbit_num=$(rabbitmqctl cluster_status|grep "running_nodes"|awk -F[ '{print $2}'|awk -F] '{print $1}'|awk -F, '{print NF}')
  if [[ $rabbit_num -lt $rabbit_num ]]; then
    fatal "rabbitmq cluster has node down"
  else
    succ_echo "rabbitmq cluster status is..."
  fi
}

check_process_mongo () {
  mongo_pid=$(cat /var/run/mongodb/mongod.pid)
  mongo_mem=$(ps u -p $mongo_pid | awk '{sum=sum+$6}; END {print sum/1024}')
  mongo_Per_phy_memory=$(ps u -p $mongo_pid | sed -n "2,1p" | awk '{print $4}')
  if [[ $(echo "$mongo_mem >= 10000"|bc) -eq 1 || $(echo "$mongo_Per_phy_memory >=20"|bc) -eq 1 ]]; then
    fatal "Mongod process using $mongo_mem MB memory,$mongo_Per_phy_memory percentage of system memory"
  else
    succ_echo "Mongo process using $mongo_mem MB memory,$mongo_Per_phy_memory percentage of system memory... "
  fi
}

check_process_mysql () {
  mysql_pid=$(cat /var/run/mysql/mysqld.pid)
  mysql_mem=$(ps u -p $mysql_pid | awk '{sum=sum+$6}; END {print sum/1024}')
  mysql_Per_phy_memory=$(ps u -p $mysql_pid | sed -n "2,1p" | awk '{print $4}')
  if [[ $(echo "$mysql_mem >= 10000"|bc) -eq 1 || $(echo "$mysql_Per_phy_memory >=10"|bc) -eq 1 ]]; then
    fatal "MySQL process using $mysql_mem MB memory,$mysql_Per_phy_memory percentage of system memory"
  else
    succ_echo "MySQL process using $mysql_mem MB memory,$mysql_Per_phy_memory percentage of system memory... "
  fi
}

check_process_memcache () {
  memcache_pid=$(cat /var/run/memcached/memcached.pid)
  memcache_mem=$(ps u -p $memcache_pid | awk '{sum=sum+$6}; END {print sum/1024}')
  memcache_Per_phy_memory=$(ps u -p $memcache_pid | sed -n "2,1p" | awk '{print $4}')
  if [[ $(echo "$memcache_mem >= 10000"|bc) -eq 1 || $(echo "$memcache_Per_phy_memory >=10"|bc) -eq 1 ]]; then
    fatal "memcache process using $memcache_mem MB memory,$memcache_Per_phy_memory percentage of system memory"
  else
    succ_echo "memcache process using $memcache_mem MB memory,$memcache_Per_phy_memory percentage of system memory... "
  fi
}

if [[ -f /root/cloud_error_log ]]; then
  rm -rf /root/cloud_error_log
fi
check_privilege
check_nodes
check_network
check_uptime
check_memory
check_db
check_ceph_cluster
check_osd_stat
check_crm_stat
check_rabbitmq
check_process_mysql
check_process_mongo
check_process_memcache
check_escloud_service
if [[ -f /root/cloud_error_log ]]; then
  echo "#############################################"
  warn_echo "Some problems exist in current cloud environment"
  echo "#############################################"
  echo "*******************************************"
  cat /root/cloud_error_log
  echo "*******************************************"
else
  echo "#############################################"
  succ_echo "Congratulations everything is"
  echo "#############################################"
fi

