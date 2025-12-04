#! /bin/bash
set -e

#############################################################################
## SSH functions
#############################################################################

#ELKARBACKUP_URL = user@serverip:/path
URL=`echo $ELKARBACKUP_URL | cut -d ":" -f1`    # user@serverip
USER="${URL%@*}"                                # user
HOST="${URL#*@}"                                # host

if [ -f /var/lib/elkarbackup/.ssh/id_rsa ]; then
        SSH_KEY_PATH=/var/lib/elkarbackup/.ssh
elif [ -f /app/.ssh/id_rsa ]; then
        SSH_KEY_PATH=/app/.ssh
else
        echo "Couldn't find SSH key."
        exit 1
fi

SSHPARAMS="-i $SSH_KEY_PATH/id_rsa -S $SSH_KEY_PATH/control_%C -o StrictHostKeyChecking=no ${ELKARBACKUP_SSH_ARGS:-}"


# Run a commmand via SSH and return the exit code
function ssh_exec {
    cmd="$1"
    output="$(ssh $SSHPARAMS $USER@$HOST $cmd && echo $?)"
    return $output
}

# Run a command via SSH and return the output
function ssh_exec_output {
    cmd="$1"
    output="$(ssh $SSHPARAMS $USER@$HOST $cmd)"
    echo "$output"
}

############################################################################

# Requirements
GETFACL="$(ssh_exec_output "which getfacl")"

# Settings
DIR=`echo $ELKARBACKUP_URL | cut -d ":" -f2`
ACLFILE="$DIR/permissions.facl"

# Delete host local acl file after backup job
delete_local_aclfile=true

if [ -z "$GETFACL" ]
then
    echo "Cannot find ACL utilities binary 'getfacl'"
    exit 1
fi

if [ "$ELKARBACKUP_LEVEL" == "JOB" ]
then
    if [ "$ELKARBACKUP_EVENT" == "PRE" ]
    then
        cmd="$GETFACL -R $DIR > $ACLFILE"
        r=$(ssh_exec "$cmd" && echo $?)

        if [ $r -ne 0 ]
        then
            echo "ERROR: Permissions backup finished with errors"
            exit 1
        fi
    elif [ "$ELKARBACKUP_EVENT" == "POST" ]
    then
        if [ "$delete_local_aclfile" = true ]
        then
            cmd="rm $ACLFILE"
            r=$(ssh_exec "$cmd" && echo $?)

            if [ $r -ne 0 ]
            then
                echo "ERROR: Error deleting local permissions file $ACLFILE"
                exit 1
            fi
        fi
    fi
fi
