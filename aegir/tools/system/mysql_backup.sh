#!/bin/bash

PATH=/usr/local/bin:/usr/local/sbin:/opt/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
SHELL=/bin/bash

check_root() {
  if [ `whoami` = "root" ]; then
    ionice -c2 -n7 -p $$
    renice 19 -p $$
    chmod a+w /dev/null
    if [ ! -e "/dev/fd" ]; then
      if [ -e "/proc/self/fd" ]; then
        rm -rf /dev/fd
        ln -s /proc/self/fd /dev/fd
      fi
    fi
  else
    echo "ERROR: This script should be ran as a root user"
    exit 1
  fi
  _DF_TEST=$(df -kTh / -l \
    | grep '/' \
    | sed 's/\%//g' \
    | awk '{print $6}' 2> /dev/null)
  _DF_TEST=${_DF_TEST//[^0-9]/}
  if [ ! -z "${_DF_TEST}" ] && [ "${_DF_TEST}" -gt "90" ]; then
    echo "ERROR: Your disk space is almost full !!! ${_DF_TEST}/100"
    echo "ERROR: We can not proceed until it is below 90/100"
    exit 1
  fi
}
check_root

if [ -e "/root/.proxy.cnf" ]; then
  exit 0
fi

if [ -e "/root/.pause_heavy_tasks_maint.cnf" ]; then
  exit 0
fi

n=$((RANDOM%600+8))
echo "Waiting $n seconds 1/2 on `date` before running backup..."
sleep $n
n=$((RANDOM%300+8))
echo "Waiting $n seconds 2/2 on `date` before running backup..."
sleep $n
echo "Starting backup on `date`"

if [ -e "/root/.barracuda.cnf" ]; then
  source /root/.barracuda.cnf
  _B_NICE=${_B_NICE//[^0-9]/}
fi
if [ -z "${_B_NICE}" ]; then
  _B_NICE=10
fi

_BACKUPDIR=/data/disk/arch/sql
_CHECK_HOST=$(uname -n 2>&1)
_DATE=$(date +%y%m%d-%H%M%S 2>&1)
_DOW=$(date +%u 2>&1)
_DOW=${_DOW//[^1-7]/}
_DOM=$(date +%e 2>&1)
_DOM=${_DOM//[^0-9]/}
_SAVELOCATION=${_BACKUPDIR}/${_CHECK_HOST}-${_DATE}
if [ -e "/root/.my.optimize.cnf" ]; then
  _OPTIM=YES
else
  _OPTIM=NO
fi
_VM_TEST=$(uname -a 2>&1)
if [[ "${_VM_TEST}" =~ "-beng" ]]; then
  _VMFAMILY="VS"
else
  _VMFAMILY="XEN"
fi
touch /var/run/boa_sql_backup.pid

create_locks() {
  echo "Creating locks for $1"
  #touch /var/run/boa_wait.pid
  touch /var/run/mysql_backup_running.pid
}

remove_locks() {
  echo "Removing locks for $1"
  #rm -f /var/run/boa_wait.pid
  rm -f /var/run/mysql_backup_running.pid
}

check_running() {
  until [ ! -z "${_IS_MYSQLD_RUNNING}" ] \
    && [ -e "/var/run/mysqld/mysqld.sock" ]; do
    _IS_MYSQLD_RUNNING=$(ps aux | grep '[m]ysqld' | awk '{print $2}' 2>&1)
    echo "Waiting for MySQLD availability.."
    sleep 3
  done
}

truncate_cache_tables() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | grep ^cache | uniq | sort 2>&1)
  for C in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
TRUNCATE ${C};
EOFMYSQL
    sleep 1
  done
}

truncate_watchdog_tables() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | grep ^watchdog$ 2>&1)
  for A in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
TRUNCATE ${A};
EOFMYSQL
    sleep 1
  done
}

truncate_accesslog_tables() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | grep ^accesslog$ 2>&1)
  for A in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
TRUNCATE ${A};
EOFMYSQL
    sleep 1
  done
}

truncate_queue_tables() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | grep ^queue$ 2>&1)
  for Q in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
TRUNCATE ${Q};
EOFMYSQL
    sleep 1
  done
}

truncate_views_data_export() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | grep ^views_data_export_index_ 2>&1)
  for Q in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
DROP TABLE ${Q};
EOFMYSQL
    sleep 1
  done
mysql ${_DB}<<EOFMYSQL
TRUNCATE views_data_export_object_cache;
EOFMYSQL
}

repair_this_database() {
  check_running
  mysqlcheck --auto-repair --silent ${_DB}
}

optimize_this_database() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | uniq | sort 2>&1)
  for T in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
OPTIMIZE TABLE ${T};
EOFMYSQL
  done
}

convert_to_innodb() {
  check_running
  _TABLES=$(mysql ${_DB} -e "show tables" -s | uniq | sort 2>&1)
  for T in ${_TABLES}; do
mysql ${_DB}<<EOFMYSQL
ALTER TABLE ${T} ENGINE=INNODB;
EOFMYSQL
  done
}

backup_this_database_with_mydumper() {
  n=$((RANDOM%15+5))
  echo waiting ${n} sec
  sleep ${n}
  check_running
  if [ ! -d "${_SAVELOCATION}/${_DB}" ]; then
    mkdir -p ${_SAVELOCATION}/${_DB}
  fi
  mydumper \
    --database=${_DB} \
    --host=localhost \
    --user=root \
    --password=${_SQL_PSWD} \
    --port=3306 \
    --outputdir=${_SAVELOCATION}/${_DB}/ \
    --rows=50000 \
    --build-empty-files \
    --threads=4 \
    --less-locking \
    --long-query-guard=900 \
    --verbose=1
}

backup_this_database_with_mysqldump() {
  n=$((RANDOM%15+5))
  echo waiting ${n} sec
  sleep ${n}
  check_running
  mysqldump \
    --single-transaction \
    --quick \
    --no-autocommit \
    --skip-add-locks \
    --hex-blob ${_DB} \
    > ${_SAVELOCATION}/${_DB}.sql
}

compress_backup() {
  if [ "${_MYQUICK_STATUS}" = "OK" ]; then
    for DbPath in `find ${_SAVELOCATION}/ -maxdepth 1 -mindepth 1 | sort`; do
      if [ -e "${DbPath}/metadata" ]; then
        DbName=$(echo ${DbPath} | cut -d'/' -f7 | awk '{ print $1}' 2>&1)
        cd ${_SAVELOCATION}
        tar cvfj ${DbName}-${_DATE}.tar.bz2 ${DbName} &> /dev/null
        rm -f -r ${DbName}
      fi
    done
    chmod 600 ${_SAVELOCATION}/*
    chmod 700 ${_SAVELOCATION}
    chmod 700 /data/disk/arch
    echo "Permissions fixed"
  else
    bzip2 ${_SAVELOCATION}/*.sql
    chmod 600 ${_BACKUPDIR}/*/*
    chmod 700 ${_BACKUPDIR}/*
    chmod 700 ${_BACKUPDIR}
    chmod 700 /data/disk/arch
    echo "Permissions fixed"
  fi
}

[ ! -a ${_SAVELOCATION} ] && mkdir -p ${_SAVELOCATION};

if [ "${_DB_SERIES}" = "10.4" ] \
  || [ "${_DB_SERIES}" = "10.3" ] \
  || [ "${_DB_SERIES}" = "10.2" ] \
  || [ "${_DB_SERIES}" = "5.7" ]; then
  check_running
  mysql -u root -e "SET GLOBAL innodb_max_dirty_pages_pct = 0;" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_change_buffering = 'none';" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_at_shutdown = 1;" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_io_capacity = 2000;" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_io_capacity_max = 4000;" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_pct = 100;" &> /dev/null
  mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_now = ON;" &> /dev/null
fi

_MYQUICK_STATUS=
if [ -x "/usr/local/bin/mydumper" ]; then
  _DB_V=$(mysql -V 2>&1 \
    | tr -d "\n" \
    | cut -d" " -f6 \
    | awk '{ print $1}' \
    | cut -d"-" -f1 \
    | awk '{ print $1}' \
    | sed "s/[\,']//g" 2>&1)
  _MD_V=$(mydumper --version 2>&1 \
    | tr -d "\n" \
    | cut -d" " -f6 \
    | awk '{ print $1}' \
    | cut -d"-" -f1 \
    | awk '{ print $1}' \
    | sed "s/[\,']//g" 2>&1)
  if [ "${_DB_V}" = "${_MD_V}" ] \
    && [ ! -e "/root/.mysql.force.legacy.backup.cnf" ]; then
    _MYQUICK_STATUS=OK
    echo "INFO: Installed MyQuick for ${_MD_V} (${_DB_V}) looks fine"
  fi
fi

if [ -e "/root/.my.pass.txt" ]; then
  _SQL_PSWD=$(cat /root/.my.pass.txt 2>&1)
  _SQL_PSWD=$(echo -n ${_SQL_PSWD} | tr -d "\n" 2>&1)
fi

for _DB in `mysql -e "show databases" -s | uniq | sort`; do
  if [ "${_DB}" != "Database" ] \
    && [ "${_DB}" != "information_schema" ] \
    && [ "${_DB}" != "performance_schema" ]; then
    check_running
    create_locks ${_DB}
    if [ "${_DB}" != "mysql" ]; then
      if [ -e "/var/lib/mysql/${_DB}/watchdog.ibd" ]; then
        _IS_GB=$(du -s -h /var/lib/mysql/${_DB}/watchdog.ibd | grep "G" 2>&1)
        if [[ "${_IS_GB}" =~ "watchdog" ]]; then
          truncate_watchdog_tables &> /dev/null
          echo "Truncated giant watchdog in ${_DB}"
        fi
      fi
      if [ -e "/var/lib/mysql/${_DB}/queue.ibd" ]; then
        _IS_GB=$(du -s -h /var/lib/mysql/${_DB}/queue.ibd | grep "G" 2>&1)
        if [[ "${_IS_GB}" =~ "queue" ]]; then
          truncate_queue_tables &> /dev/null
          echo "Truncated giant queue in ${_DB}"
        fi
      fi
      if [ -e "/var/lib/mysql/${_DB}/accesslog.ibd" ]; then
        _IS_GB=$(du -s -h /var/lib/mysql/${_DB}/accesslog.ibd | grep "G" 2>&1)
        if [[ "${_IS_GB}" =~ "accesslog" ]]; then
          truncate_accesslog_tables &> /dev/null
          echo "Truncated giant accesslog in ${_DB}"
        fi
      fi
      truncate_views_data_export &> /dev/null
      echo "Truncated not used views_data_export in ${_DB}"
      # truncate_accesslog_tables &> /dev/null
      # echo "Truncated not used accesslog in ${_DB}"
      # truncate_queue_tables &> /dev/null
      # echo "Truncated queue table in ${_DB}"
      _CACHE_CLEANUP=NONE
      if [ "${_DOW}" = "6" ] && [ -e "/root/.my.batch_innodb.cnf" ]; then
        repair_this_database &> /dev/null
        echo "Repair task for ${_DB} completed"
        truncate_cache_tables &> /dev/null
        echo "All cache tables in ${_DB} truncated"
        convert_to_innodb &> /dev/null
        echo "InnoDB conversion task for ${_DB} completed"
        _CACHE_CLEANUP=DONE
      fi
      if [ "${_OPTIM}" = "YES" ] \
        && [ "${_DOW}" = "7" ] \
        && [ "${_DOM}" -ge "24" ] \
        && [ "${_DOM}" -lt "31" ]; then
        repair_this_database &> /dev/null
        echo "Repair task for ${_DB} completed"
        truncate_cache_tables &> /dev/null
        echo "All cache tables in ${_DB} truncated"
        optimize_this_database &> /dev/null
        echo "Optimize task for ${_DB} completed"
        _CACHE_CLEANUP=DONE
      fi
      if [ "${_CACHE_CLEANUP}" != "DONE" ]; then
        truncate_cache_tables &> /dev/null
        echo "All cache tables in ${_DB} truncated"
      fi
    fi
    if [ "${_MYQUICK_STATUS}" = "OK" ]; then
      backup_this_database_with_mydumper &> /dev/null
    else
      backup_this_database_with_mysqldump &> /dev/null
    fi
    remove_locks ${_DB}
    echo "Backup completed for ${_DB}"
    echo " "
  fi
done

if [ "${_OPTIM}" = "YES" ] \
  && [ "${_DOW}" = "7" ] \
  && [ "${_DOM}" -ge "24" ] \
  && [ "${_DOM}" -lt "31" ] \
  && [ -e "/root/.my.restart_after_optimize.cnf" ] \
  && [ ! -e "/var/run/boa_run.pid" ]; then
  if [ "${_DB_SERIES}" = "10.4" ] \
    || [ "${_DB_SERIES}" = "10.3" ] \
    || [ "${_DB_SERIES}" = "10.2" ] \
    || [ "${_DB_SERIES}" = "5.7" ]; then
    check_running
    mysql -u root -e "SET GLOBAL innodb_max_dirty_pages_pct = 0;" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_change_buffering = 'none';" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_at_shutdown = 1;" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_io_capacity = 2000;" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_io_capacity_max = 4000;" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_pct = 100;" &> /dev/null
    mysql -u root -e "SET GLOBAL innodb_buffer_pool_dump_now = ON;" &> /dev/null
  fi
  bash /var/xdrago/move_sql.sh
fi

echo "MAIN TASKS COMPLETED"
rm -f /var/run/boa_sql_backup.pid
echo "CLEANUP"
_DB_BACKUPS_TTL=${_DB_BACKUPS_TTL//[^0-9]/}
if [ -z "${_DB_BACKUPS_TTL}" ]; then
  _DB_BACKUPS_TTL="7"
fi
find ${_BACKUPDIR} -mtime +${_DB_BACKUPS_TTL} -type d -exec rm -rf {} \;
echo "Backups older than ${_DB_BACKUPS_TTL} days deleted"
n=$((RANDOM%300+8))
echo "Waiting $n seconds on `date` before running compress..."
sleep $n
echo "Starting compress on `date`"
echo "COMPRESS"
compress_backup &> /dev/null
touch /var/xdrago/log/last-run-backup
echo "ALL TASKS COMPLETED"
exit 0
###EOF2021###
