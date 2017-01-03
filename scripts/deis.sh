#!/bin/bash

# Check to see if deis is installed, if so uninstall it.
clean_cluster() {
  kubectl get pods --namespace=deis | grep -q deis-controller
  if [ $? -eq 0 ]; then
    echo "Deis was installed so I'm removing it!"
    kubectl delete namespace "deis" &> /dev/null

    local timeout_secs=${DEFAULT_TIMEOUT_SECS:-180}
    local increment_secs=1
    local waited_time=0

    echo "Waiting for namespace to go away!"
    while [ ${waited_time} -lt "${timeout_secs}" ]; do
      kubectl get ns | grep -q deis
      if [ $? -gt 0 ]; then
        echo
        return 0
      fi

      sleep ${increment_secs}
      (( waited_time += increment_secs ))

      if [ ${waited_time} -ge "${timeout_secs}" ]; then
        echo "Namespace was never deleted"
        delete-lease
        exit 1
      fi
      echo -n . 1>&2
    done
  elif [ $? -eq 1 ]; then
    echo "Cluster already clean."
    return 0
  fi
}

deis_healthcheck() {
  wait-for-all-pods "deis"
  local successes=0
  local failures=0
  local max_attempts=10
  echo "Checking to see if the workflow has come up properly."
  while [[ ${successes} -lt "${max_attempts}" ]] && [[ ${failures} -lt "${max_attempts}" ]]; do
    wait-for-router
    if [ $? -eq 0 ]; then
      let successes+=1
    else
      let failures+=1
    fi

    if [ ${successes} -eq ${max_attempts} ]; then
      echo "Successfully interacted with Deis platform via '$(get-router-ip)' ${successes} time(s)."
    elif [ ${failures} -eq ${max_attempts} ]; then
      echo "Failed to interact with Deis platform via '$(get-router-ip)' ${failures} time(s); deleting lease and exiting."
      delete-lease
      exit 1
    fi
    sleep 1
  done
}

wait-for-all-pods() {
  echo "Waiting for all pods to be running"

  local timeout_secs=180
  local increment_secs=1
  local waited_time=0

  local command_output
  while [ ${waited_time} -lt ${timeout_secs} ]; do
    kubectl get pods --namespace=deis -o json | jq -r '.items[].status.conditions[] | select(.type=="Ready")' | grep -q "False"
    if [ $? -gt 0 ]; then
      echo
      echo "All pods are running!"
      return 0
    fi

    sleep ${increment_secs}
    (( waited_time += increment_secs ))

    if [ ${waited_time} -ge ${timeout_secs} ]; then
      echo "Not all pods started."
      kubectl get pods --namespace=deis
      delete-lease
      exit 1
    fi

    echo -n . 1>&2
  done
}

get-router-ip() {
  command_output="$(kubectl --namespace=deis get svc deis-router -o json | jq -r ".status.loadBalancer.ingress[0].ip")"
  if [ ! -z "${command_output}" ] && [ "${command_output}" != "null" ]; then
    echo "${command_output}"
  fi
}

wait-for-router() {
  local timeout_secs=30
  local increment_secs=1
  local waited_time=0
  local command_output

  while [ ${waited_time} -lt ${timeout_secs} ]; do
    router_ip="$(get-router-ip)"

    command_output="$(curl -sSL -o /dev/null -w '%{http_code}' "${router_ip}")"
    command_exit_code=$?

    if [ "${command_output}" == "404" ]; then
      return 0
    fi

    sleep ${increment_secs}
    (( waited_time += increment_secs ))

    if [ ${waited_time} -ge ${timeout_secs} ]; then
      echo "Endpoint is unresponsive at ${router_ip}"
      delete-lease
      exit 1
    fi

    echo -n . 1>&2
    return ${command_exit_code}
  done
}

get-pod-logs() {
  pods=$(kubectl get pods --all-namespaces | sed '1d' | awk '{print $1, $2}')
  while read -r namespace pod; do
    kubectl logs "${pod}" --namespace="${namespace}" >> "${DEIS_LOG_DIR}/${namespace}-${pod}.log"
    kubectl logs "${pod}" -p --namespace="${namespace}" >> "${DEIS_LOG_DIR}/${namespace}-${pod}-previous.log"
  done <<< "$pods"
}
