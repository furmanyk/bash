#!/usr/bin/env bash
#===============================================================================
#
#          FILE:  history_protection.sh
#
#         USAGE:  ./history_protection.sh
#
#   DESCRIPTION:
#
#       OPTIONS:  ---
#  REQUIREMENTS:  xxd, diff, sed, awk, logger, timeout, file, date, mail
#          BUGS:  ---
#         NOTES:  ---
#        AUTHOR: Furmanyuk Evgeniy (),
#       LICENCE: Copyright (c) 2017
#       COMPANY:
#       CREATED: 02/15/2017 04:52:37 PM MSK
#      REVISION:  ---
#===============================================================================

set -o nounset

# время отведенное на сохранение истории
TIMEOUT=10
# максимальное кол-во изменений
MAX_DIFF=24

#===============================================================================
# Start block functions
#
function isTextFile {
  # получаем тип файла application для бинарных или text для текстовых
  FTYPE=`file --mime --brief ${1} | sed "s|/.*$||g"`
  if [ "${FTYPE}" == "text" ]; then
    return 0
  fi
  return 1
}

function prepareDiff {
  FILE=$1   # оригинальный файл
  ETALON=$2 # предыдущая копия
  DIFF=$3   # куда сохранять историю

  # проверяем наличие файла
  test -f ${FILE}  || err "Error: ${FILE} not found or inaccessible"
  # проверяем наличие директории для хранения истории
  test -d ${DIFF} || err "Error: ${DIFF} not found or is not directory"
  # проверяем наличие эталонного-файла
  if [ ! -f ${ETALON} ]; then
    # не нашли - создаем
    timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} cp ${FILE} ${ETALON} &> /dev/null || err "Error: can't copy to ${ETALON}"

    log "First run - init etalon"
    exit 0
  fi
}

function processDiff {
  FILE=$1    # оригинальный файл
  ETALON=$2  # предыдущая копия
  PREDIFF=$3 # начало имени файла истории

  # timestamp как постфикс для файлов истории
  CTIME=`date +%s`
  DIFF_FILE="${PREDIFF}.${CTIME}"
  # lock-файл для гарантии целостности
  DIFF_LOCK="${PREDIFF}.lock"

  # проверяем наличие lock-файла и создаем его
  test -f ${DIFF_LOCK} && err "Error: somebody already processing diff, found lock - ${DIFF_LOCK}"
  touch ${DIFF_LOCK}
  # снимаем историю
  if isTextFile ${FILE}; then
    timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} diff -u ${FILE} ${ETALON} > ${DIFF_FILE}
  else
    # если файл бинарный то историю сохраняем в виде hex dump'a
    timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} diff <(xxd ${FILE}) <(xxd ${ETALON}) > ${DIFF_FILE}
  fi

  RET=$?
  # если изменений не было, то удаляем файл
  if [ ${RET} -eq 0 ]; then
    rm -f ${DIFF_FILE}
  # если timeout не дождался завершения diff'a
  elif [ ${RET} -eq 124 ]; then
    rm -f ${DIFF_FILE}
    err "Error: reach timeout ${TIMEOUT}"
  # если diff успешно выполняется то retcode==1
  elif [ ${RET} -eq 1 ]; then
    log "Success get diff from file"
    # обновляем TIMEOUT - нам нужно чтобы в сумме время не было больше TIMEOUT
    if [ $((TIMEOUT-(`date +%s`-CTIME))) -gt 0 ]; then
      TIMEOUT=$((TIMEOUT-(`date +%s`-CTIME)))
    fi
    # если diff сняли, то обновляем эталонный файл
    timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} cp ${FILE} ${ETALON} &> /dev/null
    RET=$?
    if [ ${RET} -eq 0 ]; then
      log "Update etalon file"
    elif [ ${RET} -eq 124 ]; then
      # эталонный файл побит, вариантов кроме как удалить больше никаких
      rm -f ${DIFF_FILE} ${ETALON}
      err "Error: reach timeout ${TIMEOUT} while update etalon file"
    else
      # cp могли убить или может кончиться место
      rm -f ${DIFF_FILE} ${ETALON}
      err "Error: cant update file ${ETALON}"
    fi
  else
    rm -f ${DIFF_FILE}
    err "Error: cant get diff - unknown error"
  fi
  # удаляем lock-файл
  rm -f ${DIFF_LOCK}
}

function rotateDiff {
  PREDIFF=$1
  # листим все файлы , и если файлов больше чем MAX_DIFF то уадляем самый старый
  # если это сетевая директория, например NFS, то листинг может уйти за пределы допустимого времени, поэтому
  # запускаем через timeout
  DIFF_DEL=`timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} ls -at1 ${PREDIFF}\.[0-9]* 2> /dev/null | awk 'END { if (FNR > '$((MAX_DIFF-1))' ) print}'`
  rm -f ${DIFF_DEL}
}

function mayIStart {
  # проверяем наличие всех необходимых утилит
  for UTIL in logger awk xxd diff timeout sed file date mail
  do
    ${UTIL} --version &>/dev/null || { echo >&2 "[$(date)] Error: ${UTIL} not found, exiting." ; exit 1;  }
  done

  PREDIFF=$1
  # выбираем последний измененный файл
  DIFF_LAST=`timeout --kill-after=$((TIMEOUT+1)) ${TIMEOUT} ls -at1 ${PREDIFF}\.[0-9]* 2> /dev/null | head -1`
  # выцепляем timestamp создания файла из постфикса в имени файла
  PTIME=`echo ${DIFF_LAST} | sed s/'.*\.'//g`
  # если прошло меньше 60 секунд выходим
  if [ $((`date +%s` - PTIME)) -lt 60 ]; then
    # не пишем в log чтобы не заспамить syslog
    exit 0
  fi
}

function log {
  # логируем сообщение в syslog
  logger --priority=info  --tag="`basename $0`" "$@"
}

function err {
  # пишем в syslog
  logger --priority=error --tag="`basename $0`" "$@"
  # и если есть настройка то юзеру
  if [ !  -z ${MAIL_USER}  ]; then
    echo "$@" | mail -s "Error process `basename $0`" ${MAIL_USER}
  fi
  exit 2
}

function printHelp {

  echo "Usage: $0 -f file"
  echo ""
  echo "Save the history of file changes. Ignore when passed less 60s before changes."
  echo "Create only 24 copies, more than remove oldest."
  echo "For history creates a \"standard\"-file."
  echo ""
  echo "-f absolute or relative path watching file"
  echo "-m mail user"
  echo "-p path to save history files"
  echo "-d prefix for history files"
  echo "-e prefix for \"standard\"-file"
  echo ""

}
#
# End block functions
#===============================================================================

# проверка уникальности процесса
for pid in $(pidof -x `basename $0`); do
    if [ ${pid} != $$ ]; then
        echo >&2 "[$(date)] : $0 : Process is already running with PID ${pid}"
        exit 1
    fi
done


# файл для снятия истории
WATCH_FILE="test.txt"
# пользователь, кому пишем письмо в случае ошибок
# по умолчанию: отсутствует
MAIL_USER=""
# путь для хранения слепков истории и эталонного файла
# по умолчанию: сохраются в директорию с файлом
DIFF_PATH="/tmp"
# префикс для файлов истории
# по умолчанию .diff_
DIFF_PREF=".diff_"
# префикс для предыдущей копии файла
# хранится совместно с файлами истории
ETALON_PREF=".etalon_"

while getopts "f:m:p:d:e:h" opt "$@"
do
  case ${opt} in
    h) printHelp; exit 4; ;;
    f) WATCH_FILE=${OPTARG};;
    m) MAIL_USER=${OPTARG} ;;
    p) DIFF_PATH=${OPTARG} ;;
    d) DIFF_PREF=${OPTARG} ;;
    e) ETALON_PREF=${OPTARG} ;;
    *) echo >&2 "Unknown options"; exit 3; ;;
  esac
done

# формируем путь эталонный файл
ETALON_FILE="${DIFF_PATH}/${ETALON_PREF}`basename ${WATCH_FILE}`"
# где будет распологаться файл истории
PREDIFF=${DIFF_PATH}/${DIFF_PREF}`basename ${FILE}`

# проверяем все ли условия выполнены для продолжения выполнения
mayIStart   ${PREDIFF}
# делаем все необходимые подготовки, такие как проверка наличия эталонного файла
prepareDiff ${WATCH_FILE} ${ETALON_FILE} ${DIFF_PATH}
# удаляем старые если файлов истории больше чем ${MAX_DIFF}
rotateDiff  ${PREDIFF}
processDiff ${WATCH_FILE} ${ETALON_FILE} ${PREDIFF}


