#!/bin/sh
# Runs on a Pi next to `zchess datagen`: pauses it (SIGSTOP) when the SoC
# reaches HIGH degrees C and resumes it (SIGCONT) once it cools to LOW, so the
# Pi never reaches its own throttling point (~80 C). Paused games just wait;
# nothing is lost. Exits when datagen exits; resumes datagen if stopped itself.
#
# usage: pi-thermal-guard.sh [high_C] [low_C]
HIGH=${1:-75}
LOW=${2:-68}
SENSOR=/sys/class/thermal/thermal_zone0/temp
state=running
paused=0
total=0
pid=""

datagen_pid() {
    pgrep -f '^[.]/zchess datagen' | head -n 1
}

trap '[ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null; echo "$(date +%T) guard stopped, datagen resumed"; exit 0' TERM INT

# Cloud VMs have no SoC sensor; there is nothing to guard.
if [ ! -r "$SENSOR" ]; then
    echo "$(date +%T) no thermal sensor ($SENSOR); guard not needed, exiting"
    exit 0
fi

echo "$(date +%T) guard started: pause at ${HIGH}C, resume at ${LOW}C"
while :; do
    pid=$(datagen_pid)
    if [ -z "$pid" ]; then
        echo "$(date +%T) datagen not running, guard exiting"
        exit 0
    fi
    t=$(( $(cat "$SENSOR") / 1000 ))
    if [ "$state" = running ] && [ "$t" -ge "$HIGH" ]; then
        kill -STOP "$pid" && state=paused && echo "$(date +%T) ${t}C >= ${HIGH}C: paused"
    elif [ "$state" = paused ] && [ "$t" -le "$LOW" ]; then
        kill -CONT "$pid" && state=running && echo "$(date +%T) ${t}C <= ${LOW}C: resumed"
    fi
    total=$((total + 5))
    [ "$state" = paused ] && paused=$((paused + 5))
    if [ $((total % 300)) -eq 0 ]; then
        echo "$(date +%T) status: ${t}C, $state, running $(( (total - paused) * 100 / total ))% of the time"
    fi
    # Background sleep + wait, so a TERM is handled immediately, not after the sleep.
    sleep 5 &
    wait $!
done
