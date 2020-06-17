#!/bin/bash

set -e
set -u
set -o pipefail

exec 3>&1
exec 4>&2

function special_echo() {
  echo "$@" >&3
}

function special_errecho() {
  echo "$@" >&4
}

function usage() { 
  special_errecho "Usage: $0 OPTIONS"
  special_errecho "  -a path to config file for agents"
  special_errecho "  -b path to script to execute before we start consul"
  special_errecho "  -c domain"
  special_errecho "  -d number of datacenters to spin up and wan-join together"
  special_errecho "  -e path to example"
  special_errecho "  -f number of network segments to spin up"
  special_errecho "  -h show this help"
  special_errecho "  -l log level (defaults to info)"
  special_errecho "  -m number of clients (defaults to 5)"
  special_errecho "  -n number of servers (defaults to 3)"
  special_errecho "  -p dc prefix (defaults to dc)"
  special_errecho "  -s path to config file for servers"
  special_errecho "  -v list of non-voting servers"
  special_errecho "  -w no wan-join"
  special_errecho "  -x path to script to execute after the cluster is up, must be executable"
  special_errecho "  -y start server"
  special_errecho "  -z start client"
  special_errecho ""
  special_errecho "Examples:"
  special_errecho '  `./boot.sh` # boots 3 servers and 5 clients'
  special_errecho '  `./boot.sh -e examples/auto_encrypt` # boots auto_encrypt setup'
  special_errecho '  `./boot.sh -n 5 -m 20` # boots 5 servers and 20 clients'
  special_errecho '  `./boot.sh -n 5 -m 20 -d 3` # boots 5 servers and 20 clients each in dc1, dc2, and dc3 wan-joined together.'
  exit 1
}

while getopts ":a:b:c:d:f:e:hl:m:n:p:s:v:w:x:y:z:" o; do
  case "${o}" in
    a)
      a=${OPTARG}
      ;;
    b)
      b=${OPTARG}
      ;;
    c)
      c=${OPTARG}
      ;;
    d)
      d=${OPTARG}
      ;;
    e)
      e=${OPTARG}
      ;;
    f)
      f=${OPTARG}
      ;;
    l)
      l=${OPTARG}
      ;;
    m)
      m=${OPTARG}
      ;;
    n)
      n=${OPTARG}
      ;;
    p)
      p=${OPTARG}
      ;;
    s)
      s=${OPTARG}
      ;;
    v)
      v=${OPTARG}
      ;;
    w)
      w=1
      ;;
    x)
      x=${OPTARG}
      ;;
    y)
      y=${OPTARG}
      ;;
    z)
      z=${OPTARG}
      ;;
    h)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

l=${l:-"info"}
b=${b:-""}
c=${c:-"consul"}
m=${m:-"5"}
n=${n:-"3"}
o=${o:-"3"}
e=${e:-"."}
e=${e%/}
echo "{}">dummy.json
d=${d:-"1"}
f=${f:-""}
p=${p:-"dc"}
v=${v:-""}
x=${x:-""}
y=${y:-""}
z=${z:-""}

portFile="$TMPDIR"localclusterLastUsedPort
lockFile="$TMPDIR"localclusterLock
clusterFile="$TMPDIR"localclusterCluster

function clientConfig() {
  if [ -n "${a-}" ]; then
    echo $a
    return
  fi
  local dc="$1"
  local id="$2"
  if [ -f "$e/client_${dc}_${id}.json" ]; then
    echo "$e/client_${dc}_${id}.json"
    return
  fi
  if [ -f "$e/client_$dc.json" ]; then
    echo "$e/client_$dc.json"
    return
  fi
  if [ -f "$e/client.json" ]; then
    echo "$e/client.json"
    return
  fi
  echo "dummy.json"
}

function serverConfig() {
  if [ -n "${s-}" ]; then
    echo $s
    return
  fi
  local dc="$1"
  local id="$2"
  if [ -f "$e/server_${dc}_${id}.json" ]; then
	  echo "$e/server_${dc}_${id}.json"
    return
  fi
  if [ -f "$e/server_$dc.json" ]; then
    echo "$e/server_$dc.json"
    return
  fi
  if [ -f "$e/server.json" ]; then
    echo "$e/server.json"
    return
  fi
  echo "dummy.json"
}

function checkIfConsulIsRunningAlready() {
  if pgrep consul; then
    special_echo "consul is already running"
    exit 1
  fi
}

function knownServerPort() {
  let "port = 8100 + $1"
  echo $port
}

function joinPort() {
  let "port = 8300 + $1"
  echo $port
}

function knownHttpPort() {
  let "http = 8499 + $1"
  echo $http
}

function freePort() {
  set +o xtrace
  ./incr.pl "$lockFile" "$portFile"
  set -o xtrace
}

function addLine() {
  set +o xtrace
  ./cluster.pl "$lockFile" "$clusterFile" "$1"
  set -o xtrace
}

function addAgent() {
  addLine "\"$2.$1\": {\"dc\": \"$1\", \"id\": \"$2\", \"http_port\": $3, \"https_port\": $4, \"server_port\": $5, \"mode\": \"$6\", \"address\": \"localhost:$3\"},"
}

function httpsPortConfig(){
  echo "ports { https = $1 }"
}

function segmentsConfig(){
  if [ -n "$f" ]; then
    local result="segments = ["
    for i in $(seq $f); do
      local port=$(freePort)
      result="$result { name = \"segment$i\", port = $port },"
    done
    echo "${result%?} ]"
  fi
}

function consulVersion() {
  echo $(consul version | head -1 | awk '{print $2}')
}

function startWellKnownServer() {
  local dc="$p$1"
  local id="s1"
  local data="$dc-$id"
  local serf=$(joinPort $1)
  local http=$2
  local https=$3
  local server=$4
  let "wan = 8700 + $1"
  local dns="-1"
  local config=$(serverConfig $dc $id)
  local hcl=$(httpsPortConfig $https) $(segmentsConfig)

  rm -rf "$data"
  special_echo "$dc well known server HTTP: 127.0.0.1:$http"
  set -o xtrace
  if [ -n "${w:-""}" ]; then
	  consul agent -ui -http-port "$http" -grpc-port $(freePort) -server -bootstrap-expect $n -data-dir "$data" -bind 127.0.0.1 -node $id -serf-lan-port "$serf" -serf-wan-port "$wan" -dns-port "$dns" -server-port $server -log-level $l -config-file $config -datacenter $dc -domain $c -hcl "$hcl"
  else
	  consul agent -ui -http-port "$http" -grpc-port $(freePort) -server -bootstrap-expect $n -data-dir "$data" -bind 127.0.0.1 -node $id -serf-lan-port "$serf" -serf-wan-port "$wan" -dns-port "$dns" -server-port $server -log-level $l -config-file $config -datacenter $dc -domain $c -retry-join-wan "127.0.0.1:8701" -hcl "$hcl"
  fi
}

function startServer() {
  local dc="$p$1"
  local id="s$2"
  local data="$dc-$id"
  local join=$(joinPort $1)
  local config=$(serverConfig $dc $id)

  local http=$3
  local https=$4
  local server=$5

  local hcl=$(httpsPortConfig $https) $(segmentsConfig)

  rm -rf "$data"
  set -o xtrace
  if [ -n "${w:-""}" ]; then
	  consul agent -ui -http-port $http -grpc-port $(freePort) -server -bootstrap-expect $n -retry-join "127.0.0.1:$join" -data-dir "$data" -bind 127.0.0.1 -node "$id" -serf-lan-port $(freePort) -serf-wan-port $(freePort) -dns-port $(freePort) -server-port $server -log-level $l -config-file $config -datacenter $dc -domain $c -hcl "$hcl"
  elif [[ $v == *"$data"* ]]; then
	  consul agent -ui -http-port $http -grpc-port $(freePort) -server -bootstrap-expect $n -retry-join "127.0.0.1:$join" -data-dir "$data" -bind 127.0.0.1 -node "$id" -serf-lan-port $(freePort) -serf-wan-port $(freePort) -dns-port $(freePort) -server-port $server -log-level $l -config-file $config -datacenter $dc -domain $c -retry-join-wan "127.0.0.1:8701" -non-voting-server -hcl "$hcl"
  else
	  consul agent -ui -http-port $http -grpc-port $(freePort) -server -bootstrap-expect $n -retry-join "127.0.0.1:$join" -data-dir "$data" -bind 127.0.0.1 -node "$id" -serf-lan-port $(freePort) -serf-wan-port $(freePort) -dns-port $(freePort) -server-port $server -log-level $l -config-file $config -datacenter $dc -domain $c -retry-join-wan "127.0.0.1:8701" -hcl "$hcl"
  fi
}

function startClient() {
  local dc="$p$1"
  local id="c$2"
  local data="$dc-$id"
  local knownServer=$(knownServerPort $1)
  local serf=$(freePort)
  local http=$3
  local https=$4
  local dns=$(freePort)
  local join=$(joinPort $1)
  local config=$(clientConfig $dc $id)
  local hcl=$(httpsPortConfig $https)
  rm -rf "$data"
  set -o xtrace

  consul agent -ui -http-port $http -grpc-port $(freePort) -retry-join "127.0.0.1:$join" -data-dir "$data" -bind 127.0.0.1 -node "$id" -serf-lan-port $(freePort) -serf-wan-port -1 -dns-port $(freePort) -log-level $l -config-file $config -datacenter $dc -domain $c -server-port $knownServer -hcl "$hcl"
}

function waitUntilClusterIsUp() {
  local up='false'
  let "total = $1 + $2"
  for i in $(seq $d); do
    local dc="$p$i"
    local port=$(knownHttpPort $i)
    while true; do
      set +e
      leader=$(curl -H "X-Consul-Token: $(jq -r '.bootstrap_token' cluster.json)" -s "localhost:$port/v1/agent/self" | jq -r '.Stats.consul.leader_addr')
      set -e
      if [ "$leader" != "" ]; then
        special_echo "$dc has leader"
        break
      fi
      sleep 2
    done
    while true; do
      set +e
      count=$(curl -H "X-Consul-Token: $(jq -r '.bootstrap_token' cluster.json)" -s "localhost:$port/v1/agent/members?dc=$dc" | jq '. | length')
      set -e
      if [ "$count" = "$total" ]; then
        special_echo "$dc members alive"
        break
      fi
      sleep 2
    done
    sleep 2
  done
  special_echo "cluster is up"
}

function aclBootstrap() {
  set +e
  # dc1 is hardcoded here.
  # TODO make dynamic
  enabled=$(jq '.acl.enabled' $(serverConfig dc1 1))
  if [ "$enabled" = "true" ]; then
    while true; do
      out=$(consul acl bootstrap)
      res=$?
      if [ $res -eq 0 ]; then
        secret=$(echo $out | grep SecretID | awk '{print $4}')
        special_echo "ACL bootstrap token: $secret"
        jq ". + {bootstrap_token: \"$secret\"}" cluster.json > cluster_new.json
        mv cluster_new.json cluster.json
        break
      fi
      sleep 2
    done
  fi
  set -e
}

function writeClusterJson() {
  # +1 for the first line that is a newline
  let "total = $d * ($1 + $2) + 1"
  while true; do
    set +e
    count=$(cat "$clusterFile" | wc -l)
    if [ $count -eq $total ]; then
      lines=$(cat "$clusterFile" | sed '$s/.$//')
      echo "{\"servers\": {${lines}}, \"vault_token\": \"$(cat vault.token)\"}" > cluster.json
      special_echo "wrote cluster.json"
      break
    fi
    sleep 5
  done
  set -e
}

function execScript() {
  status=0
  if [ -n "${1-}" ]; then
    special_echo "running $1"
    set +e
    out=$($1)
    status=$?
    set -e
    special_echo "$out"
  fi
  if [ -f "$e/$2" ]; then
    special_echo "running $e/$2"
    set +e
    out=$($e/$2)
    status=$?
    set -e
    special_echo "$out"
  fi
  # return $status
}

trap 'killall' INT

killall() {
  # ignore INT and TERM while shutting down
  trap '' INT TERM
  special_echo "Shutting down..."
  kill -TERM 0
  wait
}

if [ -n "$y" ] && [ -n "$z" ]; then
        http=$(freePort)
        server=$(freePort)
	fields=(${y//;/ })
	startServer ${fields[0]} ${fields[1]} $http $server &
elif [ -n "$z" ]; then
        http=$(freePort)
	fields=(${z//;/ })
	startClient ${fields[0]} ${fields[1]} $http &
else

	rm -f out.log

	exec &> out.log

	checkIfConsulIsRunningAlready

	echo 9999 > $portFile
	echo "" > $clusterFile
	echo "{}" > cluster.json

	if [ -f "$e/args" ]; then
		eval $(cat $e/args)
	fi

        execScript "$b" "before"

	for (( i=1; i<=$d; i++ )); do
	  dc=$p$i
	  http=$(knownHttpPort $i)
	  https=$(freePort)
          server=$(knownServerPort $i)
	  startWellKnownServer $i $http $https $server &
	  addAgent $dc s1 $http $https $server "server"

	  for (( j=2; j<=$n; j++ )); do
	    http=$(freePort)
	    https=$(freePort)
	    server=$(freePort)
	    startServer $i $j $http $https $server &
	    addAgent $dc s$j $http $https $server "server"
	  done

	  for (( j=1; j<=$m; j++ )); do
	    http=$(freePort)
	    https=$(freePort)
	    startClient $i $j $http $https &
	    addAgent $dc c$j $http $https 0 "client"
	  done
	done

	writeClusterJson $n $m
	aclBootstrap
	waitUntilClusterIsUp $n $m

        execScript "$x" "after"
fi

cat # wait forever
