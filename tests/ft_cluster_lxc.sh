#! /bin/bash
MYNAME=$(basename $0)
MYBASENAME=$(basename $0 .sh)
MYDIR=$(dirname $0)
VERBOSE=""
VERSION="0.0.1"
LOG_OPTION="--log"

CONTAINER_SERVER=""
CONTAINER_IP=""
CLUSTER_NAME="${MYBASENAME}_$$"

cd $MYDIR
source ./include.sh
source ./shared_test_cases.sh
source ./include_lxc.sh
source ./include_user.sh

#
# Prints usage information and exits.
#
function printHelpAndExit()
{
cat << EOF
Usage: 
  $MYNAME [OPTION]... [TESTNAME]
 
  $MYNAME - Test script for s9s to check cluster creation on containers.

 -h, --help       Print this help and exit.
 --verbose        Print more messages.
 --print-json     Print the JSON messages sent and received.
 --log            Print the logs while waiting for the job to be ended.
 --print-commands Do not print unit test info, print the executed commands.
 --install        Just install the server and the cluster and exit.
 --reset-config   Remove and re-generate the ~/.s9s directory.
 --server=SERVER  Use the given server to create containers.

SUPPORTED TESTS:
  o createUserSisko    Creates a user to work with.
  o testCreateOutsider Creates an outsider user for access right checks.
  o registerServer     Registers a new container server. No software installed.
  o createContainer    Creates a container.
  o createCluster      Creates a cluster.
  o removeCluster      Drops the cluster, removes containers.

EOF
    exit 1
}

ARGS=$(\
    getopt -o h \
        -l "help,verbose,print-json,log,print-commands,install,reset-config,\
server:" \
        -- "$@")

if [ $? -ne 0 ]; then
    exit 6
fi

eval set -- "$ARGS"
while true; do
    case "$1" in
        -h|--help)
            shift
            printHelpAndExit
            ;;

        --verbose)
            shift
            VERBOSE="true"
            OPTION_VERBOSE="--verbose"
            ;;

        --log)
            shift
            LOG_OPTION="--log"
            ;;

        --print-json)
            shift
            OPTION_PRINT_JSON="--print-json"
            ;;

        --print-commands)
            shift
            DONT_PRINT_TEST_MESSAGES="true"
            PRINT_COMMANDS="true"
            ;;

        --install)
            shift
            OPTION_INSTALL="--install"
            ;;

        --reset-config)
            shift
            OPTION_RESET_CONFIG="true"
            ;;

        --server)
            shift
            CONTAINER_SERVER="$1"
            shift
            ;;

        --)
            shift
            break
            ;;
    esac
done

if [ -z "$OPTION_RESET_CONFIG" ]; then
    printError "This script must remove the s9s config files."
    printError "Make a copy of ~/.s9s and pass the --reset-config option."
    exit 6
fi

if [ -z "$CONTAINER_SERVER" ]; then
    printError "No container server specified."
    printError "Use the --server command line option to set the server."
    exit 6
fi

#
# Creates then destroys a cluster on lxc.
#
function createContainer()
{
    local config_dir="$HOME/.s9s"
    local container_name="${MYBASENAME}_01_$$"
    local template
    local owner

    print_title "Creating Container"
    begin_verbatim

    #
    # Creating a container.
    #
    mys9s container \
        --create \
        --cloud=lxc \
        --os-user=sisko \
        --template="ubuntu" \
        --os-key-file="$config_dir/sisko.key" \
        $LOG_OPTION \
        "$container_name"
    
    check_exit_code $?
    
    mys9s container --list --long

    #
    # Checking the ip and the owner.
    #
    CONTAINER_IP=$(get_container_ip "$container_name")
    
    if [ -z "$CONTAINER_IP" -o "$CONTAINER_IP" == "-" ]; then
        failure "The container was not created or got no IP."
        s9s container --list --long
    fi
    
    end_verbatim

    #
    # Checking if the owner can actually log in through ssh.
    #
    print_title "Checking SSH Access for '$USER'"
    begin_verbatim

    is_server_running_ssh "$CONTAINER_IP" "$USER"

    if [ $? -ne 0 ]; then
        failure "User $USER can not log in to $CONTAINER_IP"
    else
        success "SSH access granted for user '$USER' on $CONTAINER_IP."
    fi
    
    end_verbatim

    #
    # Checking that sisko can log in.
    #
    print_title "Checking SSH Access for 'sisko'"
    begin_verbatim

    ls -lha "$config_dir/sisko.key"

    is_server_running_ssh \
        --current-user "$CONTAINER_IP" "sisko" "$config_dir/sisko.key"

    if [ $? -ne 0 ]; then
        failure "User 'sisko' can not log in to $CONTAINER_IP"
    else
        echo "SSH access granted for user 'sisko' on $CONTAINER_IP."
    fi
    
    end_verbatim

    #
    # Deleting the container we just created.
    #
    print_title "Deleting Container"
    begin_verbatim

    mys9s container --delete $LOG_OPTION "$container_name"
    check_exit_code $?

    end_verbatim
}

function createCluster()
{
    local config_dir="$HOME/.s9s"
    local container_name1="${MYBASENAME}_11_$$"
    local container_name2="${MYBASENAME}_12_$$"

    #
    # Creating a Cluster.
    #
    print_title "Creating a Cluster on LXC"
    cat <<EOF
  This test will create a cluster on two new containers that are created on the
  fly by the cluster creation job.

EOF
    
    begin_verbatim

    mys9s cluster \
        --create \
        --cluster-name="$CLUSTER_NAME" \
        --template="ubuntu" \
        --cluster-type=galera \
        --provider-version="5.7" \
        --vendor=percona \
        --cloud=lxc \
        --nodes="$container_name1;$container_name2" \
        --containers="$container_name1;$container_name2" \
        --os-user=sisko \
        --os-key-file="$config_dir/sisko.key" \
        $LOG_OPTION 

    check_exit_code $?
    end_verbatim

    check_container_ids --galera-nodes

    #
    #
    #
    print_title "Waiting and Printing Lists"
    begin_verbatim
    mysleep 10
    mys9s cluster   --list --long
    mys9s node      --list --long
    mys9s container --list --long
    mys9s node      --stat
    end_verbatim
}

function testAlarms()
{
    local container_name1="${MYBASENAME}_11_$$"
    local clusterState
    local line

    print_title "Checking Alarms"
    cat <<EOF
  Testing alarms. This test will first stop a container that holds a database
  node. This will trigger some alarms that should be visible by the owner of
  the cluste, but should not be visible by an outsider. 
  
  At the end the container is restarted, so the cluster recovery should commence
  and the alarms should disappear.

EOF
    
    begin_verbatim
    mys9s container --stop --wait "$container_name1"
    check_exit_code $?

    mysleep 5
    mys9s container --list --long
    mys9s node --list --long
    mys9s cluster --list --long

    mysleep 40
    mys9s job --list
    mys9s cluster --list --long
    clusterState=$(cluster_state $CLUSTER_ID)
    if [ "$clusterState" == "STARTED" ]; then
        failure "Cluster state should not be '$clusterState'."
        end_verbatim
        return 1
    fi


    # Check active alarms with the owner using the cluster ID.
    mys9s alarm --list --long --cluster-id=1 
    check_exit_code $?
    if s9s alarm --list --long --cluster-id=1 --batch | grep CRITICAL; then
        success "  o Owner can see the alarm about disconnected nodes, ok."
    else
        failure "Owner can't see the alarm?"
    fi

    # Active alarms, owner, no cluster ID.
    mys9s alarm --list --long 
    check_exit_code $?
    if s9s alarm --list --long --batch | grep CRITICAL; then
        success "  o Owner can see the alarm about disconnected nodes, ok."
    else
        failure "Owner can't see the alarm?"
    fi

    # Active alarms, outsider, cluster ID is provided.
    mys9s alarm --list --long --cluster-id=1 --cmon-user=grumio --password=p
    if [ $? -eq 0 ]; then
        failure "Outsiders should get false return value."
    else
        success "  o Outsiders get false return value, ok."
    fi
   
    # Checking stats.
    mys9s alarm --stat --cluster-id=1
    if [ $? -eq 0 ]; then
        success "  o Owner gets a true return value on stats, ok."
    else
        failure "Owner got a false return value on stats."
    fi

    mys9s alarm --stat --cluster-id=1 --cmon-user="grumio" --password="p"
    if [ $? -eq 0 ]; then
        failure "Outsiders should get false return value on stats."
    else
        success "  o Outsiders get false return value on stats, ok."
    fi

    #
    # Starting the node, waiting for a while, alarms should disappear.
    #
    s9s container --start --wait "$container_name1"
    check_exit_code $?
    mysleep 120

    # No alarms, owner, cluster ID provided.
    mys9s alarm --list --long --cluster-id=1 
    check_exit_code $?
    if s9s alarm --list --long --cluster-id=1 --batch | grep -q CRITICAL; then
        failure "Alarm should have disappeared already."
        mys9s job --list
    else
        success "  o Alarm disappeared, ok."
    fi


    mys9s alarm --list --long 
    check_exit_code $?
    if s9s alarm --list --long --cluster-id=1 --batch | grep -q CRITICAL; then
        failure "Alarm should have disappeared already."
    else
        success "  o Alarm disappeared, ok."
    fi

    end_verbatim
}

function removeCluster()
{
    local container_name1="${MYBASENAME}_11_$$"
    local container_name2="${MYBASENAME}_12_$$"

    #
    # Dropping and deleting.
    #
    print_title "Dropping Cluster"
    begin_verbatim

    CLUSTER_ID=$(find_cluster_id $CLUSTER_NAME)

    mys9s cluster \
        --drop \
        --cluster-id="$CLUSTER_ID" \
        $LOG_OPTION
    
    #check_exit_code $?

    #
    # Deleting containers.
    #
    print_title "Deleting Containers"
   
    mys9s container --list --long

    mys9s container --delete $LOG_OPTION "$container_name1"
    check_exit_code $?
    
    mys9s container --delete $LOG_OPTION "$container_name2"
    check_exit_code $?

    end_verbatim
}

#
# Running the requested tests.
#
startTests
reset_config
grant_user

#s9s event --list --with-event-job &
#EVENT_HANDLER_PID=$!

if [ "$OPTION_INSTALL" ]; then
    runFunctionalTest createUserSisko
    runFunctionalTest testCreateOutsider
    runFunctionalTest registerServer
    runFunctionalTest createCluster
    runFunctionalTest testAlarms
elif [ "$1" ]; then
    for testName in $*; do
        runFunctionalTest "$testName"
    done
else
    runFunctionalTest createUserSisko
    runFunctionalTest testCreateOutsider
    runFunctionalTest registerServer
    runFunctionalTest createContainer
    runFunctionalTest createCluster
    runFunctionalTest testAlarms
    runFunctionalTest removeCluster
fi

#kill $EVENT_HANDLER_PID
endTests
