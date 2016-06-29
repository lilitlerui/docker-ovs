#!/bin/bash

function __CheckParam(){
    [[ ! -n $1 ]] && \
        echo "Faild: not availible param." &&\
        __Usage &&\
        exit 1
}
__CheckParam $1

container_host_nic=em1
integration_bridge=br-int
tunenl_bridge=br-tun
docker_bridge=br0
filepath=$(cd "$(dirname "$0")"; pwd)
run_log=$filepath/docker-ovs.log
statefile=$filepath/docker-ovs.state
namespace_dir=/var/run/netns

container_id=$2
short_id=${2:0:8}
container_cidr=$3
container_net=${container_cidr%@*}
container_gateway=${container_cidr##*@}
container_ip=${container_net%/*}
container_mask=${container_net#*/}
container_bridge=qbr-$short_id

[[ ! -d $namespace_dir ]] && mkdir -p $namespace_dir
if [[ `command -v ovs-vsctl` != '/usr/bin/ovs-vsctl'  ]] || [[ `command -v ovs-ofctl` != '/usr/bin/ovs-ofctl' ]];then
    echo "Faild: OpenVswtich Not Found!"
    exit 1
fi

function __Usage(){
    echo "Syntax:"
    echo "init base openvswitch network. like this."
    echo "docker-ovs init"
    echo "create new network for contaniner like this."
    echo "docker-ovs create <container_id> 10.1.1.5/24@10.1.1.1"
    echo "delete container network like this."
    echo "docker-ovs delete <container_id>"
    echo "attach container network like this."
    echo "docker-ovs attach <container_id>"
    echo "docker-ovs attach <container_id> 10.1.1.15/24@10.1.1.1"
    echo "detach container network like this."
    echo "docker-ovs detach <container_id>"
}

function __Checkfile(){
    if [[ ! -f $statefile ]];then
        echo "Faild: Cant found file docker-ovs" 
        exit 1
    fi
}

function __CheckContainer(){
    #---------------------------------
    #----- $1  container short id
    #---------------------------------
    __Checkfile
    cat $statefile | grep $1 > /dev/null 2>&1 
    [[ $? -ne 0 ]] && echo "Faild: Could not found Container:$1" &&\
        exit 1
}

function __AddState(){
    __Checkfile
    time=`date +%F-%T`
    #printf "ID    IP/MASK  GATEWAY   QOSUUID   Q1UUID   Q1UUID  STATES  CREATE_TIME"
    printf "%-20s    %-20s    %-20s    %-40s    %-40s    %-40s    %-20s    %-20s\n" $1 $2 $3 $4 $5 $6 $7 ${time} >> $statefile
}

function __DeleteState(){
    __Checkfile
    sed -i "/^${1}.*/d" $statefile
}

function __GetState(){
    #----------------------------------
    #----- $1  container short id
    #----- $2  IP\QosUuid\Q0Uuid\Q1Uuid\State 
    #----------------------------------
    __Checkfile
    __CheckContainer $1
    [[ $2 == 'ip' ]] && \
        cat $statefile | grep $1 | awk '{print $2}'
    [[ $2 == 'gateway' ]] && \
        cat $statefile | grep $1 | awk '{print $3}'
    [[ $2 == 'qos' ]] && \
        cat $statefile | grep $1 | awk '{print $4}'
    [[ $2 == 'q0' ]] && \
        cat $statefile | grep $1 | awk '{print $5}'
    [[ $2 == 'q1' ]] && \
        cat $statefile | grep $1 | awk '{print $6}'
    [[ $2 == 'state' ]] && \
        cat $statefile | grep $1 | awk '{print $7}'
}

function __ChangeState(){
    #----------------------------------
    #----- $1  container short id
    #----- $2  container state (Attache/Detache)
    #----------------------------------
    __Checkfile
    __CheckContainer $1
    cat $statefile | grep $1 > /tmp/$1.state
    __container_net=`cat /tmp/$1.state |awk '{print $2}'`
    __container_gateway=`cat /tmp/$1.state |awk '{print $3}'`
    sed -i "/^${1}.*/d" $statefile
    [[ $2 == 'attache' ]] && \
        __AddState ${container_id:0:18} $__container_net $__container_gateway `__GetOvsQosUuid qos qvr-$short_id` `__GetOvsQosUuid q0 qvr-$short_id` `__GetOvsQosUuid q1 qvr-$short_id` "attache"
        #sed -i 's/detache/attache/g' /tmp/$1.state
    [[ $2 == 'detache' ]] && \
        __AddState ${container_id:0:18} $__container_net $__container_gateway null null null "detache"
        #sed -i 's/attache/detache/g' /tmp/$1.state
    rm -rf /tmp/$1.state >> $statefile
}

function __GetOvsQosUuid(){
    #-------------------------
    #-----  $1  flows type (qos q0 q1)
    #-----  $2  qvr veth
    #-------------------------
    qos_uuid=`ovs-vsctl list port $2 | grep qos |awk '{print $3}'`
    [[ $1 == 'qos' ]] && qos=`ovs-vsctl list port $2 | grep qos | awk '{print $3}'` && \
        echo ${qos}
    [[ $1 == 'q0' ]] && queue=`ovs-vsctl list qos $qos_uuid | grep queues | awk '{print $3}'` && \
        echo ${queue:3:36}
    [[ $1 == 'q1' ]] && queue=`ovs-vsctl list qos $qos_uuid | grep queues | awk '{print $4}'` && \
        echo ${queue:2:36}
}

function __FlowsTableQosBoardCast(){
    # Create a Qos rules, and Flows tables by Ovs.
    # config two queues, the one used by match BoardCast Pakage,anothor use by normal communicate
    #-------------------------
    #-----  $1  container_bridge
    #-----  $2  in port (tap veth)
    #-----  $3  out port (qvr veth)
    #-------------------------
    inport=`ovs-ofctl show $1 | grep $2 | awk '{print substr($1,1,1)}'`
    outport=`ovs-ofctl show $1 |grep $3 | awk '{print substr($1,1,1)}'`

    ovs-vsctl set port $3 qos=@newqos -- --id=@newqos create qos type=linux-htb other-config:max-rate=1000000000 queues=0=@q0,1=@q1 -- --id=@q0 create queue other-config:min-rate=500000000 other-config:max-rate=1000000000 -- --id=@q1 create queue other-config:min-rate=1000000 other-config:max-rate=1000000  > /dev/null 2>&1
    [[ $? -ne 0 ]] && \
        echo "Faild: Create Qos faild!" && \
        exit 100
    ovs-ofctl add-flow $1 "table=1, in_port=${inport}, dl_src=00:00:00:00:00:00/01:00:00:00:00:00, actions=enqueue:${outport}:0"
    ovs-ofctl add-flow $1 "table=0, in_port=${inport}, dl_src=01:00:00:00:00:00/01:00:00:00:00:00, actions=enqueue:${outport}:1"
    ovs-ofctl dump-flows $1 |grep enqueue > /dev/null 2>&1 
    [[ $? -ne 0 ]] && \
        echo "Faild: Flows tables enable faild!" && \
        exit 101
}

function __CleanFlows(){
    #Clean the containner's qos and flows on its bridge
    #-------------------------
    #-----  $1  container_bridge
    #-----  $2  in port (qvr veth)
    #-------------------------
    inport=`ovs-ofctl show $1 | grep $2 | awk '{print substr($1,1,1)}'`
    qos_uuid=`__GetOvsQosUuid qos $2`
    queue0=`__GetOvsQosUuid q0 $2`
    queue1=`__GetOvsQosUuid q1 $2`
    ovs-vsctl clear port $2 qos
    ovs-vsctl destroy qos $qos_uuid
    ovs-vsctl destroy queue $queue0
    ovs-vsctl destroy queue $queue1
    ovs-ofctl del-flows $1 "in_port=${inport}"
}

function __CheckIPAddr()
{
    echo $1|grep "^[0-9]\{1,3\}\.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}$" > /dev/null;
    if [ $? -ne 0 ];then
        return 1
    fi
    ipaddr=$1
    a=`echo $ipaddr|awk -F . '{print $1}'`
    b=`echo $ipaddr|awk -F . '{print $2}'`
    c=`echo $ipaddr|awk -F . '{print $3}'`
    d=`echo $ipaddr|awk -F . '{print $4}'`
    for num in $a $b $c $d
    do
        if [ $num -gt 255 ] || [ $num -lt 0 ];then
            echo 'Error: an inet prefix is expected rather than "$1".' && \
            exit 1
        fi
    done
    ping -c 1 $1 > /dev/null 2>&1
    [[ $? -eq 0 ]] && \
        echo "Faild: Ipaddr $1 are using now!" && \
        exit 1 
    return 0
}

function __AttacheContainerNetwork(){
    # Add Container's nic into the NameSpace. Configure Cidr to the nic
    #-------------------------
    #-----  $1   containser id
    #-----  $2   containser pid
    #-----  $3   containser veth port
    #-----  $4   containser CIDR
    #-------------------------
    __Checkfile
    cat $statefile | grep $1 > /dev/null  2>&1
    tag=$?
    if [[ $tag -eq 0 ]];then
        _container_net=`__GetState $1 ip`
        _container_gateway=`__GetState $1 gateway`
        _container_ip=${_container_net%/*}
	[[ `__GetState $1 state` == 'attache' ]] && \
  	    echo "Faild: Container $1 is attaching!" && \
	    exit 1
    else
	_container_net=${4%@*}
	_container_gateway=${4##*@}
	_container_ip=${_container_net%/*}
    fi
    __CheckIPAddr $_container_ip
    ln -s /proc/$2/ns/net $namespace_dir/$1
    ip link set $3 netns $1
    ip netns exec $1 ip link set $3 up
    ip netns exec $1 ip addr add $_container_net dev $3
    ip netns exec $1 ip route add default via $_container_gateway dev $3
    #ip netns exec $1 ping -c 2 $_container_gateway > /dev/null 2>&1
    #[[ $? -ne 0 ]] && echo "Warnning: Gateway faraway!"
    rm -f $namespace_dir/$1
    if [[ $tag -eq 0 ]];then
        __ChangeState $short_id attache
    fi
}

function __DetacheContainerNetwork(){
    # Detache container nic
    #-------------------------
    #-----  $1   containser id
    #-------------------------
    __CheckContainer $1
    container_pid=`docker inspect -f '{{ .State.Pid }}' $short_id`
    ln -s /proc/${container_pid}/ns/net $namespace_dir/$1
    __CleanFlows $container_bridge qvr-${short_id}
    ip netns exec $1 ip link del dev veth-$short_id > /dev/null 2>&1
    ovs-vsctl del-port ${container_bridge} tap-${short_id}
    ip link del dev tap-${short_id} > /dev/null 2>&1
    rm -f $namespace_dir/$1
    __ChangeState $short_id detache
}

function InitOvsNet(){
    # Init OpenVswitch Top
    #----------------------------------
    #----- $1  integration_bridge
    #----- $2  docker_bridge
    #----------------------------------
    ovs-vsctl list-br | grep $1 > /dev/null
    [[ $? -eq 0 ]] && \
        echo "Faild: Ovs Init Faild,$1 exsit!" &&\
        exit 1
    ovs-vsctl add-br $1
    ovs-vsctl list_br | grep $2 > /dev/null
    [[ $? -eq 0 ]] && \
        echo "Faild: Ovs Init Faild,$2 exsit!" && \
	exit 1
    ovs-vsctl add-br $2
    ip link del phy-$1 > /dev/null 2>&1
    ip link del int-$2 > /dev/null 2>&1
    ip link add phy-$1 type veth peer name int-$2
    ovs-vsctl add-port $1 int-$2
    ovs-vsctl add-port $2 phy-$1
    echo "Success: OpenVswitch Base Topology Initialed"
    echo "Base Network like this:"
    ovs-vsctl show
    printf "%-20s    %-20s    %-20s    %-40s    %-40s    %-40s    %-20s    %-20s\n" "ID" "IP/MASK" "GATEWAY" "QOS_UUID" "QUEUE0_UUID" "QUEUE1_UUID" "NIC_STATE" "CREATE_AT" >> $statefile
    exit 0
}

function CreateNetwork(){
    # Create peer virtual nic and container's bridge.
    # build container net topology,and config boardcast qos by openvswitch
    #-------------------------
    #-----  $1   container_id
    #-----  $2   container_cidr
    #-------------------------
    container_pid=`docker inspect -f '{{ .State.Pid }}' $1`
    
    ovs-vsctl list-br | grep $container_bridge > /dev/null
    [[ $? -eq 0 ]] && \
        echo "Faild: Bridge $container_bridge exsit!" && \
        exit 1
    ovs-vsctl add-br $container_bridge
    ip link del qvb-$short_id > /dev/null 2>&1
    ip link del tap-$short_id > /dev/null 2>&1
    ip link add qvb-$short_id type veth peer name qvr-$short_id
    ip link add tap-$short_id type veth peer name veth-$short_id
    ovs-vsctl add-port $integration_bridge qvb-$short_id
    ovs-vsctl add-port $container_bridge qvr-$short_id
    ovs-vsctl add-port $container_bridge tap-$short_id
    ip link set qvb-$short_id up
    ip link set qvr-$short_id up
    ip link set tap-$short_id up
    __FlowsTableQosBoardCast qbr-$short_id tap-$short_id qvr-$short_id
    __AttacheContainerNetwork $1 $container_pid veth-$short_id $2
    __AddState ${container_id:0:18} $container_net $container_gateway `__GetOvsQosUuid qos qvr-$short_id` `__GetOvsQosUuid q0 qvr-$short_id` `__GetOvsQosUuid q1 qvr-$short_id` "attache"
}

function DeleteNetwork(){
    # Delete Container Network
    #-------------------------
    #-----  $1   container_id
    #-------------------------
    state=`__GetState $1 state`
    [[ $state == 'attache' ]] && \
        __DetacheContainerNetwork $short_id
    ovs-vsctl del-port $integration_bridge qvb-$short_id
    ovs-vsctl del-port $container_bridge qvr-$short_id
    ovs-vsctl del-br $container_bridge
    ip link del qvb-$short_id > /dev/null 2>&1
    ip link del qvr-$short_id > /dev/null 2>&1
    ovs-vsctl list-br | grep $container_bridge > /dev/null
    [[ $? -eq 0 ]] && \
        echo "Faild: Delete Bridge $container_bridge faild!" && \
        exit 1
    __DeleteState $short_id
}

function AttacheNic(){
    #-------------------------
    #-----  $1   container_id
    #-------------------------
    container_pid=`docker inspect -f '{{ .State.Pid }}' $1`
    [[ `__GetState $short_id state` == "attache" ]] && \
        echo "Faild: Contiander $short_id is attaching!" &&\
        exit 1
    ovs-vsctl list-br | grep $container_bridge > /dev/null
    [[ $? -ne 0 ]] && \
	echo "Faild: Bridge $container_bridge not exsit!" && \
	exit 1
    ovs-vsctl list-ports $container_bridge | grep tap-$short_id > /dev/null
    [[ $? -eq 0 ]] && \
	echo "Warnning: Port tap-$short_id exsit!" && \
    ln -s /proc/${container_pid}/ns/net $namespace_dir/$1
    ip link del dev tap-$short_id  > /dev/null 2>&1
    ip netns exec $1 ip link del dev veth1-$short_id  > /dev/null 2>&1
    ip link add tap-$short_id type veth peer name veth-$short_id
    ovs-vsctl add-port qbr-$short_id tap-$short_id
    ip link set tap-$short_id up
    __FlowsTableQosBoardCast qbr-$short_id tap-$short_id qvr-$short_id
    __AttacheContainerNetwork $short_id $container_pid veth-$short_id $2
}

function DetacheNic(){
    #-------------------------
    #-----  $1   container_id
    #-------------------------
    ovs-vsctl list-br | grep $container_bridge > /dev/null
    [[ $? -ne 0 ]] && \
	echo "Faild: Bridge $container_bridge not exsit!" && \
	exit 1
    ovs-vsctl list-ports $container_bridge | grep tap-$short_id > /dev/null
    [[ $? -ne 0 ]] && \
	echo "Warnning: Port tap-$short_id not exsit!" && \
	exit 1
    __DetacheContainerNetwork $short_id

}

case "$1" in
    init)
	InitOvsNet $integration_bridge $docker_bridge
	;;
    create)
        __CheckParam $2
        __CheckParam $3
	CreateNetwork $2 $3
	;;
    delete)
        __CheckParam $2
	DeleteNetwork $2
	;;
    attache)
        __CheckParam $2
	AttacheNic $2 $3
	;;
    detache)
	DetacheNic $short_id
	;;
    *)
	__Usage
esac
