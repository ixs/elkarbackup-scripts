#!/bin/bash
# Report Backup Status to bawue.net Nagios via NRDP

#### CONFIG BEGIN ####

# nrdp endpoint configuration
nrdp_url="https://nagios.example.net/nrdp/"
nrdp_token="secret"

# Nagios host entry and service entry template
host_name="backup.example.net"
service_name="ElkarBackup ${ELKARBACKUP_CLIENT_NAME}/${ELKARBACKUP_JOB_NAME}"

# We're reporting our local diskspace to nagios. Set thresholds here.
storage_warn=95
storage_crit=98
#### CONFIG END ####

#(
#set -x

# Import the environment variables normally set for the docker container
# For some reason, these are missing for this script
load_docker_env() {
	source /envars.sh
	while IFS= read -r line; do
		if [[ $line =~ ^(EB|SYMFONY)[A-Z0-9_]*= ]]; then
			export "$line"
		fi
	done < <(tr '\0' '\n' < /proc/1/environ)
}
load_docker_env

set -euo pipefail

# Testing Data only
if [ "${1:-}" == "--test" ]; then
	ELKARBACKUP_CLIENT_NAME="Bawue mailin01"
	ELKARBACKUP_CLIENT_TOTAL_SIZE="979219892"
	ELKARBACKUP_EVENT="POST"
	ELKARBACKUP_ID="4"
	ELKARBACKUP_JOB_ENDTIME="1762945429"
	ELKARBACKUP_JOB_NAME="Spool files"
	ELKARBACKUP_JOB_RUN_SIZE="0"
	ELKARBACKUP_JOB_STARTTIME="1762945291"
	ELKARBACKUP_JOB_TOTAL_SIZE="978361436"
	ELKARBACKUP_LEVEL="JOB"
	ELKARBACKUP_OWNER_EMAIL="root@localhost"
	ELKARBACKUP_PATH="/app/backups/0002/0004"
	ELKARBACKUP_RECIPIENT_LIST=""
	ELKARBACKUP_SSH_ARGS="-T -o Compression=no -x"
	ELKARBACKUP_STATUS="1536"
	ELKARBACKUP_URL="root@mailin01.mx.bawue.net:/var/spool/imap/"
fi

if [ -z "${ELKARBACKUP_CLIENT_NAME:-}" ]; then
	echo "This script has to be run as a POST Job Script for ElkarBackup."
	echo "A --test mode is available."
	exit 1
fi

kb_to_human() {
	local kb=$1

	# Check if input is numeric
	if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
		echo "Error: Input must be a numeric value."
		return 1
	fi

	# Calculate in terabytes, gigabytes, or megabytes
	if [ "$kb" -ge $((1024**3)) ]; then
		echo "$((kb / (1024**3))).$(printf "%02d" $(( (kb % (1024**3)) * 100 / (1024**3) )))TB"
	elif [ "$kb" -ge $((1024**2)) ]; then
		echo "$((kb / (1024**2))).$(printf "%02d" $(( (kb % (1024**2)) * 100 / (1024**2) )))GB"
	else
		echo "$((kb / 1024)).$(printf "%02d" $(( (kb % 1024) * 100 / 1024 )))MB"
	fi
}

# Convert a unix timestamp from elkarbackup to a MySQL Date String.
convert_date() {
	local timestamp=${1}
	date +"%Y-%m-%d %H:%M:%S" --date="@$timestamp"
}

# Fetch the job logs from MySQL
get_log_entries() {
	local query="
		SELECT message
		FROM LogRecord
		WHERE link LIKE '/client/%/job/${ELKARBACKUP_ID}'
			AND dateTime BETWEEN '$(convert_date ${ELKARBACKUP_JOB_STARTTIME})' AND '$(convert_date ${ELKARBACKUP_JOB_ENDTIME})'
			AND source = 'RunJobCommand'
			AND level = 400
		ORDER BY dateTime DESC;
	"
	mysql -h $SYMFONY__DATABASE__HOST -u $SYMFONY__DATABASE__USER -p$SYMFONY__DATABASE__PASSWORD -N -B -e "$query" $SYMFONY__DATABASE__NAME
}

if [ "$ELKARBACKUP_STATUS" -eq 0 ]; then
    service_status=0
    service_status_text="OK"
elif [ "$ELKARBACKUP_STATUS" -eq -1 ]; then
    service_status=2
    service_status_text="CRITICAL"
    service_error_text="pre scripts failed"
elif [ "$ELKARBACKUP_STATUS" -eq -2 ]; then
    service_status=2
    service_status_text="CRITICAL"
    service_error_text="rsnapshot skipped"
elif get_log_entries | grep -q 'rsync warning: some files vanished before they could be transferred'; then
    service_status=1
    service_status_text="WARNING"
    service_error_text="file vanished during rsync ($ELKARBACKUP_STATUS)"
else
    service_status=2
    service_status_text="CRITICAL"
    service_error_text="unknown ($ELKARBACKUP_STATUS)"
fi

job_duration=$((ELKARBACKUP_JOB_ENDTIME - ELKARBACKUP_JOB_STARTTIME))
job_size=$(echo "${ELKARBACKUP_JOB_RUN_SIZE}" | tr -d '[a-z], ')
job_storage_size="${ELKARBACKUP_JOB_TOTAL_SIZE}"

hours=$((job_duration / 3600))
minutes=$(((job_duration % 3600) / 60 ))
seconds=$((job_duration % 60))

if [ $hours -gt 0 ]; then
	elapsed_text="${hours}h ${minutes}m"
elif [ $minutes -gt 0 ]; then
	elapsed_text="${minutes}m ${seconds}s"
else
	elapsed_text="${seconds}s"
fi

if [ "$service_status" -eq 0 ]; then
    service_status=0
    service_status_text="OK"
    service_output="${service_status_text}: Backed up $(kb_to_human "$job_storage_size"), transferred $(kb_to_human "$((job_size / 1000))") in ${elapsed_text} for ${ELKARBACKUP_URL}"
elif [ "$service_status" -eq 1 ]; then
    service_status=1
    service_status_text="WARNING"
    service_output="${service_status_text}: Backed up $(kb_to_human "$job_storage_size"), transferred $(kb_to_human "$((job_size / 1000))") with warning ${service_error_text} in ${elapsed_text} for ${ELKARBACKUP_URL}"
elif [ "$service_status" -eq 2 ]; then
    service_status=2
    service_status_text="CRITICAL"
    service_output="${service_status_text}: Error during backup, ${service_error_text} in ${elapsed_text} for ${ELKARBACKUP_URL}"
else
    service_status=3
    service_status_text="UNKNOWN"
    service_output="Unknown status during backup: ${ELKARBACKUP_STATUS}"
fi


# Get diskspace variables
read MOUNT SIZE USED AVAIL PCENT <<EOF
$(df -l -BM --output=target,size,used,avail,pcent "${ELKARBACKUP_PATH}" | tail -1)
EOF

# Strip units of measure
USE_PCT=$(echo "$PCENT" | tr -d '%')
USED=$(echo "$USED" | tr -d 'M')
AVAIL=$(echo "$AVAIL" | tr -d 'M')
SIZE=$(echo "$SIZE" | tr -d 'M')

# Determine Nagios state
if [ "$USE_PCT" -ge "$storage_crit" ]; then
    storage_status=2
    storage_text="DISK CRITICAL"
elif [ "$USE_PCT" -ge "$storage_warn" ]; then
    storage_status=1
    storage_text="DISK WARNING"
else
    storage_status=0
    storage_text="DISK OK"
fi

# Human-readable sizes for output
USED_HR=$(numfmt --to=iec --from=auto "$USED"M)
AVAIL_HR=$(numfmt --to=iec --from=auto "$AVAIL"M)

storage_output="${storage_text} - free space: ${MOUNT} ${AVAIL_HR} (${PCENT})"
storage_perfdata="${MOUNT}=${AVAIL}MiB;$(($SIZE / 100 * $storage_warn));$(($SIZE / 100 * $storage_crit));0;${SIZE}"


xml="<?xml version='1.0'?>
<checkresults>
    <checkresult type='host'>
        <hostname>${host_name}</hostname>
        <state>0</state>
        <output>ElkarBackup NRDP Status</output>
    </checkresult>
    <checkresult type='service'>
        <hostname>${host_name}</hostname>
        <servicename>Free disk space</servicename>
        <state>${storage_status}</state>
        <output>${storage_output} | ${storage_perfdata}</output>
    </checkresult>
    <checkresult type='service'>
        <hostname>${host_name}</hostname>
        <servicename>${service_name}</servicename>
        <state>${service_status}</state>
        <output>${service_output} | job_duration=${job_duration}s;;;; job_size=${job_size}B;;;; job_total_size=${job_storage_size}KB;;;;</output>
    </checkresult>
</checkresults>"

if [ "${1:-}" == "--test" ]; then
	echo "${xml}"
	exit
fi

output=$(curl -L -s -f -d "token=${nrdp_token}&cmd=submitcheck&xml=${xml}" "${nrdp_url}")
if [ "$?" -ne 0 ]; then
	echo "Problem talking to NDRP Server at ${nrdp_url}"
	exit 1
fi

err=$(echo "$output" | grep status | cut -d '>' -f 2 | cut -d '<' -f 1)
message=$(echo "$output" | grep message | cut -d '>' -f 2 | cut -d '<' -f 1)
out=$(echo "$output" | grep output | cut -d '>' -f 2 | cut -d '<' -f 1)

echo "Reported: ${service_name} as ${service_status_text} on ${host_name}"
echo "${message}: ${out}"
exit "${err}"

#) > /tmp/nagios.log 2>&1
