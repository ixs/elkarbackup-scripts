#!/bin/bash

#
# Name: backup-mysql.sh
# Description: This script backups all your local MySQL databases in individual files
#              It will copy to Elkarbackup only the modified databases.
# Use:  JOB level -> Pre-Script
#       Will only work with Debian/Ubuntu MySQL servers (MYSQLCNF=/etc/mysql/debian.cnf)
#       In other distributions, you have to create "/root/.my.cnf" file (chmod 400) and change MYSQLCNF path
#

set -eu

#ELKARBACKUP_URL = user@serverip:/path
URL=`echo $ELKARBACKUP_URL | cut -d ":" -f1`    # user@serverip
USER="${URL%@*}"                                # user
HOST="${URL#*@}"                                # host
DIR=`echo $ELKARBACKUP_URL | cut -d ":" -f2`    # path
COMPRESS=yes

if [ -f /var/lib/elkarbackup/.ssh/id_rsa ]; then
	SSH_KEY_PATH=/var/lib/elkarbackup/.ssh
elif [ -f /app/.ssh/id_rsa ]; then
	SSH_KEY_PATH=/app/.ssh
else
	echo "Couldn't find SSH key."
	exit 1
fi

SSHPARAMS="-i $SSH_KEY_PATH/id_rsa -S $SSH_KEY_PATH/control_%C -o StrictHostKeyChecking=no ${ELKARBACKUP_SSH_ARGS:-}"

MYSQL=mysql
MYSQLDUMP=mysqldump

# Start SSH Master connection
ssh -M $SSHPARAMS -N -q -f $USER@$HOST

TMP=$(ssh $SSHPARAMS $USER@$HOST mktemp -d)

REMOTE_HOME=$(ssh $SSHPARAMS $USER@$HOST 'echo ${HOME}')

if [ $(ssh $SSHPARAMS $USER@$HOST [[ -f ${REMOTE_HOME}/.my.cnf ]]; echo $?) -eq 0 ]
then
	MYSQLCNF="${REMOTE_HOME}/.my.cnf"
else
	MYSQLCNF=/etc/mysql/debian.cnf
fi

TEST=`ssh $SSHPARAMS $USER@$HOST "test -f $MYSQLCNF && echo $?"`

if [ ! ${TEST} ]; then
    echo "[ERROR] mysql config file doesn't exist $MYSQLCNF"
    exit 1
fi

if [ "$ELKARBACKUP_LEVEL" != "JOB" ]
then
    echo "Only allowed at job level" >&2
    exit 1
fi

if [ "$ELKARBACKUP_EVENT" == "PRE" ]
then
    # If backup directory doesn't exist, create it
    set +e
    TEST=$(ssh $SSHPARAMS $USER@$HOST "test -d $DIR && echo $?")
    set -e
    if [ ! ${TEST} ]; then
        echo "[INFO] Backup directory $DIR doesn't exist. Creating..."
        ssh $SSHPARAMS $USER@$HOST "mkdir -p $DIR"
    fi

    # If tmp directory doesn't exist, create it
    set +e
    TEST=$(ssh $SSHPARAMS $USER@$HOST "test -d $TMP && echo $?")
    set -e
    if [ ! ${TEST} ]; then
        echo "[INFO] TMP directory $TMP doesn't exist. Creating..."
        ssh $SSHPARAMS $USER@$HOST "mkdir -p $TMP"
    fi

    # Get all databases list
    set +e
    databases=$(ssh $SSHPARAMS $USER@$HOST "$MYSQL --defaults-file=$MYSQLCNF -e \"SHOW DATABASES;\"" | grep -Ev "(Database|information_schema|mysql)")
    RESULT=$?
    set -e
    if [ $RESULT -ne 0 ]; then
        echo "ERROR: $databases"
        exit 1
    else

        for db in $databases; do
            # Dump it!
            ssh $SSHPARAMS $USER@$HOST "$MYSQLDUMP --defaults-file=$MYSQLCNF --force --opt --databases $db --single-transaction --quick --lock-tables=FALSE > \"$TMP/$db.sql\""
            if [ "$COMPRESS" == "yes" ]; then
                EXTENSION=sql.gz
                ssh $SSHPARAMS $USER@$HOST "rm -f $TMP/$db.$EXTENSION || true"
                ssh $SSHPARAMS $USER@$HOST "gzip -9 $TMP/$db.sql"
            else
                EXTENSION=sql
            fi
            # If we already have an old version...
            set +e
            TEST=$(ssh $SSHPARAMS $USER@$HOST "test -f $DIR/$db.$EXTENSION && echo $?")
            set -e
            if [ ${TEST} ]; then
                # Diff
                #echo "making a diff"
                set +e
                TEST=$(ssh $SSHPARAMS $USER@$HOST "diff -q <(zcat $TMP/$db.sql|head -n -1) <(zcat $DIR/$db.$EXTENSION|head -n -1) > /dev/null && echo $?")
                set -e
                #echo "diff result: [$TEST]"
                # If Diff = false, copy tmp dump file
                if [ ! ${TEST} ]; then
                    ssh $SSHPARAMS $USER@$HOST "cp $TMP/$db.$EXTENSION $DIR/$db.$EXTENSION"
                    echo "[$db.$EXTENSION] Changes detected. New dump saved."
                else
                    echo "[$db.$EXTENSION] No changes detected. Nothing to save."
                fi
            else
                echo "[$db.$EXTENSION] First dump created!"
                ssh $SSHPARAMS $USER@$HOST "cp $TMP/$db.$EXTENSION $DIR/$db.$EXTENSION"
            fi
        done
    fi
fi

ssh $SSHPARAMS $USER@$HOST rm -rf ${TMP}

# tell master to quit
ssh $SSHPARAMS -O exit $USER@$HOST

exit 0
