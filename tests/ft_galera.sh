#! /bin/bash
MYNAME=$(basename $0)
MYBASENAME=$(basename $0 .sh)
MYDIR=$(dirname $0)
STDOUT_FILE=ft_errors_stdout
VERBOSE=""
LOG_OPTION="--wait"
CLUSTER_NAME="${MYBASENAME}_$$"
CLUSTER_ID=""
ALL_CREATED_IPS=""

# This is the name of the server that will hold the linux containers.
CONTAINER_SERVER="core1"

# The IP of the node we added first and last. Empty if we did not.
FIRST_ADDED_NODE=""
LAST_ADDED_NODE=""

cd $MYDIR
source include.sh

#
# Prints usage information and exits.
#
function printHelpAndExit()
{
cat << EOF
Usage: $MYNAME [OPTION]... [TESTNAME]
 Test script for s9s to check various error conditions.

 -h, --help       Print this help and exit.
 --verbose        Print more messages.
 --log            Print the logs while waiting for the job to be ended.
 --server=SERVER  The name of the server that will hold the containers.

EOF
    exit 1
}


ARGS=$(\
    getopt -o h \
        -l "help,verbose,log,server:" \
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
            ;;

        --log)
            shift
            LOG_OPTION="--log"
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

if [ -z "$S9S" ]; then
    echo "The s9s program is not installed."
    exit 7
fi

CLUSTER_ID=$($S9S cluster --list --long --batch | awk '{print $1}')

if [ -z $(which pip-container-create) ]; then
    printError "The 'pip-container-create' program is not found."
    printError "Don't know how to create nodes, giving up."
    exit 1
fi

#
# Creates and starts a new 
#
function create_node()
{
    local ip

    ip=$(pip-container-create --server=$CONTAINER_SERVER)
    echo $ip

    sleep 5
}

#
# $1: the name of the cluster
#
function find_cluster_id()
{
    local name="$1"
    local retval
    local nTry=0

    while true; do
        retval=$($S9S cluster --list --long --batch --cluster-name="$name")
        retval=$(echo "$retval" | awk '{print $1}')

        if [ -z "$retval" ]; then
            printVerbose "Cluster '$name' was not found."
            let nTry+=1

            if [ "$nTry" -gt 10 ]; then
                echo 0
                break
            else
                sleep 3
            fi
        else
            printVerbose "Cluster '$name' was found with ID ${retval}."
            echo "$retval"
            break
        fi
    done
}

function grant_user()
{
    $S9S user --create --cmon-user=$USER --generate-key
}

#
#
#
function testPing()
{
    pip-say "Pinging controller."

    #
    # Pinging. 
    #
    $S9S cluster --ping 

    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "Exit code is not 0 while pinging controller."
        pip-say "The controller is off line. Further testing is not possible."
    else
        pip-say "The controller is on line."
    fi
}

#
# This test will allocate a few nodes and install a new cluster.
#
function testCreateCluster()
{
    local nodes
    local nodeName
    local exitCode

    pip-say "The test to create Galera cluster is starting now."
    nodeName=$(create_node)
    nodes+="$nodeName;"
    FIRST_ADDED_NODE=$nodeName
    ALL_CREATED_IPS+=" $nodeName"
    
    nodeName=$(create_node)
    nodes+="$nodeName;"
    ALL_CREATED_IPS+=" $nodeName"
    
    nodeName=$(create_node)
    nodes+="$nodeName"
    ALL_CREATED_IPS+=" $nodeName"
    
    #
    # Creating a Galera cluster.
    #
    $S9S cluster \
        --create \
        --cluster-type=galera \
        --nodes="$nodes" \
        --vendor=percona \
        --cluster-name="$CLUSTER_NAME" \
        --provider-version=5.6 \
        $LOG_OPTION

    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "Exit code is not 0 while creating cluster."
    fi

    CLUSTER_ID=$(find_cluster_id $CLUSTER_NAME)
    if [ "$CLUSTER_ID" -gt 0 ]; then
        printVerbose "Cluster ID is $CLUSTER_ID"
    else
        failure "Cluster ID '$CLUSTER_ID' is invalid"
    fi
}

#
# Creating a new account on the cluster.
#
function testCreateAccount()
{
    pip-say "Testing account creation."

    #
    # This command will create a new account on the cluster.
    #
    $S9S cluster \
        --create-account \
        --cluster-id=$CLUSTER_ID \
        --account="john_doe:password@1.2.3.4" \
        --with-database
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "Exit code is not 0 while creating an account."
    fi
}

#
# This test will add one new node to the cluster.
#
function testAddNode()
{
    local nodes
    local exitCode

    pip-say "The test to add node is starting now."
    printVerbose "Creating Node..."
    LAST_ADDED_NODE=$(create_node)
    nodes+="$LAST_ADDED_NODE"
    ALL_CREATED_IPS+=" $LAST_ADDED_NODE"

    #
    # Adding a node to the cluster.
    #
    $S9S cluster \
        --add-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="$nodes" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This test will add a proxy sql node.
#
function testAddProxySql()
{
    local node
    local nodes
    local exitCode

    pip-say "The test to add ProxySQL node is starting now."
    printVerbose "Creating Node..."
    nodeName=$(create_node)
    nodes+="proxySql://$nodeName"
    ALL_CREATED_IPS+=" $nodeName"

    #
    # Adding a node to the cluster.
    #
    $S9S cluster \
        --add-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="$nodes" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This test will first add a HaProxy node, then remove from the cluster. The
# idea behind this test is that the remove-node call should be identify the node
# using the IP address if there are multiple nodes with the same IP (one galera
# node and one haproxy node on the same host this time).
#
function testAddRemoveHaProxy()
{
    local node
    local nodes
    local exitCode
    
    pip-say "The test to add and remove HaProxy node is starting now."
    node=$(\
        $S9S node --list --long --batch | \
        grep ^g | \
        tail -n1 | \
        awk '{print $4}')

    #
    # Adding a node to the cluster.
    #
    $S9S cluster \
        --add-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="haProxy://$node" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
   
    $S9S node --list --long --color=always

    #
    # Remove a node to the cluster.
    #
    $S9S cluster \
        --remove-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="$node:9600" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
    
    $S9S node --list --long --color=always
}

#
# This test will add a HaProxy node.
#
function testAddHaProxy()
{
    local node
    local nodes
    local exitCode
    
    pip-say "The test to add HaProxy node is starting now."
    printVerbose "Creating Node..."
    node=$(create_node)
    nodes+="haProxy://$node"
    ALL_CREATED_IPS+=" $node"

    #
    # Adding a node to the cluster.
    #
    $S9S cluster \
        --add-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="$nodes" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This test will remove the last added node.
#
function testRemoveNode()
{
    if [ -z "$LAST_ADDED_NODE" ]; then
        printVerbose "Skipping test."
    fi
    
    pip-say "The test to remove node is starting now."
    
    #
    # Removing the last added node.
    #
    $S9S cluster \
        --remove-node \
        --cluster-id=$CLUSTER_ID \
        --nodes="$LAST_ADDED_NODE" \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This will perform a rolling restart on the cluster
#
function testRollingRestart()
{
    local exitCode
    
    pip-say "The test of rolling restart is starting now."

    #
    # Calling for a rolling restart.
    #
    $S9S cluster \
        --rolling-restart \
        --cluster-id=$CLUSTER_ID \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This will create a backup.
#
function testCreateBackup()
{
    local exitCode
    
    pip-say "The test to create a backup is starting."

    #
    # Calling for a rolling restart.
    #
    $S9S backup \
        --create \
        --cluster-id=$CLUSTER_ID \
        --nodes=$FIRST_ADDED_NODE \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This will restore a backup. 
#
function testRestoreBackup()
{
    local exitCode
    local backupId

    pip-say "The test to restore a backup is starting."
    backupId=$(\
        $S9S backup --list --long --batch --cluster-id=$CLUSTER_ID |\
        awk '{print $1}')

    #
    # Creating a backup. 
    #
    $S9S backup \
        --restore \
        --cluster-id=$CLUSTER_ID \
        --backup-id=$backupId \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# This will remove a backup. 
#
function testRemoveBackup()
{
    local exitCode
    local backupId

    pip-say "The test to remove a backup is starting."
    backupId=$(\
        $S9S backup --list --long --batch --cluster-id=$CLUSTER_ID |\
        awk '{print $1}')

    #
    # Calling for a rolling restart.
    #
    $S9S backup \
        --delete \
        --backup-id=$backupId \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# Stopping the cluster.
#
function testStop()
{
    local exitCode

    pip-say "The test to stop the cluster is starting now."

    #
    # Stopping the cluster.
    #
    $S9S cluster \
        --stop \
        --cluster-id=$CLUSTER_ID \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

#
# Starting the cluster.
#
function testStart()
{
    local exitCode

    pip-say "The test to start the cluster is starting now."

    #
    # Starting the cluster.
    #
    $S9S cluster \
        --start \
        --cluster-id=$CLUSTER_ID \
        $LOG_OPTION
    
    exitCode=$?
    printVerbose "exitCode = $exitCode"
    if [ "$exitCode" -ne 0 ]; then
        failure "The exit code is ${exitCode}"
    fi
}

function testDestroyNodes()
{
    pip-say "The test is now destroying the nodes."
    pip-container-destroy --server=$CONTAINER_SERVER $ALL_CREATED_IPS
}

#
# Running the requested tests.
#
startTests
grant_user

if [ "$1" ]; then
    for testName in $*; do
        runFunctionalTest "$testName"
    done
else
    runFunctionalTest testPing
    runFunctionalTest testCreateCluster
    runFunctionalTest testCreateAccount
    runFunctionalTest testAddNode
    runFunctionalTest testAddProxySql
    runFunctionalTest testAddRemoveHaProxy
    runFunctionalTest testAddHaProxy
    runFunctionalTest testRemoveNode
    runFunctionalTest testRollingRestart
    runFunctionalTest testCreateBackup
    runFunctionalTest testRestoreBackup
    runFunctionalTest testRemoveBackup
    runFunctionalTest testStop
    runFunctionalTest testStart
    runFunctionalTest testDestroyNodes
fi

endTests


