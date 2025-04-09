#!/bin/bash

# heads up: dev-scripts cluster do not provide a https redfish endpoint,
# but fence_redfish is hardcoded to use https
#
# you can patch the cluster with:
# - on the server, cd to the dev-scripts working dir (default: /opt/dev-scripts)
# - cd virtualbmc/sushy-tools
# - create a certificate: openssl req -nodes -newkey rsa:2048 -x509 -keyout key.pem -out cert.pem -days 365
# - patch conf.py:
#     echo 'SUSHY_EMULATOR_SSL_KEY = "/root/sushy/key.pem"' >> conf.py
#     echo 'SUSHY_EMULATOR_SSL_CERT = "/root/sushy/cert.pem"' >> conf.py
# - restart the sushy-tools podman container

set -euxo pipefail

echo "call this from project root!"
echo "kubeconfig must be configured!"
echo "some steps are specific to dev-scripts clusters (e.g. node names...)"

#node2remove=master-2
#
#remove_etcdc_member() {
#  # remove 3rd node from etcd member list
#  echo "removing 3rd node from etcd member list"
#  etcd_pod=etcd-master-0
#  etcdid=$(oc exec -n openshift-etcd "$etcd_pod" --quiet -- etcdctl member list | awk -v name="$node2remove" '$3 ~ name {gsub(",", "", $1); print $1}')
#  oc exec -n openshift-etcd "$etcd_pod" -- etcdctl member remove "$etcdid"
#}
#
#delete_machine() {
#  echo "deleting 3rd machine, this will deprovision the BMH and delete the node as well"
#  echo "this will take a while..."
#  machine=$(oc get machine -A -o name | grep "$node2remove")
#  oc -n openshift-machine-api delete "$machine"
#}

configureSecret() {

  ns=openshift-machine-api

  machines=$(oc -n $ns get machines -o name)

  nodes=()
  ips=()
  urls=()
  users=()
  pwds=()

  # get data for each host
  for machine in ${machines}; do
    bmhWns=$(oc -n $ns get $machine -o yaml | yq '.metadata.annotations."metal3.io/BareMetalHost"')
    splitted=(${bmhWns//\// })
    bmh=${splitted[1]}
    node=$(oc -n $ns get bmh $bmh -o yaml | yq .status.hardware.hostname)
    nodes+=($node)
    ips+=($(oc -n $ns get node $node -o yaml | yq '.status.addresses[] | select(.type == "InternalIP") | .address'))
    httpUrl=$(oc -n $ns get bmh $bmh -o yaml | yq .spec.bmc.address)
    httpsUrl=${httpUrl//http:/https:}
    urls+=("${httpsUrl}")
    secretName=$(oc -n $ns get bmh $bmh -o yaml | yq .spec.bmc.credentialsName)
    users+=($(oc -n $ns get secrets $secretName -o yaml | yq -r .data.username | base64 -d))
    pwds+=($(oc -n $ns get secrets $secretName -o yaml | yq -r .data.password | base64 -d))
  done

  # debugging...
  echo ${nodes[*]}
  echo ${ips[*]}
  echo ${urls[*]}
  echo ${users[*]}
  echo ${pwds[*]}

  # create fenceing credentials secret
  credsfile=hack/tnf-tmp/fencingCredentials.yaml
  secretfile=hack/tnf-tmp/fencingCredentialsSecret.yaml

  echo "" | \
  yq ".${nodes[0]}.address = \"${urls[0]}\"" | \
  yq ".${nodes[0]}.username = \"${users[0]}\"" | \
  yq ".${nodes[0]}.password = \"${pwds[0]}\"" | \
  yq ".${nodes[0]}.sslInsecure = true" | \
  yq ".${nodes[1]}.address = \"${urls[1]}\"" | \
  yq ".${nodes[1]}.username = \"${users[1]}\"" | \
  yq ".${nodes[1]}.password = \"${pwds[1]}\"" | \
  yq ".${nodes[1]}.sslInsecure = true" \
    >  $credsfile

  data=$(cat $credsfile)

  yq 'del(.stringData)' ${secretfile}.in | \
  yq ".stringData.\"config.yaml\" = \"$data\"" \
    >  $secretfile

  echo "applying secret with BMC config"
  tnf_ns=openshift-etcd
  oc -n $tnf_ns apply -f $secretfile

}

configureMachineConfig() {

  # create machine config

  ns=openshift-machine-api

  machines=$(oc -n $ns get machines -o name)

  nodes=()
  ips=()

  # get data for each host
  for machine in ${machines}; do
    bmhWns=$(oc -n $ns get $machine -o yaml | yq '.metadata.annotations."metal3.io/BareMetalHost"')
    splitted=(${bmhWns//\// })
    bmh=${splitted[1]}
    node=$(oc -n $ns get bmh $bmh -o yaml | yq .status.hardware.hostname)
    nodes+=($node)
    ips+=($(oc -n $ns get node $node -o yaml | yq '.status.addresses[] | select(.type == "InternalIP") | .address'))
  done

  # debugging...
  echo ${nodes[*]}
  echo ${ips[*]}
  echo ${urls[*]}
  echo ${users[*]}
  echo ${pwds[*]}


  export PULL_SECRET=$(oc -n openshift-config get secret pull-secret -o yaml | yq '.data.".dockerconfigjson"')
  export TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
  export NODE1=${nodes[0]}
  export IP1=${ips[0]}
  export NODE2=${nodes[1]}
  export IP2=${ips[1]}

#  export SYSTEMCTL_AGENT=$(cat hack/tnf-tmp/systemctl | base64 -w 0)
#  export PODMAN_ETCD_AGENT=$(cat hack/tnf-tmp/podman-etcd | base64 -w 0)

  mcfile=hack/tnf-tmp/machineConfig.yaml
  cat "${mcfile}.in" | envsubst > "${mcfile}"

  echo "applying machineconfig with fencing prerequisites"
  echo "this will trigger node restarts, monitor the machineconfig pool for status updates"
  oc apply -f $mcfile

}

patchceo() {
  echo "Unmanage CEO"
  oc patch clusterversion/version --type='merge' -p "$(cat <<- EOF
spec:
  overrides:
  - group: apps
    kind: Deployment
    name: etcd-operator
    namespace: openshift-etcd-operator
    unmanaged: true
EOF
)"

  oc patch deployment etcd-operator -n openshift-etcd-operator --type=json -p='[
    {"op": "replace", "path": "/spec/template/spec/containers/0/env/1/value", "value": "quay.io/slintes/ceo:latest"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/slintes/ceo:latest"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}
  ]'

}

# execute one step after another
# TODO automate this by checking results...
# NOT NEEDED ANYMORE remove_etcdc_member
# NOT NEEDED ANYMORE delete_machine

#configureSecret
configureMachineConfig
#patchceo

