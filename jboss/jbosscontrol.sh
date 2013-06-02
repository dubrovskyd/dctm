#!/bin/sh


# Please ensure that console output enabled, see conf/jboss-log4j.xml
#   <!-- ============================== -->
#   <!-- Append messages to the console -->
#   <!-- ============================== -->
#   <appender name="CONSOLE" class="org.apache.log4j.ConsoleAppender">
#      <errorHandler class="org.jboss.logging.util.OnlyOnceErrorHandler"/>
#      <param name="Target" value="System.out"/>
#      <param name="Threshold" value="INFO"/>
#
#      <layout class="org.apache.log4j.PatternLayout">
#         <param name="ConversionPattern" value="%d{ABSOLUTE} %-5p [%c{1}] %m%n"/>
#      </layout>
#   </appender>
#
#   <!-- ====================== -->
#   <!-- More Appender examples -->
#   <!-- ====================== -->
#
#   <!-- Buffer events and log them asynchronously -->
#   <appender name="ASYNC" class="org.apache.log4j.AsyncAppender">
#     <errorHandler class="org.jboss.logging.util.OnlyOnceErrorHandler"/>
#     <appender-ref ref="FILE"/>
#     <appender-ref ref="CONSOLE"/>
#     <!--
#     <appender-ref ref="SMTP"/>
#     -->
#   </appender>


###############################################################################
# Node manager shell script version.                                          #
###############################################################################

###############################################################################
# helper functions                                                            #
###############################################################################

###############################################################################
# Reads a line from the specified file and returns it in REPLY.               #
# Error message supressed if file not found.                                  #
###############################################################################
read_file() {
  if [ -f "$1" ]; then
    read REPLY 2>$NullDevice <"$1"
  else
    return 1
  fi
}

###############################################################################
# Writes a line to the specified file. The line will first be written         #
# to a temporary file which is then used to atomically overwrite the          #
# destination file. This prevents a simultaneous read from getting            #
# partial data.                                                               #
###############################################################################
write_file() {
  file="$1"; shift
  echo $* >>$file.tmp
  mv -f "$file.tmp" "$file"
}

###############################################################################
# Updates the state file with new server state information.                   #
###############################################################################
write_state() {
  write_file "$StateFile" "$1"
}

###############################################################################
# Prints informational message to server output log.                          #
###############################################################################
print_info() {
  echo "<`date`> <Info> <NodeManager> <"$@">"
}

###############################################################################
# Prints error message to server output log.                                  #
###############################################################################
print_err() {
  echo "<`date`> <Error> <NodeManager> <"$@">"
}

###############################################################################
# Force kill jboss pid                                                        #
###############################################################################
force_kill() {
  # Check for pid file
  read_file "$PidFile"

  if [ "$?" = "0" ]; then
    srvr_pid=$REPLY
  fi

  # Make sure server is started
  monitor_is_running

  if [ "$?" != "0" -a x$srvr_pid = x ]; then
    echo "Jboss is not currently running" >&2
    return 1
  fi

  # Check for pid file
  if [ x$srvr_pid = x ]; then
    echo "Could not kill server process (pid file not found)." >&2
    return 1
  fi

  kill -9 $srvr_pid

}

###############################################################################
# Makes thread dump of the running java process.                              #
###############################################################################
make_thread_dump() {
  # Check for pid file
  read_file "$PidFile"

  if [ "$?" = "0" ]; then
    srvr_pid=$REPLY
  fi

  # Make sure server is started
  monitor_is_running

  if [ "$?" != "0" -a x$srvr_pid = x ]; then
    echo "Jboss is not currently running" >&2
    return 1
  fi

  # Check for pid file
  if [ x$srvr_pid = x ]; then
    echo "Could not kill server process (pid file not found)." >&2
    return 1
  fi

  kill -3 $srvr_pid

}

###############################################################################
# Returns true if the process with the specified pid is still alive.          #
###############################################################################
is_alive() {
  if [ -d /proc ]; then
    [ -r /proc/$1 -a "x" != "x$1" ]
  else
    ps -p $1 2>$NullDevice | grep -q $1
  fi
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has started.                                                #
###############################################################################
server_is_started() {
  if read_file "$StateFile"; then
    case $REPLY in
      *:Y:*) return 0 ;;
    esac
  fi
  return 1
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has not yet started.                                        #
###############################################################################
server_not_yet_started() {
  if server_is_started; then
    return 1;
  else
    return 0;
  fi
}

###############################################################################
# Returns true if the monitor is running otherwise false. Also will remove    #
# the monitor lock file if it is no longer valid.                             #
###############################################################################
monitor_is_running() {
  if read_file "$LockFile" && is_alive $REPLY; then
    return 0
  fi
  rm -f "$LockFile"
  return 1
}

###############################################################################
# Get the current time as an equivalent time_t.  Note that this may not be    #
# always right, but should be good enough for our purposes of monitoring      #
# intervals.                                                                  #
###############################################################################
time_as_timet() {
    if [ x$BaseYear = x0 ]; then
        BaseYear=1970
    fi
    cur_timet=`date -u +"%Y %j %H %M %S" | awk '{
        base_year = 1970
        year=$1; day=$2; hour=$3; min=$4; sec=$5;
        yearsecs=int((year  - base_year)* 365.25 ) * 86400
        daysecs=day * 86400
        hrsecs=hour*3600
        minsecs=min*60
        total=yearsecs + daysecs + hrsecs + minsecs + sec
        printf "%08d", total
        }'`
}

###############################################################################
# Update the base start time if it is 0.  Every time a server stops,          #
# if the time since last base time is > restart interval, it is reset         #
# to 0.  Next restart of the server will set the last base start time         #
# to the new time                                                             #
###############################################################################
update_base_time() {
  time_as_timet
  if [ $LastBaseStartTime -eq 0 ]; then
    LastBaseStartTime=$cur_timet
  fi
}

###############################################################################
# Computes the seconds elapsed between last start time and current time       #
###############################################################################
compute_diff_time() {
    #get current time as time_t
    time_as_timet
    diff_time=`expr $cur_timet - $LastBaseStartTime`
}

###############################################################################
# Rotate the specified log file. Rotated log files are named                  #
# <server-name>.outXXXXX where XXXXX is the current log count and the         #
# highest is the most recent. The log count starts at 00001 then cycles       #
# again if it reaches 99999.                                                  #
###############################################################################
save_log() {
  fileLen=`echo ${OutFile} | wc -c`
  fileLen=`expr ${fileLen} + 1`
  lastLog=`ls -r1 "$OutFile"* | head -1`
  logCount=`ls -r1 "$OutFile"* | head -1 | cut -c $fileLen-`
  if [ -z "$logCount" ]; then
    logCount=0
  fi
  if [ "$logCount" -eq "99999" ]; then
    logCount=0
  fi
  logCount=`expr ${logCount} + 1`
  zeroPads=""
  case $logCount in
    [0-9]) zeroPads="0000" ;;
    [0-9][0-9]) zeroPads="000" ;;
    [0-9][0-9][0-9]) zeroPads="00" ;;
    [0-9][0-9][0-9][0-9]) zeroPads="0" ;;
  esac
  rotatedLog="$OutFile"$zeroPads$logCount
  mv -f "$OutFile" "$rotatedLog"
  print_info "Rotated server output log to '$rotatedLog'"
}

###############################################################################
# Make sure server directory exists and is valid.                             #
###############################################################################
check_dirs() {
  if [ ! -d "$JBOSS_HOME" ]; then
    echo "Directory '$JBOSS_HOME' not found.  Make sure jboss directory exists and is accessible" >&2
    exit 1
  fi

  if [ ! -d "$JBOSS_HOME/server/$ServerName" ]; then
    echo "Directory '$JBOSS_HOME/server/$ServerName' not found.  Make sure jboss server directory exists and is accessible" >&2
    exit 1
  fi

  mkdir -p "$JBOSS_HOME/server/$ServerName/log"
  mkdir -p "$JBOSS_HOME/server/$ServerName/nodemanager"
}

###############################################################################
# Process node manager START command. Starts server with current startup      #
# properties and enters the monitor loop which will automatically restart     #
# the server when it fails.                                                   #
###############################################################################
do_start() {
  # Make sure server is not already started
  if monitor_is_running; then
    echo "Jboss has already been started" >&2
    return 1
  fi
  # If monitor is not running, but if we can determine that the Jboss
  # process is running, then say that server is already running.
  if read_file "$PidFile" && is_alive $REPLY; then
    echo "Jboss has already been started" >&2
    return 1
  fi
  # Save previous server output log
  [ -f "$OutFile" ] && save_log
  # Remove previous state file
  rm -f "$StateFile"
  # Change to server root directory
  cd "$JBOSS_HOME/server/$ServerName"
  # Now start the server and monitor loop
  start_and_monitor_server &
  # Create server lock file
  write_file "$LockFile" $!
  # Wait for server to start up
  while is_alive $! && server_not_yet_started; do
    sleep 1
  done
  if server_not_yet_started; then
    echo "Jboss failed to start (see server output log for details)" >&2
    return 1
  fi
  return 0
}

start_and_monitor_server() {
  trap "rm -f $LockFile" 0
  # Disconnect input and redirect stdout/stderr to server output log
  exec 0<$NullDevice
  exec >>$OutFile 2>&1
  # Start server and monitor loop
  count=0

  setup_jboss_cmdline

  while true; do
    count=`expr ${count} + 1`
    update_base_time

    start_server_script

    read_file "$StateFile"
    case $REPLY in
      *:N:*)
        print_err "Server startup failed (will not be restarted)"
        write_state FAILED_NOT_RESTARTABLE:N:Y
        return 1
      ;;
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        print_info "Server was shut down normally"
        write_state SHUTDOWN:Y:N
        return 0
      ;;
    esac
    compute_diff_time
    if [ $diff_time -gt $RestartInterval ]; then
      #Reset count
      count=0
      LastBaseStartTime=0
    fi
    if [ $AutoRestart != true ]; then
      print_err "Server failed but is not restartable because autorestart is disabled."
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    elif [ $count -gt $RestartMax ]; then
      print_err "Server failed but is not restartable because the maximum number of restart attempts has been exceeded"
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    fi
    print_info "Server failed so attempting to restart"
      # Optionally sleep for RestartDelaySeconds seconds before restarting
    if [ $RestartDelaySeconds -gt 0 ]; then
      write_state FAILED:Y:Y
      sleep $RestartDelaySeconds
    fi
  done
}

###############################################################################
# Starts the Jboss server                                                     #
###############################################################################
start_server_script() {
  print_info "Starting Jboss with command line: $CommandName $CommandArgs"
  write_state STARTING:N:N
  (

     pid=`exec sh -c 'ps -o ppid -p $$|sed '1d''`

     write_file "$PidFile" $pid
     exec $CommandName $CommandArgs 2>&1) | (
     IFS=""; while read line; do
       case $line in
#JBoss AS 4
         *\[Server\]\ JBoss\ \(MX\ MicroKernel\)\ *Started\ in*)
           write_state RUNNING:Y:N
         ;;
#JBoss AS 5
         *\[ServerImpl\]\ JBoss\ \(Microcontainer\)\ *Started\ in*)
           write_state RUNNING:Y:N
         ;;
         *\[Server\]\ Shutdown\ complete)
           write_state SHUTTING_DOWN:Y:N
         ;;
# Example of killing JBoss AS when DFC_CORE_CRYPTO_ERROR appears in logs
#         *\[DFC_CORE_CRYPTO_ERROR\]*)
#           force_kill
#         ;;
       esac
       echo $line;
    done
  )

  print_info "Jboss exited"
  return 0
}

setup_jboss_cmdline() {

  MEM_ARGS="-Xms128m -Xmx512m -XX:MaxPermSize=256m"
  if [ "x$USER_MEM_ARGS" != "x" ]; then
    MEM_ARGS="$USER_MEM_ARGS"
  fi

  echo $JAVA_OPTS | grep Dorg.jboss.resolver.warning= > $NullDevice 2>&1
  if [ $? -ne 0 ]; then
    JAVA_OPTS="$JAVA_OPTS -Dorg.jboss.resolver.warning=true"
  fi

  echo $JAVA_OPTS | grep Dsun.rmi.dgc.client.gcInterval= > $NullDevice 2>&1
  if [ $? -ne 0 ]; then
    JAVA_OPTS="$JAVA_OPTS -Dsun.rmi.dgc.client.gcInterval=3600000"
  fi

  echo $JAVA_OPTS | grep Dsun.rmi.dgc.server.gcInterval= > $NullDevice 2>&1
  if [ $? -ne 0 ]; then
    JAVA_OPTS="$JAVA_OPTS -Dsun.rmi.dgc.server.gcInterval=3600000"
  fi

  # Setup the JVM
  if [ "x$JAVA_HOME" != "x" -a -x "$JAVA_HOME/bin/java" ]; then
    JAVA="$JAVA_HOME/bin/java"
  else
    echo "Please specify a valid JAVA_HOME" >&2
    return 1
  fi

  # Setup the classpath
  runjar="$JBOSS_HOME/bin/run.jar"
  if [ ! -f "$runjar" ]; then
    echo "Missing required file: $runjar" >&2
    return 1
  fi

  JBOSS_BOOT_CLASSPATH="$runjar"

  # Tomcat uses the JDT Compiler
  # Only include tools.jar if someone wants to use the JDK instead.
  # compatible distribution which JAVA_HOME points to
  if [ "x$JAVAC_JAR" = "x" ]; then
    JAVAC_JAR_FILE="$JAVA_HOME/lib/tools.jar"
  else
    JAVAC_JAR_FILE="$JAVAC_JAR"
  fi

  if [ ! -f "$JAVAC_JAR_FILE" -a "x$JAVAC_JAR" != "x"  ]; then
    warn "Missing file: JAVAC_JAR=$JAVAC_JAR"
    warn "Unexpected results may occur."
    JAVAC_JAR_FILE=
  fi

  if [ "x$JBOSS_CLASSPATH" = "x" ]; then
    JBOSS_CLASSPATH="$JBOSS_BOOT_CLASSPATH"
  else
    JBOSS_CLASSPATH="$JBOSS_CLASSPATH:$JBOSS_BOOT_CLASSPATH"
  fi

  if [ "x$JAVAC_JAR_FILE" != "x" ]; then
    JBOSS_CLASSPATH="$JBOSS_CLASSPATH:$JAVAC_JAR_FILE"
  fi

  if [ "x$POST_CLASSPATH" != "x" ]; then
    JBOSS_CLASSPATH="$JBOSS_CLASSPATH:$POST_CLASSPATH"
  fi

  # If -server not set in JAVA_OPTS, set it, if supported
  echo $JAVA_OPTS | grep "\-client" > $NullDevice 2>&1
  if [ $? -ne 0 ]; then
    echo $JAVA_OPTS | grep "\-server" > $NullDevice 2>&1
    if [ $? -ne 0 ]; then
      $JAVA -version | grep -i HotSpot > $NullDevice 2>&1
      if [ $? -eq 0 ]; then
        JAVA_OPTS="-server $JAVA_OPTS"
      fi
    fi
  fi

  # Setup JBoss Native library path
  # Use the common JBoss Native convention
  # for packing platform binaries
  #
  JBOSS_NATIVE_CPU=`uname -m`
  case "$JBOSS_NATIVE_CPU" in
    sun4u*)
      JBOSS_NATIVE_CPU="sparcv9"
    ;;
    i86pc*)
      JBOSS_NATIVE_CPU="x86"
    ;;
    i[3-6]86*)
      JBOSS_NATIVE_CPU="x86"
    ;;
    x86_64*)
      JBOSS_NATIVE_CPU="x64"
    ;;
    ia64*)
      JBOSS_NATIVE_CPU="i64"
    ;;
    9000/800*)
      JBOSS_NATIVE_CPU="parisc2"
    ;;
    Power*)
      JBOSS_NATIVE_CPU="ppc"
    ;;
  esac

  JBOSS_NATIVE_SYS=`uname -s`
  case "$JBOSS_NATIVE_SYS" in
    Linux*)
      JBOSS_NATIVE_SYS="linux2"
    ;;
    SunOS*)
      JBOSS_NATIVE_SYS="solaris"
    ;;
    HP-UX*)
      JBOSS_NATIVE_SYS="hpux"
    ;;
  esac

  JBOSS_NATIVE_DIR="$JBOSS_HOME/bin/META-INF/lib/$JBOSS_NATIVE_SYS/$JBOSS_NATIVE_CPU"
  if [ -d "$JBOSS_NATIVE_DIR" ]; then
    if [ "x$LD_LIBRARY_PATH" = "x" ]; then
      LD_LIBRARY_PATH="$JBOSS_NATIVE_DIR"
    else
      LD_LIBRARY_PATH="$JBOSS_NATIVE_DIR:$LD_LIBRARY_PATH"
    fi
    export LD_LIBRARY_PATH

    if [ "x$JAVA_OPTS" = "x" ]; then
      JAVA_OPTS="-Djava.library.path=$JBOSS_NATIVE_DIR"
    else
      JAVA_OPTS="$JAVA_OPTS -Djava.library.path=$JBOSS_NATIVE_DIR"
    fi
  fi

  # Setup JBoss specific properties
  JAVA_OPTS="$JAVA_OPTS -Dprogram.name=$PROGNAME -Djava.endorsed.dirs=$JBOSS_HOME/lib/endorsed -classpath $JBOSS_CLASSPATH"

  CommandName=$JAVA
  CommandArgs="$JAVA_OPTS $MEM_ARGS org.jboss.Main $JBOSS_OPTS"


echo $CommandName
echo $CommandArgs
}

###############################################################################
# Process node manager KILL command to kill the currently running server.     #
# Returns true if successful otherwise returns false if the server process    #
# was not running or could not be killed.                                     #
###############################################################################
do_kill() {
  # Check for pid file
  read_file "$PidFile"

  if [ "$?" = "0" ]; then
    srvr_pid=$REPLY
  fi

  # Make sure server is started
  monitor_is_running

  if [ $? -ne 0 -a x$srvr_pid = x ]; then
    echo "Jboss is not currently running" >&2
    return 1
  fi

  # Check for pid file
  if [ "x$srvr_pid" = "x" ]; then
    echo "Could not kill server process (pid file not found)." >&2
    return 1
  fi

  if is_alive $srvr_pid; then
    # Kill the server process
    write_state SHUTTING_DOWN:Y:N
    kill $srvr_pid

    # Now wait for up to 60 seconds for monitor to die
    count=0
    while [ $count -lt 60 ] && monitor_is_running; do
      sleep 1
      count=`expr ${count} + 1`
    done
    if monitor_is_running; then
      write_state FORCE_SHUTTING_DOWN:Y:N
      echo "Server process did not terminate in 60 seconds after being signaled to terminate, killing" 2>&1
      kill -9 $srvr_pid
    fi
  else
    echo "Could not kill server process (process does not exists)." >&2
    return 1
  fi

}

do_stat() {
  valid_state=0

  if read_file "$StateFile"; then
    statestr=$REPLY
    state=`echo $REPLY| sed 's/_ON_ABORTED_STARTUP//g'`
    state=`echo $state | sed 's/:.//g'`
  else
    statestr=UNKNOWN:N:N
    state=UNKNOWN
  fi

  if monitor_is_running; then
    valid_state=1
  elif read_file "$PidFile" && is_alive $REPLY; then
    valid_state=1
  fi

  cleanup=N

  if [ $valid_state = 0 ]; then
    case $statestr in
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        state=SHUTDOWN
        write_state $state:Y:N
      ;;
      *UNKNOWN*) ;;
      *SHUT*) ;;
      *FAIL*) ;;
      *:Y:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
      *:N:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
    esac

       if [ "$cleanup" = "Y" ]; then
          if server_is_started; then
            write_state $state:Y:N
          else
            write_state $state:N:N
          fi
       fi
  fi

  if  [ x$InternalStatCall = xY ]; then
       ServerState=$state
  else
       echo $state
  fi
}

###############################################################################
# run command.                                                                #
###############################################################################
do_command() {
    case $NMCMD in
    START)  check_dirs
            do_start
    ;;
    STARTP) check_dirs
            do_start
    ;;
    STAT)   do_stat ;;
    KILL)   do_kill ;;
    STOP)   do_kill ;;
    GETLOG) cat "$OutFile" 2>$NullDevice ;;
    *)      echo "Unrecognized command: $1" >&2 ;;
    esac
}


###############################################################################
# Prints command usage message.                                               #
###############################################################################
print_usage() {
  cat <<__EOF__
Usage: $0 [OPTIONS] CMD
Where options include:
    -h                          Show this help message
    -D<name>[=<value>]          Set a system property
    -d <dir>                    Set the boot patch directory; Must be absolute or url
    -p <dir>                    Set the patch directory; Must be absolute or url
    -n <url>                    Boot from net with the given url as base
    -c <name>                   Set the server configuration name, required
    -r <dir>                    Set the server root directory, required
    -B <filename>               Add an extra library to the front bootclasspath
    -L <filename>               Add an extra library to the loaders classpath
    -C <url>                    Add an extra url to the loaders classpath
    -P <url>                    Load system properties from the given url
    -b <host or ip>             Bind address for all JBoss services
    -g <name>                   HA Partition name (default=DefaultDomain)
    -m <ip>                     UDP multicast port; only used by JGroups
    -u <ip>                     UDP multicast address
    -l <log4j|jdk>              Specify the logger plugin type
__EOF__
}


PROGNAME=$0

AutoRestart=true
RestartMax=2
RestartDelaySeconds=0
LastBaseStartTime=0
NullDevice=/dev/null

###############################################################################
# Parse command line options                                                  #
###############################################################################
eval "set -- $@"
while getopts hD:d:p:n:c:r:B:L:C:P:b:g:m:u:l: flag "$@"; do
  case $flag in
    h)
     print_usage
     exit 0
    ;;
    r)
     JBOSS_HOME=$OPTARG
    ;;
    c)
     ServerName=$OPTARG
     JBOSS_OPTS="$JBOSS_OPTS -c $OPTARG"
    ;;
    D)
     JAVA_OPTS="$JAVA_OPTS -D$OPTARG"
    ;;
    d|p|n|c|r|B|L|C|P|b|g|m|u|l)
     JBOSS_OPTS="$JBOSS_OPTS -$flag $OPTARG"
    ;;
    *) echo "Unrecognized option: $flag" >&2
     exit 1
    ;;
  esac
done

if [ ${OPTIND} -gt 1 ]; then
  shift `expr ${OPTIND} - 1`
fi

if [ $# -lt 1 ]; then
  echo "Please specify a command to execute"
  print_usage
  exit 1
fi

if [ "x$JBOSS_HOME" = "x" ]; then
  echo "Please specify jboss root directory"
  print_usage
  exit 1
fi

if [ "x$ServerName" = "x" ]; then
  echo "Please specify jboss server name"
  print_usage
  exit 1
fi

NMCMD=`echo $1 | tr '[a-z]' '[A-Z]'`

OutFile=$JBOSS_HOME/server/$ServerName/log/$ServerName.out
PidFile=$JBOSS_HOME/server/$ServerName/nodemanager/$ServerName.pid
LockFile=$JBOSS_HOME/server/$ServerName/nodemanager/$ServerName.lck
StateFile=$JBOSS_HOME/server/$ServerName/nodemanager/$ServerName.state
RestartInterval=10

do_command
