## report-nrdp

Report to Nagios via NRDRP the backup job results

[Download URL](https://github.com/ixs/elkarbackup-scripts/raw/master/report-nrdp/report-nrdp.sh)

### Configuration

Steps for setting up:

 - Ensure there is a reachable nrdp endpoint available. Configure this as `nrdp_url` at the top of the script.
 - Configure the nrdp token to use at `nrdp_token`.
 - Configure the hostname to use for nagios passive check results. This must match your nagios configuration.
 - Same for the Service name. This also must match.

### Data submitted.

This script submits the following data:

 - Hostresult is being sent OK
 - `Free disk space` check is reporting on the backup location disk space
 - Each job is reporting on success/warning/fail.

### Notes

The script works around the "warning, files went away" error by checking for this and setting the status from
FAIL to WARN.

### Testing

The script has a `--test` parameter that will display the generated XML instead of posting it.
