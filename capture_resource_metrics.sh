#!/bin/bash
#
# PREREQUISITES
# - jq
# - oc (logged in at the cmd line in order to get the bearer token)
# - a "perf-test-start-time.txt" file with a valid rfc3339 timestamp from a moment before performance tests started 
#   (it can be produced with this multiplatform command: `date -u +%Y-%m-%dT%TZ > perf-test-start-time.txt`)
# - a "perf-test-end-time.txt" file with a valid rfc3339 timestamp from a moment after performance tests finished
#
# VARIABLES
START_TIME_FILENAME=${START_TIME_FILENAME:-perf-test-start-time.txt}
END_TIME_FILENAME=${END_TIME_FILENAME:-perf-test-end-time.txt}
TOKEN=$(oc whoami --show-token)
LOCALHOST_QUERY="localhost:9090/api/v1/query"

# Get timestamps and calculate test duration
startTime=$(cat $START_TIME_FILENAME)
if [[ "$OSTYPE" == "darwin"* ]]; then
  # MacOS command:
  startTimestamp=$(date -u -j -f "%Y-%m-%dT%TZ" "$startTime" +"%s")
else
  # Linux command:
  startTimestamp=$(date -u -d "$startTime" +"%s")
fi

endTime=$(cat $END_TIME_FILENAME)
if [[ "$OSTYPE" == "darwin"* ]]; then
  # MacOS command:
  endTimestamp=$(date -u -j -f "%Y-%m-%dT%TZ" "$endTime" +"%s")
else
  # Linux command:
  endTimestamp=$(date -u -d "$endTime" +"%s")
fi
testDuration=$(($endTimestamp-$startTimestamp))

# Order of the queries must strictly match the rows from the spreadsheet that is used to collect these data
INSTANT_QUERIES=(\
  "sum(cluster:capacity_cpu_cores:sum)"\
  "sum(cluster:capacity_cpu_cores:sum{label_node_role_kubernetes_io!~'master|infra'})"\
  "sum(kube_node_status_allocatable{resource='cpu'} * on (node) (kube_node_role{role='worker'} == on (node) group_left () (count by (node) (kube_node_role{}))))"\
  "sum(cluster:capacity_memory_bytes:sum)/1024/1024/1024"\
  "sum(cluster:capacity_memory_bytes:sum{label_node_role_kubernetes_io!~'master|infra'})/1024/1024/1024"\
  "sum(kube_node_status_allocatable{resource='memory'} * on (node) (kube_node_role{role='worker'} == on (node) group_left () (count by (node) (kube_node_role{}))) / 1024 / 1024 / 1024)"\
  "sum(kube_pod_container_resource_requests{namespace=~'3scale-test',container!='lifecycle',resource='cpu'} * on(namespace, pod) group_left() max by (namespace, pod) ( kube_pod_status_phase{phase='Running'} == 1 ))"\
  "sum(kube_pod_container_resource_requests{namespace=~'3scale-test', container!='lifecycle',resource='memory'} * on(namespace, pod) group_left() max by (namespace, pod) ( kube_pod_status_phase{phase='Running'} == 1 )) / 1024 /1024"\
)



# Order of the queries must strictly match the rows from the spreadsheet that is used to collect these data
IDLE_QUERIES=(\
  "avg_over_time(sum(container_memory_working_set_bytes{namespace='3scale-test', pod!='', container=''}) [15m:10s])/1024/1024"\
  "avg_over_time(namespace:container_cpu_usage:sum{namespace='3scale-test'} [15m])"\
  "sum(avg_over_time(namespace:container_cpu_usage:sum{namespace=~'3scale-test'} [15m]))"\
)

# Order of the queries must strictly match the rows from the spreadsheet that is used to collect these data
LOAD_QUERIES=(\
  "max_over_time(sum(container_memory_working_set_bytes{namespace='3scale-test',container='', pod!=''}) [${testDuration}s:10s])/1024/1024"\
  "max_over_time(namespace:container_cpu_usage:sum{namespace='3scale-test'} [${testDuration}s])"\
  "sum(max_over_time(namespace:container_cpu_usage:sum{namespace=~'3scale-test'} [${testDuration}s]))"\
)

_runQueryROO() {
   oc exec -n 3scale-test prometheus-example-0 -- curl -s -X POST -H "Accept: application/json" -H "Authorization: Bearer $TOKEN" -d "query=$1&time=$2" $3 -k | jq -r ".data.result[0].value[1]"
   curl -s -X POST \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=$1" \
    --data-urlencode "time=$2" \
    --insecure \
    $3 | jq -r ".data.result[0].value[1]"

}

_runQueryOM() {
  oc exec -n openshift-monitoring prometheus-k8s-0 -- curl -s -H "Authorization: Bearer $TOKEN" --data-urlencode "query=$1" --data-urlencode "time=$2"  -H 'Accept: application/json' $3 | jq -r ".data.result[0].value[1]"
}

runQuery() {
  result=$( _runQueryOM "$1" "$2" "$LOCALHOST_QUERY")
  if [[ "$result" == "null" ]]; then
    result=$( _runQueryROO "$1" "$2" "$LOCALHOST_QUERY")
  fi
  echo "$result"
}

#
# Execute queries
#
for query in "${INSTANT_QUERIES[@]}";
do
  runQuery "$query" "$endTime"
done

for query in "${IDLE_QUERIES[@]}";
do
  runQuery "$query" "$startTime"
done

for query in "${LOAD_QUERIES[@]}";
do
  runQuery "$query" "$endTime"
done