#!/bin/bash
# rclone_jobber.sh version 1.5.6
# Tutorial, backup-job examples, and source code at https://github.com/wolfv6/rclone_jobber
# Logging options are headed by "# set log".  Details are in the tutorial's "Logging options" section.

################################### license ##################################
# rclone_jobber.sh is a script that calls rclone sync to perform a backup.
# Written in 2018 by Wolfram Volpi, contact at https://github.com/wolfv6/rclone_jobber/issues
# To the extent possible under law, the author(s) have dedicated all copyright and related and
# neighboring rights to this software to the public domain worldwide.
# This software is distributed without any warranty.
# You should have received a copy of the CC0 Public Domain Dedication along with this software.
# If not, see http://creativecommons.org/publicdomain/zero/1.0/.
# rclone_jobber is not affiliated with rclone.

################################# parameters #################################
source="$1"            # the directory to back up (without a trailing slash)
dest="$2"              # the directory to back up to (without a trailing slash or "last_snapshot") destination=$dest/last_snapshot
move_old_files_to="$3" # move_old_files_to is one of:
                       # "dated_directory" - move old files to a dated directory (an incremental backup)
                       # "dated_files"     - move old files to old_files directory, and append move date to file names (an incremental backup)
                       # ""                - old files are overwritten or deleted (a plain one-way sync backup)
options="$4"           # rclone options like "--filter-from=filter_patterns --checksum --log-level="INFO" --dry-run"
                       # do not put these in options: --backup-dir, --suffix, --log-file
job_name="$5"          # job_name="$(basename $0)"
monitoring_url="$6"    # cron monitoring service URL to send email if cron failure or other error prevented back up

################################ set variables ###############################
# $new is the directory name of the current snapshot
# $timestamp is time that old file was moved out of new (not time that file was copied from source)
new="last_snapshot"
timestamp="$(date +%F_%T)"
#timestamp="$(date +%F_%H%M%S)"  # time w/o colons if thumb drive is FAT format, which does not allow colons in file name

################################ logging options #############################
# set to false if you want to turn off logging
log=true
if [ "$log" = true ]; then
	# set log_file path
	path="$(realpath "$0")"                 # this will place log in the same directory as this script
	log_file="${path%.*}.log"
	#log_file="/var/log/rclone_jobber.log" 

	log_option="--log-file=$log_file"       # log to log_file
	#log_option="--syslog"                  # log to systemd journal

	send_to_log()
	{
	    msg="$1"
 	   # set log - send msg to log
 	   echo "$msg" >> "$log_file"                             # log msg to log_file
 	   #printf "$msg" | systemd-cat -t RCLONE_JOBBER -p info   # log msg to systemd journal
	}
else
	log_option=""
fi

############################### healthchecks.io ###############################
if [[ "$monitoring_url" = *"hc.io"* ]]; then
	hc=true
	log_to_hc=true		# set this to false if you want to store logs locally or not send to healthchecks
	# log_option="-q"	# no logs including errors are sent to healthchecks
	log_option="" 		# set to -v to send INFO logs, or -vv to send INFO and DEBUG logs
else
	hc=false
	log_to_hc=false
fi

# print message to echo, log, and popup
print_message()
{
    urgency="$1"
    msg="$2"
    message="${urgency}: $job_name $msg"

    echo "$message"
    send_to_log "$(date +%F_%T) $message"
    warning_icon="/usr/share/icons/Adwaita/32x32/emblems/emblem-synchronizing.png"   # path in Fedora 28
    # notify-send is a popup notification on most Linux desktops, install `libnotify-bin`
    command -v notify-send && notify-send --urgency critical --icon "$warning_icon" "$message"
}

################################# range checks ################################
# if source string is empty
if [ -z "$source" ]; then
    print_message "ERROR" "aborted - source string is empty."
    exit 1
fi

# if dest string is empty
if [ -z "$dest" ]; then
    print_message "ERROR" "aborted - dest string is empty."
    exit 1
fi

# if source is empty
if ! test "rclone lsf --max-depth 1 $source"; then  # rclone lsf requires rclone 1.40 or later
    print_message "ERROR" "aborted - source is empty."
    exit 1
fi

# if job is already running (maybe previous run didn't finish)
# https://github.com/wolfv6/rclone_jobber/pull/9 said this is not working in macOS
if [[ $(pidof -x "$(basename "$0")" -o %PPID) ]]; then
    print_message "WARNING" "aborted - process already running."
    exit 1
fi

############################### move_old_files_to #############################
# deleted or changed files are removed or moved, depending on value of move_old_files_to variable
# default move_old_files_to="" will remove deleted or changed files from backup
if [ "$move_old_files_to" = "dated_directory" ]; then
    # move deleted or changed files to archive/$(date +%Y)/$timestamp directory
    backup_dir="--backup-dir=$dest/archive/$(date +%Y)/$timestamp"
elif [ "$move_old_files_to" = "dated_files" ]; then
    # move deleted or changed files to old directory, and append _$timestamp to file name
    backup_dir="--backup-dir=$dest/old_files --suffix=_$timestamp"
elif [ "$move_old_files_to" != "" ]; then
    print_message "WARNING" "Parameter move_old_files_to=$move_old_files_to, but should be dated_directory or dated_files.\
  Moving old data to dated_directory."
    backup_dir="--backup-dir=$dest/$timestamp"
fi

# notify healthchecks.io to measure command run time
if [ "$hc" = true ]; then
    curl -fsS --retry 3 --quiet "$monitoring_url/start" -O /dev/null
    exit 0
fi

################################### back up ##################################
if [ "$hc" = false ] || [ "$log_to_hc" = false ]; then
	cmd="rclone sync $source $dest/$new $backup_dir $log_option $options"
	# progress message
	echo "Back up in progress $timestamp $job_name"
	echo "$cmd"
elif [ "$log_to_hc" = true ]; then
	output=$("rclone sync $source $dest/$new $backup_dir $log_option $options")
fi

# set logging to verbose
#send_to_log "$timestamp $job_name"
#send_to_log "$cmd"

eval "$cmd"
exit_code=$?

############################ confirmation and logging ########################
if [ "$exit_code" -eq 0 ]; then            # if no errors
    confirmation="$(date +%F_%T) completed $job_name"
    echo "$confirmation"
    send_to_log "$confirmation"
    send_to_log ""
    if [ "$hc" = true ]; then
		curl -fsS --retry 3 --quiet "$monitoring_url" -O /dev/null
    fi
    exit 0
else
    print_message "ERROR" "failed.  rclone exit_code=$exit_code"
    if [ "$hc" = true ]; then
		curl -fsS --retry 3 --data-raw "$output" "$monitoring_url/fail" -O /dev/null
    fi
    send_to_log ""
    exit 1
fi
