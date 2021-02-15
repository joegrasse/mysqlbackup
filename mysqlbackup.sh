#!/bin/sh

##########################
# MySQL backup Program
# Written by: Joe Grasse
##########################
# Notes:
#   For help:
#     ./mysqlbackup.sh -h
#   External programs Used: 
#     cp cat chmod wc rm tar sed find date bc sendmail mysql mysqldump
#   If using remote copy programs used include: 
#     sudo ssh
#   Backup user permissions
#     SELECT, RELOAD, SHOW DATABASES, SHOW VIEW, SUPER, and possibly LOCK TABLES
#   If backing up a slave
#     REPLICATION CLIENT
#   Umask can be set in .bashrc and .bash_profile

# Configuration parameters
MODE="" # Options full, ddl, or inc (Incremental)
BACKUP_DIR="" # Directory where backups will be stored
STATUS_FILE="" # used to keep track of where backup is at
MYSQL_BINLOG_PATH="" # The directory where the binary logs are located
RETENTION="" # example 10D (10 Days), D = day W = week M = month Y = year, how long to keep backups
MYSQL_USER="" # optional
MYSQL_PASSWORD="" # optional
MYSQL_SOCKET="" # optional
MYSQL_PORT="" # optional
EMAIL_ADDRESS="" # optional

# Remote copy configuration parameters
# Optional, all must be set to perform remote copy and purge
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_DIR=""
# Optional
SUDO_USER=""

# Global variables that may need to be set if not auto discovered
MYSQL_EXECUTABLE_DIR=""
MYSQL_SLAVE_LOAD_TMPDIR=""

# Global variables used by the script
MYSQL_DATADIR="" # example /var/lib/mysql/
MYSQL_LOG_BIN="" # example OFF
MYSQL_VERSION="" # example 4.1.11
MASTER_INFO_REPOSITORY="FILE"
RELAY_LOG_INFO_REPOSITORY="FILE"
MYSQL=""
MYSQLDUMP=""
MYSQL_OPTIONS=""
MYSQLDUMP_OPTIONS=""
MYSQLDUMP_OPTIONS_MYSQL_DATA=""
STARTING_BINLOG=""
NEXT_BINLOG=""
IS_SLAVE=""
NON_TRANSACTIONAL=0
BACKUP_DATE_TIME=""
F_BACKUP_DATE_TIME=""
BACKUP_NAME=""
BACKUP_TIME=""
BACKUP_LOCK_START=0
BACKUP_LOCK_STOP=0
BACKUP_LOCK_TIME=""
BACKUP_SIZE=""
BACKUP_STATUS=0
SUDO_COMMAND=""
PROGRAM_NAME=$0
VERBOSE=0
MYSQL_DATA=0
DUMP_SLAVE=0
declare -a MYSQL_VERSION_ARRAY
declare -a BINLOGS
declare -a BACKUP_FILES
declare -a DATABASES
declare -a ERRORS
declare -a WARNINGS

# SENDMAIL program
SENDMAIL="/usr/sbin/sendmail"

# Set allowed configs to be set via config file
VALID_CONFIGS=(MODE RETENTION BACKUP_DIR STATUS_FILE MYSQL_BINLOG_PATH MYSQL_USER MYSQL_PASSWORD MYSQL_PORT MYSQL_SOCKET EMAIL_ADDRESS DUMP_SLAVE REMOTE_HOST REMOTE_USER REMOTE_DIR MYSQL_EXECUTABLE_DIR SUDO_USER MYSQL_SLAVE_LOAD_TMPDIR MYSQL_DATA VERBOSE)

function version(){
  echo "${PROGRAM_NAME##*/} 1.8"
  exit 0
}

function usage(){
cat <<ENDOFMESSAGE 
  Usage: ${PROGRAM_NAME} -m mode -d backup_dir -f status_file -b binlog_dir [options]
  
  Config file option in brackets [].

  Required:
    -m mode         [MODE] Backup mode.
                      full - Full backup
                      inc - Incremental backup
                      ddl - Backup the database ddl statements
    -d backup_dir   [BACKUP_DIR] Backup Directory.
    -f status_file  [STATUS_FILE] The file used to keep track of backup information. Will be created
                      if it does not exist.
    -b binlog_dir   [MYSQL_BINLOG_PATH] The directory where the MySQL binlogs are located.
  
  Other Options:
    -u user         [MYSQL_USER] MySQL user
    -p password     [MYSQL_PASSWORD] MySQL password
    -P port         [MYSQL_PORT] MySQL port
    -S socket       [MYSQL_SOCKET] MySQL socket
    -r retention    [RETENTION] How long to keep the backups, D = day W = week M = month Y = year.
                      Example: 10D (10 Days)
    -e email        [EMAIL_ADDRESS] Email address to send backup status.
    -s              [DUMP_SLAVE] Include binary log coordinates of slave's master
    -M              [MYSQL_DATA] Backups mysql table data. For use with ddl backup mode.
    -H remote_host  [REMOTE_HOST] Remote host to copy backup to.
    -U remote_user  [REMOTE_USER] User to connect to remote host.
    -D remote_dir   [REMOTE_DIR] Backup directory on remote host.
    -L sudo_user    [SUDO_USER] Local user to sudo the remote copy and purge commands.
    -E mysql_dir    [MYSQL_EXECUTABLE_DIR] The directory where the MySQL executables are located.
    -l load_dir     [MYSQL_SLAVE_LOAD_TMPDIR] The directory where the slave load files are located.
    -V              Version information.
    -v              [VERBOSE] Verbose mode. Produces more output about what the program does.
                      This option can be given multiple times to produce more output.
                      Example: -v -v
    -h              Show this message.
ENDOFMESSAGE

exit $1
}

function print(){
  local datetime=$(date '+%a %b %e %T %Y')

  echo "$datetime: $@"
}

function print_error(){
  BACKUP_STATUS=1
  
  ERRORS=("${ERRORS[@]}" "$@")

  print "ERROR: $@"
}

function print_warning(){
  # check that we don't already have errors
  if [ ! $BACKUP_STATUS -eq 1 ] ; then
    BACKUP_STATUS=2
  fi

  WARNINGS=("${WARNINGS[@]}" "$@")

  print "WARNING: $@"
}

function print_exit(){
  BACKUP_STATUS=1

  print_error "$@"

  print "End backup"

  exit_backup 1
}

function exit_backup(){
  if [ "$EMAIL_ADDRESS" ] ; then
    email_results
  fi

  exit $1
}

function backup_date(){
  local -a dt_a
  local date_time=$(date '+%Y-%m-%d-%H-%M-%S-%A-%b')
  
  # we want to break on - (dash)
  OLD_IFS=$IFS
  IFS='-'
  
  # save date time parts into an array
  dt_a=( $date_time )
  
  IFS=$OLD_IFS  
  
  BACKUP_DATE_TIME="${dt_a[0]}${dt_a[1]}${dt_a[2]}${dt_a[3]}${dt_a[4]}${dt_a[5]}"
  F_BACKUP_DATE_TIME="${dt_a[6]} ${dt_a[7]} ${dt_a[2]} ${dt_a[0]} ${dt_a[3]}:${dt_a[4]}:${dt_a[5]}"
}

function is_integer() {
  [ "$1" -eq "$1" ] > /dev/null 2>&1
  return $?
}

function check_retention(){
  local number time num_days

  if [ ${#RETENTION} -eq 1 ] ; then
    echo "${PROGRAM_NAME}: Invalid retention policy"
    usage 1
  elif [ ${#RETENTION} -gt 1 ] ; then
    number=${RETENTION:0:(${#RETENTION}-1)}
    time=${RETENTION:(-1)}
    
    if ! is_integer ${number} ; then
      echo "${PROGRAM_NAME}: Retention policy must be an integer followed by time designator"
      usage 1
    elif [ $number -lt 1 ] ; then
      echo "${PROGRAM_NAME}: Retention policy must be greater than 0"
      usage 1
    fi
    
    if [ $time = "Y" ] || [ $time = "y" ] ; then #year
      num_days=$((number * 365))    
    elif [ $time = "M" ] || [ $time = "m" ] ; then # month
      num_days=$((number * 30))
    elif [ $time = "W" ] || [ $time = "w" ] ; then # week
      num_days=$((number * 7))
    elif [ $time = "D" ] || [ $time = "d" ] ; then # day
      num_days=$((number * 1))
    else
      echo "${PROGRAM_NAME}: Invalid retention policy"
      usage 1
    fi

    # need to adjust days for find command
    RETENTION=$((num_days - 1))
  fi
}

function check_status_file(){
  # check for status file
  if [ -f "$STATUS_FILE" ] ; then
    # check that we can write to the status file
    if [ ! -w "$STATUS_FILE" ] ; then
      print_exit "Can not write to ${STATUS_FILE}"
    fi
  else
    # try to create status file
(
cat <<'EOF'
# last successfull backup
last-backup=

# last successfull full backup
last-full-backup=

# date and time of last backup
backup-date=

# type of last backup
backup-type=

# binlog to start with on next backup
next-binlog=
EOF
) > "$STATUS_FILE"

    # check for created file
    if [ -f "$STATUS_FILE" ] ; then
      `chmod 644 "$STATUS_FILE" 2> /dev/null`
      
      # check if the command failed
      if [ $? -ne 0 ] ; then
        print_exit "Could not: chmod 644 ${STATUS_FILE}"
      fi
    else
      print_exit "Can not create backup status file ${STATUS_FILE}" 
    fi  
  fi
}

function check_required_parameters(){
  # check for mode
  if [ ! "$MODE" ]; then
    echo "${PROGRAM_NAME}: The backup mode must be set"
    usage 1
  # check for valid mode
  elif [ ! "$MODE" = "full" ] && [ ! "$MODE" = "inc" ] && [ ! "$MODE" = "ddl" ] ; then
    echo "${PROGRAM_NAME}: Invalid backup mode"
    usage 1
  fi

  # check for provided retention
  check_retention

  # check for provided status file
  if [ ! "$STATUS_FILE" ] ; then
    echo "${PROGRAM_NAME}: The location of the status file must be set"
    usage 1
  else
    check_status_file
  fi

  # check for provided backup dir
  if [ ! "$BACKUP_DIR" ] ; then
    echo "${PROGRAM_NAME}: The backup directory must be set"
    usage 1
  fi

  # check for provided mysql binary logs dir
  if [ ! "$MYSQL_BINLOG_PATH" ] ; then
    echo "${PROGRAM_NAME}: The mysql binary logs directory must be set"
    usage 1
  fi
}

function check_optional_parameters(){
  local output
  
  # check the BACKUP_DIR parameter for ending /
  if [ ! "${BACKUP_DIR:(-1)}" = "/" ] ; then
    BACKUP_DIR="${BACKUP_DIR}/"
  fi
  
  # check that the backup folder provided is actually writable
  if [ ! -w "$BACKUP_DIR" ] ; then
    print_exit "The backup directory: ${BACKUP_DIR} is not writable"
  fi
  
  # check if the MYSQL_EXECUTABLE_DIR parameter is set and if it is that it has an ending slash
  if [ "$MYSQL_EXECUTABLE_DIR" ] && [ ! "${MYSQL_EXECUTABLE_DIR:(-1)}" = "/" ] ; then
    MYSQL_EXECUTABLE_DIR="${MYSQL_EXECUTABLE_DIR}/"
  fi
  
  MYSQL="${MYSQL_EXECUTABLE_DIR}mysql"
  
  # check that we can run the mysql executable
  output=`$MYSQL -V 2> /dev/null` 
  if [ $? -ne 0 ] ; then
    print_exit "Can not execute mysql, try setting the mysql executable directory"
  fi
  
  MYSQLDUMP="${MYSQL_EXECUTABLE_DIR}mysqldump"
  
  # check that we can run the mysqldump command
  output=`$MYSQLDUMP -V 2> /dev/null` 
  if [ $? -ne 0 ] ; then
    print_exit "Can not execute mysqldump, try setting the mysql executable directory"
  fi

  # check the MYSQL_BINLOG_PATH parameter for ending /
  if [ ! "${MYSQL_BINLOG_PATH:(-1)}" = "/" ] ; then
    MYSQL_BINLOG_PATH="${MYSQL_BINLOG_PATH}/"
  fi
  
  # check that the binlog folder provided is actually a valid folder
  if [ ! -d "$MYSQL_BINLOG_PATH" ] ; then
    print_exit "The MySQL binary log directory must be set to a valid directory"
  fi

  # check the remote host settings
  if [ "$REMOTE_USER" ] && [ "$REMOTE_HOST" ] && [ "$REMOTE_DIR" ] ; then
    # check for ending /
    if [ ! "${REMOTE_DIR:(-1)}" = "/" ] ; then
      REMOTE_DIR="${REMOTE_DIR}/"
    fi    
  elif [ "$REMOTE_USER" ] || [ "$REMOTE_HOST" ] || [ "$REMOTE_DIR" ] ; then
    print_exit "The remote host, remote user, and remote directory must all be set to perform remote copy and purge"
  fi
}

function check_parameters(){
  check_required_parameters  
  check_optional_parameters
}

function setup_mysql_options(){
  if [ "$MYSQL_USER" ] && [ "$MYSQL_PASSWORD" ] ; then
    MYSQL_OPTIONS="-u ${MYSQL_USER} -p${MYSQL_PASSWORD}"
  elif [ "$MYSQL_USER" ] ; then
    MYSQL_OPTIONS="-u ${MYSQL_USER}"
  fi

  if [ "$MYSQL_SOCKET" ] ; then
    MYSQL_OPTIONS="${MYSQL_OPTIONS} -S ${MYSQL_SOCKET}"
  elif [ "$MYSQL_PORT" ] ; then
    MYSQL_OPTIONS="${MYSQL_OPTIONS} -P ${MYSQL_PORT} -h 127.0.0.1"
  fi
}

function setup_mysqldump_options(){  
  local major=${MYSQL_VERSION_ARRAY[0]}
  local minor=${MYSQL_VERSION_ARRAY[1]}
  local revision=${MYSQL_VERSION_ARRAY[2]}
  local master_data=" --master-data"
  local add_event_routine_options=0

  MYSQLDUMP_OPTIONS=" --opt"
  
  if [ "$MODE" != "ddl" ] ; then
    MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --flush-logs"
  fi
  
  MYSQLDUMP_OPTIONS_MYSQL_DATA="--opt --databases mysql"

  # Only need to add --events and --routines if not including mysql tables in backup
  if [ "$MODE" = "ddl" ] && [ $MYSQL_DATA -ne 1 ] ; then
    add_event_routine_options=1
  fi
  
  if [ $major -ge 5 ] ; then
    if [ $minor -ge 5 ] ; then # >= 5.5
      if [ $add_event_routine_options -eq 1 ] ; then
        MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --events --routines"
        MYSQLDUMP_OPTIONS_MYSQL_DATA="${MYSQLDUMP_OPTIONS_MYSQL_DATA} --events --routines"
      fi
    elif [ $minor -eq 1 ] ; then # 5.1
      if [ $revision -ge 8 ] && [ $add_event_routine_options -eq 1 ] ; then
        MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --events"
        MYSQLDUMP_OPTIONS_MYSQL_DATA="${MYSQLDUMP_OPTIONS_MYSQL_DATA} --events"
      fi
      if [ $revision -ge 2 ] && [ $add_event_routine_options -eq 1 ] ; then
        MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --routines"
        MYSQLDUMP_OPTIONS_MYSQL_DATA="${MYSQLDUMP_OPTIONS_MYSQL_DATA} --routines"
      fi
    elif [ $minor -eq 0 ] ; then # 5.0
      if [ $revision -ge 13 ] && [ $add_event_routine_options -eq 1 ] ; then
        MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --routines"
        MYSQLDUMP_OPTIONS_MYSQL_DATA="${MYSQLDUMP_OPTIONS_MYSQL_DATA} --routines"
      fi
    fi
    
    master_data="${master_data}=2"
    
    if [ $NON_TRANSACTIONAL -gt 0 ] ; then
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --lock-all-tables"
    else
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --single-transaction"
    fi
  elif [ $major -eq 4 ] && [ $minor -eq 1 ] && [ $revision -ge 8 ] ; then # >= 4.1.8
    master_data="${master_data}=2"
    
    if [ $NON_TRANSACTIONAL -gt 0 ] ; then
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --lock-all-tables"
    else
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --single-transaction"
    fi
  elif [[ $major -eq 4 && $minor -eq 0 && $revision -ge 2 ]] || [[ $major -eq 4 && $minor -eq 1 ]] ; then # >= 4.0.2 || >= 4.1.0
    if [ $NON_TRANSACTIONAL -eq 0 ] ; then
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --single-transaction"
    fi
  fi

  # Check for dump-slave instead of master-data
  if [ $DUMP_SLAVE -eq 1 ]; then
    if [ $major -gt 5 ] ; then
      master_data=" --dump-slave=2"
    elif [ $major -eq 5 ] && [ $minor -eq 5 ] && [ $revision -ge 3 ] ; then # >= 5.5.3
      master_data=" --dump-slave=2"
    elif [ $major -eq 5 ] && [ $minor -gt 5 ] ; then # > 5.5
      master_data=" --dump-slave=2"
    fi
  fi
  
  # if binlogs are enabled add master-data option
  if [ $MYSQL_LOG_BIN = "ON" ] ; then
    MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS}$master_data"
  fi
  
  # In ddl mode we don't want to backup the data
  # Also don't want to backup the mysql database because 
  if [ "$MODE" = "ddl" ]; then
    MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --no-data"
    
    # if we don't want the mysql database table data then we backup all databases as well
    if [ $MYSQL_DATA -ne 1 ]; then
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --all-databases"
    # we do want the mysql database table data so we back those up in a separte statement
    # Get the list of database minus the mysql, information_schema, and performance_schema databases
    else
      MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --databases `${MYSQL} ${MYSQL_OPTIONS} --skip-column-names -Be'SHOW DATABASES'|grep -vE '^mysql|information_schema|performance_schema$'`"
    fi
  # Not in ddl mode, backup everything
  else
    MYSQLDUMP_OPTIONS="${MYSQLDUMP_OPTIONS} --all-databases"
  fi
}

function get_mysql_variables(){
  local variable value mysql_output

  if [ $VERBOSE -gt 0 ] ; then
    print "Getting global mysql variables"
  fi
  # Get variables from mysql
  mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "SHOW GLOBAL VARIABLES" 2> /dev/null`
  
  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_exit "Failed to SHOW GLOBAL VARIABLES"
  fi

  # we want to break on newlines only
  OLD_IFS=$IFS
  IFS=$'\n'
  
  for v in `echo "$mysql_output"`; do
    # break up the single line of output into it's variable and value
    variable="${v%%[[:space:]]*}"
    value="${v#*[[:space:]]}"

    if [ "$variable" = "datadir" ] ; then
      MYSQL_DATADIR="$value"
      
      # check for ending /
      if [ ! "${MYSQL_DATADIR:(-1)}" = "/" ] ; then
        MYSQL_DATADIR="${MYSQL_DATADIR}/"
      fi
    elif [ "$variable" = "log_bin" ] ; then
      MYSQL_LOG_BIN=${value}
    elif [ "$variable" = "master_info_repository" ] ; then
      MASTER_INFO_REPOSITORY="$value"
    elif [ "$variable" = "relay_log_info_repository" ] ; then
      RELAY_LOG_INFO_REPOSITORY="$value"
    elif [ "$variable" = "slave_load_tmpdir" ] ; then
      MYSQL_SLAVE_LOAD_TMPDIR="$value"
      
      # check for ending /
      if [ ! "${MYSQL_SLAVE_LOAD_TMPDIR:(-1)}" = "/" ] ; then
        MYSQL_SLAVE_LOAD_TMPDIR="${MYSQL_SLAVE_LOAD_TMPDIR}/"
      fi
    elif [ "$variable" = "version" ] ; then
      MYSQL_VERSION="$value"
    fi
  done
  
  IFS=$OLD_IFS
  
  if [ ! "$MYSQL_DATADIR" ] ; then
    print_exit "The mysql datadir variable was not found, please set it"
  elif [ ! "$MYSQL_LOG_BIN" ] ; then
    print_exit "The mysql log_bin variable was not found, please set it"
  elif [ ! "$MYSQL_VERSION" ] ; then
    print_exit "The mysql version variable was not found, please set it"
  elif [ ! "$MYSQL_SLAVE_LOAD_TMPDIR" ] ; then
    print_exit "The slave load tmpdir variable was not found, please set it"
  fi
  
  # we want to split version string on . (period)
  OLD_IFS=$IFS
  IFS='.'

  # MYSQL_VERSION_ARRAY 0 = major, 1 = minor, 2 = revision
  MYSQL_VERSION_ARRAY=( $MYSQL_VERSION )
  
  IFS=$OLD_IFS
  
  # revision number might contain text, strip it
  MYSQL_VERSION_ARRAY[2]=${MYSQL_VERSION_ARRAY[2]%%[^[:digit:]]*}
}

function check_if_slave(){
  if [ $VERBOSE -gt 0 ] ; then
    print "Checking if slave server"
  fi
  # check slave status
  local mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "SHOW SLAVE STATUS\G" 2> /dev/null`
  
  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_exit "Failed to SHOW SLAVE STATUS"
  fi
  
  if [ "$mysql_output" ] ; then
    IS_SLAVE="TRUE"
  else
    IS_SLAVE="FALSE"
  fi
}

function stop_slave(){
  if [ $IS_SLAVE = "TRUE" ] ; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Stopping slave threads"
    fi
    local mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "STOP SLAVE" 2> /dev/null`
    
    # check if the command failed
    if [ $? -ne 0 ] ; then
      print_exit "Failed to STOP SLAVE"
    fi
  fi
}

function start_slave(){
  if [ $IS_SLAVE = "TRUE" ] ; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Starting slave threads"
    fi
    local mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "START SLAVE" 2> /dev/null`
    
    # check if the command failed
    if [ $? -ne 0 ] ; then
      print_warning "Failed to START SLAVE"
    fi
  fi
}

function get_start_binlog(){
  # Look for the next-binlog line and grab the next binlog
  STARTING_BINLOG=`sed -e "/^next-binlog=\([^\s]*\)/ !d" -e 's//\1/' $STATUS_FILE 2> /dev/null`
  
  if [ $? -ne 0 ] || [ ! "$STARTING_BINLOG" ] ; then
    return 1
  fi
  
  return 0
}

function flush_logs(){
  # flush logs
  if [ $VERBOSE -gt 0 ] ; then
    print "Flushing server logs"
  fi
  local mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "FLUSH LOGS" 2> /dev/null`

  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_exit "Failed to FLUSH LOGS"
  fi
}

function get_binlogs(){
  local num_binlogs=0 binlog_name mysql_output

  # get binlog list
  if [ $VERBOSE -gt 0 ] ; then
    print "Getting binlog list"
  fi
  mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "SHOW MASTER LOGS" 2> /dev/null`

  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_error "Failed to get binlog list"
  else
    # we want to break on newlines only
    OLD_IFS=$IFS
    IFS=$'\n'
  
    # put binlogs in array
    for l in `echo "$mysql_output"`; do
      # Each line could contain the binlog name and size
      # we just want the name
      binlog_name=${l%%[[:space:]]*}
      
      BINLOGS[$num_binlogs]="${binlog_name}"
      
      
      ((num_binlogs += 1))
    done
  
    IFS=$OLD_IFS
  
    if [ $num_binlogs -eq 0 ] ; then
      print_error "Binlogs not available"
    else  
      # Save the last binlog in the list
      NEXT_BINLOG="${BINLOGS[${#BINLOGS[@]}-1]}"
    fi
  fi
}

function get_binlogs_to_backup(){
  local binlog found=0 start=0 end=0 i=0 count
  local -a backup_binlogs

  for binlog in "${BINLOGS[@]}"; do
    # check if the current binlog is the one we are supposed to start from
    if [ $binlog = "${STARTING_BINLOG}" ] ; then
      # mark that we have found it and it's index
      found=1
      start=$i
    fi
    
    # Check if we have hit the last binlog
    if [ $binlog = "${NEXT_BINLOG}" ] ; then
      break
    fi    
    
    ((i += 1))
  done
  
  # set the number of binlogs we need to save
  end=$(($i - $start))
  
  # check if we found the binlog that we were supposed to start from
  if [ $found -ne 1 ] ; then
    print_warning "Last recorded binlog not found. Saving binlogs starting with first currently available binlog"
  fi
  
  # save just the binlogs that we need to backup
  BINLOGS=( ${BINLOGS[@]:$start:$end} )
  
  if [ $VERBOSE -gt 1 ] ; then
    print "Binlogs to backup: ${BINLOGS[@]}"
  fi

  count=0
  for binlog in "${BINLOGS[@]}"; do
    # check that we can read the binlog
    if [ ! -r "${MYSQL_BINLOG_PATH}${binlog}" ] ; then
      print_warning "Binlog ${MYSQL_BINLOG_PATH}${binlog} is not readable"
    else
      # add binlog file to files to be backed up
      BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${MYSQL_BINLOG_PATH}\" \"${binlog}\"" )
      ((count += 1))
    fi
  done

  # check if we are going to backup any binlogs
  if [ $count -eq 0 ] ; then
    print_warning "Not backing up any binlogs"
  fi
}

function get_databases(){
  # get database list
  if [ $VERBOSE -gt 0 ] ; then
    print "Getting database list"
  fi
  local mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "SHOW DATABASES" 2> /dev/null`

  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_exit "Failed to get list of databases"
  fi

  # we want to break on newlines only
  OLD_IFS=$IFS
  IFS=$'\n'
  
  # put databases into an array
  DATABASES=( ${mysql_output} )
  
  IFS=$OLD_IFS
}

function check_database_engines(){
  local -a rows
  local -a columns
  local mysql_output

  if [ ! "$1" ] ; then
    print_exit "Database to get the table engines from, was not provided"
  fi
  
  # get table list
  mysql_output=`${MYSQL} ${MYSQL_OPTIONS} -Bse "SHOW TABLE STATUS FROM \\\`${1}\\\`" 2> /dev/null`

  # check if the command failed
  if [ $? -ne 0 ] ; then
    print_exit "Failed to get list of table engines"
  fi

  # we want to break on newlines only
  OLD_IFS=$IFS
  IFS=$'\n'
  
  # put databases into an array
  rows=( ${mysql_output} )
  
  IFS=$OLD_IFS
  
  for row in "${rows[@]}"; do
    # we want to break on tabs only
    OLD_IFS=$IFS
    IFS=$'\t'

    # put databases into an array
    # columns array 0 = table name, 1 = table engine
    columns=( ${row[@]} )
    
    IFS=$OLD_IFS
    
    # Check if table engine is transactional
    if [ ! "${columns[1]}" = "InnoDB" ] && [ ! "${columns[1]}" = "BDB" ] ; then
       ((NON_TRANSACTIONAL +=1))
       # we only care if there is at least one
       break
    fi
  done
}

function check_engines(){
  local database

  # get the database list
  get_databases

  # loop through the databases and check the tables in them
  for database in "${DATABASES[@]}"; do
    # we don't care about the engine types in the mysql and information_schema databases
    if [ ! "$database" = "mysql" ] && [ ! "$database" = "information_schema" ] ; then
      if [ $VERBOSE -gt 0 ] ; then
        print "Checking database engines"
      fi
      check_database_engines "${database}"
      
      # we only care if there is at least one database with a non transaction engine
      if [ $NON_TRANSACTIONAL -gt 0 ] ; then
        break
      fi
    fi
  done
}

function remove_tmp_files(){
  local output

  if [ -f "${BACKUP_DIR}backup.sql" ] ; then
    `rm -f "${BACKUP_DIR}backup.sql" 2> /dev/null`

    # check if the command failed
    if [ $? -ne 0 ] ; then
      print_warning "Failed to remove temporary database dump file"
    fi
  fi
  
  if [ -f "${BACKUP_DIR}master.info" ] ; then
    `rm -f "${BACKUP_DIR}master.info" 2> /dev/null`

    # check if the command failed
    if [ $? -ne 0 ] ; then
      print_warning "Failed to remove temporary master.info file"
    fi
  fi
  
  if [ -f "${BACKUP_DIR}relay-log.info" ] ; then
    `rm -f "${BACKUP_DIR}relay-log.info" 2> /dev/null`

    # check if the command failed
    if [ $? -ne 0 ] ; then
      print_warning "Failed to remove temporary relay-log.info file"
    fi
  fi
  
  #look for tmp load files
  output=`eval find "${BACKUP_DIR}" -type f -regex "\"${BACKUP_DIR}SQL_LOAD-.*\"" 2> /dev/null`
  
  if [ $? -ne 0 ] ; then
    print_warning "Failed check for tmp sql load files"
  else
    if [ "$output" ] ; then
      `rm -f "${BACKUP_DIR}"SQL_LOAD-* 2> /dev/null`
  
      # check if the command failed
      if [ $? -ne 0 ] ; then
        print_warning "Failed to remove temporary sql load files"
      fi
    fi    
  fi
}

function get_sql_load_files_to_backup(){
  local file output

  # check for ending /
  if [ ! "${MYSQL_SLAVE_LOAD_TMPDIR:(-1)}" = "/" ] ; then
    MYSQL_SLAVE_LOAD_TMPDIR="${MYSQL_SLAVE_LOAD_TMPDIR}/"
  fi

  # Check that MYSQL_SLAVE_LOAD_TMPDIR is a valid directory
  if [ ! -d "$MYSQL_SLAVE_LOAD_TMPDIR" ] ; then
    print_warning "Slave load tmp dir: ${MYSQL_SLAVE_LOAD_TMPDIR} is not a valid directory"
  else
    output=`eval find "${MYSQL_SLAVE_LOAD_TMPDIR}" -type f -regex "\"${MYSQL_SLAVE_LOAD_TMPDIR}SQL_LOAD-.*\"" 2> /dev/null`
  
    if [ $? -ne 0 ] ; then
      print_warning "Failed check for sql load files"
    elif [ "$output" ]; then
      `cp "${MYSQL_SLAVE_LOAD_TMPDIR}"SQL_LOAD-* "${BACKUP_DIR}" 2> /dev/null`
      
      # check if the command failed
      if [ $? -ne 0 ] ; then
        print_warning "Failed to copy sql load files"
      else
        if [ $VERBOSE -gt 1 ] ; then
          print "Slave load fines to backup: ${output}"
        fi
      
        # we want to split files on newlines only
        OLD_IFS=$IFS
        IFS=$'\n'
        
        # loop through load files
        for file in `echo "$output"`; do
          # Strip off dir path and add load file to files to be backed up
          BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${BACKUP_DIR}\" \"${file##*/}\"" )
        done
        
        IFS=$OLD_IFS
      fi
    fi
  fi
}

function slave_data(){
  # check if slave
  if [ $IS_SLAVE = "TRUE" ] ; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Saving slave data"
    fi

    # Check if we need to backup master.info
    if [ $MASTER_INFO_REPOSITORY = "FILE" ] ; then
      # Test the master file
      if [ ! -r "${MYSQL_DATADIR}master.info" ] ; then
        print_warning "Unable to backup ${MYSQL_DATADIR}master.info"
      else
        `cp "${MYSQL_DATADIR}master.info" "${BACKUP_DIR}master.info" 2> /dev/null`
        # check if the command failed
        if [ $? -ne 0 ] ; then
          print_warning "Failed to copy master.info file"
        fi
  
        BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${BACKUP_DIR}\" \"master.info\"" )
      fi
    fi

    # Check if we need to backup relay-log.info
    if [ $RELAY_LOG_INFO_REPOSITORY = "FILE" ] ; then
      # Test the relay file
      if [ ! -r "${MYSQL_DATADIR}relay-log.info" ] ; then
        print_warning "Unable to backup ${MYSQL_DATADIR}relay-log.info"
      else
        `cp "${MYSQL_DATADIR}relay-log.info" "${BACKUP_DIR}relay-log.info" 2> /dev/null`
        # check if the command failed
        if [ $? -ne 0 ] ; then
          print_warning "Failed to copy relay-log.info file"
        fi
  
        BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${BACKUP_DIR}\" \"relay-log.info\"" )
      fi
    fi

    # get sql load files
    get_sql_load_files_to_backup
  fi
}

function get_backup_size(){
  local found file
  local -a absolute_backup_files
  
  for file in "${BACKUP_FILES[@]}"; do
    # look for relative file path
    found=`echo "$file" | sed -n "/^-C[[:space:]].*/p" 2> /dev/null`
    if [ "$found" ] ; then
      # replace -C and space between dir and filename
      file=${file/#-C /}
      file=${file/\" \"/}
    fi
    
    # add file to array
    absolute_backup_files=( "${absolute_backup_files[@]}" "$file" )
  done
  
  # get the size in bytes of the backup files
  # i have to add the status codes together and return them as one in order to see if either command failed
  if [ $VERBOSE -gt 0 ] ; then
    print "Calculating backup size"
  fi
  BACKUP_SIZE=`eval cat "${absolute_backup_files[@]}" 2> /dev/null | wc -c 2> /dev/null; exit $((${PIPESTATUS[0]}+${PIPESTATUS[1]}))`

  if [ $? -ne 0 ] ; then
    print_warning "Failed to get size of backup before compression"
  else
    # Convert to human readable
    if [ $(echo "$BACKUP_SIZE >= 1073741824" | bc) -eq 1 ] ; then # G
      BACKUP_SIZE=$(echo "scale=2; $BACKUP_SIZE / 1073741824" | bc)" GB"
    elif [ $(echo "$BACKUP_SIZE >= 1048576" | bc) -eq 1 ] ; then # M
      BACKUP_SIZE=$(echo "scale=2; $BACKUP_SIZE / 1048576" | bc)" MB"
    elif [ $(echo "$BACKUP_SIZE >= 1024" | bc) -eq 1 ] ; then # K
      BACKUP_SIZE=$(echo "scale=2; $BACKUP_SIZE / 1024" | bc)" KB"
    else
      BACKUP_SIZE="${BACKUP_SIZE} B"
    fi
  fi
}

function save_backup(){
  local return_code
  
  # check if there are files to back up
  if [ ${#BACKUP_FILES[@]} -gt 0 ] ; then
    # get size of files to back up
    get_backup_size
    
    BACKUP_NAME="backup-${BACKUP_DATE_TIME}.tar.gz"

    # tar and gzip the files to backup
    if [ $VERBOSE -gt 0 ] ; then
      print "Taring backup data"
    fi
    if [ $VERBOSE -gt 1 ] ; then
      print "tar -cpsz ${BACKUP_FILES[@]} -f \"${BACKUP_DIR}${BACKUP_NAME}\" 2> /dev/null"
    fi
    `eval tar -cpsz ${BACKUP_FILES[@]} -f \"${BACKUP_DIR}${BACKUP_NAME}\" 2> /dev/null`
    return_code=$?
    
    # clean up tmp file
    remove_tmp_files
    
    # check if tar worked
    if [ $return_code -ne 0 ] ; then
      print_exit "Failed to tar backup files. Out of disk space??"
    fi
  else
    print_exit "No files backed up"
  fi
}

function inc_backup(){
  if [ $MYSQL_LOG_BIN = "ON" ] ; then
    get_start_binlog
    if [ $? -ne 0 ] ; then
      print_warning "Could not get next-binlog from $STATUS_FILE, performing full backup"
      MODE="full"
      full_backup
    else
      BACKUP_LOCK_START=$(date +%s)
      stop_slave
      flush_logs
      slave_data
      start_slave
      BACKUP_LOCK_STOP=$(date +%s)

      get_binlogs
      
      # check for no exiting error
      if [ ! $BACKUP_STATUS -eq 1 ] ; then
        get_binlogs_to_backup
      fi
      
      # check for errors
      if [ $BACKUP_STATUS -eq 1 ] ; then
        remove_tmp_files
        print "End backup"
        exit_backup 1
      else
        save_backup
      fi
    fi
  else
    print_warning "Binary logging is not enabled, performing full backup"
    MODE="full"
    full_backup
  fi
}

function ddl_backup(){
  local mysql_output return_code mysql_output2 return_code2

  # check what type of engines we have
  check_engines
  # setup the options for mysqldump
  setup_mysqldump_options
  
  BACKUP_LOCK_START=$(date +%s)

  # Dump mysql
  if [ $VERBOSE -gt 0 ] ; then
    print "Dumping database data"
  fi
  if [ $VERBOSE -gt 1 ] ; then
    print "mysqldump options: ${MYSQLDUMP_OPTIONS}"
  fi
  mysql_output=`"${MYSQLDUMP}" ${MYSQL_OPTIONS} ${MYSQLDUMP_OPTIONS} > "${BACKUP_DIR}backup.sql"`
  return_code=$?
  
  if [ $MYSQL_DATA -eq 1 ] ; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Dumping mysql schema data"
    fi
    if [ $VERBOSE -gt 1 ] ; then
      print "mysqldump options: ${MYSQLDUMP_OPTIONS_MYSQL_DATA}"
    fi
    mysql_output2=`"${MYSQLDUMP}" ${MYSQL_OPTIONS} ${MYSQLDUMP_OPTIONS_MYSQL_DATA} >> "${BACKUP_DIR}backup.sql" 2> /dev/null`
    return_code2=$?
  fi

  BACKUP_LOCK_STOP=$(date +%s)

  # check if the command failed
  if [ $return_code -ne 0 ] ; then
    remove_tmp_files
    print_exit "Failed to dump database"
  fi

  # check if the 2nd command failed
  if [ $MYSQL_DATA -eq 1 ] && [ $return_code2 -ne 0 ] ; then
    remove_tmp_files
    print_exit "Failed to dump mysql schema"
  fi

  BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${BACKUP_DIR}\" \"backup.sql\"" )
  
  save_backup
}

function full_backup(){
  local mysql_output return_code backup_binlogs=1

  # check what type of engines we have
  check_engines
  # setup the options for mysqldump
  setup_mysqldump_options
  
  BACKUP_LOCK_START=$(date +%s)
  stop_slave
  slave_data
  # Dump mysql
  if [ $VERBOSE -gt 0 ] ; then
    print "Dumping database data"
  fi
  if [ $VERBOSE -gt 1 ] ; then
    print "mysqldump options: ${MYSQLDUMP_OPTIONS}"
  fi
  mysql_output=`"${MYSQLDUMP}" ${MYSQL_OPTIONS} ${MYSQLDUMP_OPTIONS} > "${BACKUP_DIR}backup.sql" 2> /dev/null`
  return_code=$?
  
  start_slave
  
  BACKUP_LOCK_STOP=$(date +%s)
  
  # check if the command failed
  if [ $return_code -ne 0 ] ; then
    remove_tmp_files
    print_exit "Failed to dump database"
  fi

  BACKUP_FILES=( "${BACKUP_FILES[@]}" "-C \"${BACKUP_DIR}\" \"backup.sql\"" )

  if [ $MYSQL_LOG_BIN = "ON" ] ; then
    get_start_binlog
    if [ $? -ne 0 ] ; then
      backup_binlogs=0
      print_warning "Could not get next-binlog from $STATUS_FILE, not backing up previous binlogs"
      print_warning "This could be because there was no previous backup taken"
    fi
    get_binlogs
    # check for errors
    if [ ! $BACKUP_STATUS -eq 1 ] && [ $backup_binlogs -eq 1 ] ; then
      get_binlogs_to_backup
    fi
  fi
  
  save_backup
}

# TODO: finish if want raw backup
#function raw_backup(){
  # Get list of files to backup
  # Shut down db
  # Save files
  # Start db
  # get binlogs
#}

function save_backup_status(){
  local found
  # get text from status file
  local output=`cat "${STATUS_FILE}" 2> /dev/null`
  
  if [ "$output" ] ; then
    if [ "$MODE" != "ddl" ] ; then
      # Look for the next-binlog line so that we can replace it
      found=`echo "${output}" | sed -n "/^next-binlog=[^\n]*/p" 2> /dev/null`
      
      if [ "$found" ] ; then
        output=`echo "${output}" | sed "s/^next-binlog=[^\n]*/next-binlog=${NEXT_BINLOG}/" 2> /dev/null`
      else
        print_error "Failed to find the next-binlog line for replacement"
      fi
    fi
    
    # Look for the backup-date line so that we can replace it
    found=`echo "${output}" | sed -n "/^backup-date=[^\n]*/p" 2> /dev/null`
    
    if [ "$found" ] ; then
      output=`echo "${output}" | sed "s/^backup-date=[^\n]*/backup-date=${F_BACKUP_DATE_TIME}/" 2> /dev/null`
    else
      print_warning "Failed to find the backup-date line for replacement"
    fi

    # Look for the last-backup line so that we can replace it
    found=`echo "${output}" | sed -n "/^last-backup=[^\n]*/p" 2> /dev/null`    
    
    if [ "$found" ] ; then    
      output=`echo "${output}" | sed "s/^last-backup=[^\n]*/last-backup=${BACKUP_NAME}/" 2> /dev/null`
    else
      print_warning "Failed to find the last-backup line for replacement"
    fi

    if [ $MODE = "full" ] ; then
      # Look for the last-full-backup line so that we can replace it
      found=`echo "${output}" | sed -n "/^last-full-backup=[^\n]*/p" 2> /dev/null`    
      
      if [ "$found" ] ; then    
        output=`echo "${output}" | sed "s/^last-full-backup=[^\n]*/last-full-backup=${BACKUP_NAME}/" 2> /dev/null`
      else
        print_warning "Failed to find the last-full-backup line for replacement"
      fi
    fi
    
    # Look for the backup-type line so that we can replace it
    found=`echo "${output}" | sed -n "/^backup-type=[^\n]*/p" 2> /dev/null`    
    
    if [ "$found" ] ; then    
      output=`echo "${output}" | sed "s/^backup-type=[^\n]*/backup-type=${MODE}/" 2> /dev/null`
    else
      print_warning "Failed to find the backup-type line for replacement"
    fi
    
    `echo "${output}" > "${STATUS_FILE}" 2> /dev/null`
    
    if [ $? -ne 0 ] ; then
      print_error "Failed to save changes to ${STATUS_FILE}"
    fi
    
  else
    print_error "Failed to get contents of status file for updating"
  fi
}

function purge_old_backups(){
  if [ $RETENTION ]; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Purging old backups"
    fi
    if [ $VERBOSE -gt 1 ] ; then
      print "find "\"${BACKUP_DIR}\"" -type f -regex "\"${BACKUP_DIR}backup-[0-9]*.tar.gz\"" -mtime +${RETENTION} -exec rm -f {} \\; 2> /dev/null"
    fi
    `eval find "\"${BACKUP_DIR}\"" -type f -regex "\"${BACKUP_DIR}backup-[0-9]*.tar.gz\"" -mtime +"${RETENTION}" -exec "rm -f {} \\;" 2> /dev/null`
    
    if [ $? -ne 0 ] ; then
      print_warning "Failed to purge old backups"
    fi
  fi
}

function remote_copy(){
  # copy to remote host
  if [ $VERBOSE -gt 0 ] ; then
    print "Copying backup to remote host"
  fi
  if [ "$SUDO_USER" ] ; then
    `eval cat "\"${BACKUP_DIR}${BACKUP_NAME}\"" | sudo -u "${SUDO_USER}" ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" cat ">" "\"${REMOTE_DIR}${BACKUP_NAME}\"" 2> /dev/null`
  else
    `eval cat "\"${BACKUP_DIR}${BACKUP_NAME}\"" | ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" cat ">" "\"${REMOTE_DIR}${BACKUP_NAME}\"" 2> /dev/null`
  fi
  
  if [ $? -ne 0 ] ; then
  	print_warning "Failed to copy backup to remote host ${REMOTE_HOST}";
  fi
}

function remote_purge(){
  if [ $RETENTION ]; then
    # purge backups on remote hosts
    if [ $VERBOSE -gt 0 ] ; then
      print "Purging backups on remote host remote host"
    fi
    if [ "$SUDO_USER" ] ; then
      `eval sudo -u "${SUDO_USER}" ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" find "\"${REMOTE_DIR}\"" -type f -regex "\"${REMOTE_DIR}backup-\[0-9\]*.tar.gz\"" -mtime +"${RETENTION}" -exec "\"rm -f {} \\;\"" 2> /dev/null`
    else
      `eval ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" find "\"${REMOTE_DIR}\"" -type f -regex "\"${REMOTE_DIR}backup-\[0-9\]*.tar.gz\"" -mtime +"${RETENTION}" -exec "\"rm -f {} \\;\"" 2> /dev/null`
    fi
  
    if [ $? -ne 0 ] ; then
      print_warning "Failed to purge old remote backups"
    fi
  fi
}

function remote_cmds(){
  if [ "$REMOTE_USER" ] && [ "$REMOTE_HOST" ] && [ "$REMOTE_DIR" ] ; then
    remote_copy
    remote_purge
  fi
}

function email_results(){
  local f_backup_time f_backup_lock_time error warning headers email_text

  EMAIL_LINE_END=$'\r\n'
  
  if [ "$BACKUP_TIME" ] ; then
    f_backup_time=`printf "%02d:%02d:%02d\n" $((BACKUP_TIME/3600)) $((BACKUP_TIME/60%60)) $((BACKUP_TIME%60))`
  fi
  
  if [ "$BACKUP_LOCK_TIME" ] ; then
    f_backup_lock_time=`printf "%02d:%02d:%02d\n" $((BACKUP_LOCK_TIME/3600)) $((BACKUP_LOCK_TIME/60%60)) $((BACKUP_LOCK_TIME%60))`
  fi

  case "$BACKUP_STATUS" in
    1) backup_status_text="Failed";;
    2) backup_status_text="Successful but with Warnings";;
    *) backup_status_text="Successful";;    
  esac
  
  headers="${headers}From: MySQL Backup Script <mysql@prairiesys.com>"$EMAIL_LINE_END
  headers="${headers}To: ${EMAIL_ADDRESS}"$EMAIL_LINE_END
  headers="${headers}Subject: ${HOSTNAME}: Backup ${backup_status_text}"$EMAIL_LINE_END$EMAIL_LINE_END
  
  email_text="${email_text}  Backup Date: ${F_BACKUP_DATE_TIME}"$EMAIL_LINE_END
  email_text="${email_text}  Backup Mode: ${MODE}"$EMAIL_LINE_END
  email_text="${email_text}  Backup Lock Time: ${f_backup_lock_time}"$EMAIL_LINE_END
  email_text="${email_text}  Backup Time: ${f_backup_time}"$EMAIL_LINE_END
  email_text="${email_text}  Backup Size: ${BACKUP_SIZE}"$EMAIL_LINE_END
  email_text="${email_text}  Backup Status: ${backup_status_text}"$EMAIL_LINE_END

  # Add errors to email if any  
  if [ ${#ERRORS[@]} -gt 0 ] ; then
    email_text="${email_text}"$EMAIL_LINE_END"  The following errors occured:"$EMAIL_LINE_END
    for error in "${ERRORS[@]}"; do
      email_text="${email_text}    ${error}"$EMAIL_LINE_END
    done
  fi

  # add warnings to email if any
  if [ ${#WARNINGS[@]} -gt 0 ] ; then
    email_text="${email_text}"$EMAIL_LINE_END"  The following warnings occured:"$EMAIL_LINE_END
    for warning in "${WARNINGS[@]}"; do
      email_text="${email_text}    ${warning}"$EMAIL_LINE_END
    done
  fi  

  if [ -x "$SENDMAIL" ] ; then
    if [ $VERBOSE -gt 0 ] ; then
      print "Emailing backup status report"
    fi
    `echo "${headers}${email_text}" | ${SENDMAIL} -t 2> /dev/null`
    
    if [ $? -ne 0 ] ; then
      print_error "Failed to send email"
    fi
  else
    print_error "Sendmail command not executable."
  fi
}

function in_array(){
  local search_value="$1"

  shift 1

  local values=("$@")

  for item in "$@"; do
    if [[ $search_value == "$item" ]] ; then
      return 0
    fi
  done

  return 1
}

function read_config(){
  local config="$1"

  print "Reading config file [$config]"

  if [ ! -r $config ] ; then
    print_exit "Config file [ $config ] is not readable"
  fi

  # read the config file
  while read line; do
    if [[ "$line" =~ ^[^#]*= ]] ; then
      name=${line%% =*}
      value=${line#*= }

      # Check if config file value is allowed
      in_array $name ${VALID_CONFIGS[@]}
      if [ $? -eq 0 ] ; then
        eval "$name"="$value"
      else
        print_exit "Config value [ $name ] is not allowed"
      fi
    fi
  done <$config
}

function print_parameters(){
  if [ $VERBOSE -lt 1 ] ; then
    return
  fi

  for item in "${VALID_CONFIGS[@]}"; do
    eval value="$"$item

    # only show password if verbose level greater than 1
    if [ $item == "MYSQL_PASSWORD" ] && [ $VERBOSE -gt 1 ] ; then
      print "Config Value $item [$value]"
    elif [ $item == "MYSQL_PASSWORD" ] ; then
      print "Config Value $item [${value/*/*******}]"
    else
      print "Config Value $item [$value]"
    fi
  done
}

function main(){
  local option backup_start backup_stop
  
  local optstring="c:m:r:d:f:b:u:p:P:S:e:H:U:D:E:L:l:VvhMs"

  while getopts "$optstring" option
  do
    case "$option" in
      c) read_config "$OPTARG";;
    esac
  done

  OPTIND=1

  #check options
  while getopts "$optstring" option
  do
    case "$option" in
      m) MODE="$OPTARG";;
      r) RETENTION="$OPTARG";;
      d) BACKUP_DIR="$OPTARG";;
      f) STATUS_FILE="$OPTARG";;
      b) MYSQL_BINLOG_PATH="$OPTARG";;
      u) MYSQL_USER="$OPTARG";;
      p) MYSQL_PASSWORD="$OPTARG";;
      P) MYSQL_PORT="$OPTARG";;
      S) MYSQL_SOCKET="$OPTARG";;
      e) EMAIL_ADDRESS="$OPTARG";;
      s) DUMP_SLAVE=1;;
      H) REMOTE_HOST="$OPTARG";;
      U) REMOTE_USER="$OPTARG";;
      D) REMOTE_DIR="$OPTARG";;
      E) MYSQL_EXECUTABLE_DIR="$OPTARG";;
      L) SUDO_USER="$OPTARG";;
      l) MYSQL_SLAVE_LOAD_TMPDIR="$OPTARG";;
      c) ;;
      M)
        MYSQL_DATA=1;;
      V)
        version;;
      v)
        ((VERBOSE += 1));;
      h)
        usage 0;;
      *)
        usage 1;;
    esac
  done

  # point to the next argument after getopts has gone through what it knows about
  shift $(($OPTIND - 1))
  
  # check if there are any arguments left
  if [ "$1" ] ; then
    # if there are then it is an error
    usage 1
  fi
  
  #set umask
  umask 026

  print_parameters
  check_parameters

  # get the backup dates
  backup_date
  
  print "Start ${MODE} backup"

  backup_start=$(date +%s)

  setup_mysql_options  
  get_mysql_variables
  check_if_slave
  
  if [ "$MODE" = "inc" ] ; then
    inc_backup
  elif [ "$MODE" = "ddl" ] ; then
    ddl_backup
  else
    full_backup
  fi

  save_backup_status
  purge_old_backups
  remote_cmds
  
  backup_stop=$(date +%s)
  BACKUP_TIME=$((backup_stop - backup_start))
  BACKUP_LOCK_TIME=$((BACKUP_LOCK_STOP - BACKUP_LOCK_START))
  
  print "End backup"
  exit_backup 0
}

main $@
