#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh"

if ! is_monitoring_enabled; then
    exit 0
fi

# Check if nvidia-smi run successfully
if ! nvidia-smi -L > /dev/null 2>&1; then
    echo "nvidia-smi command failed. Do not install DCGM exporter."
    exit 0
fi

DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04"
DCGM_CONTAINER_NAME="dcgm-exporter"

install_dcgm_exporter() {
    # Check if the DCGM exporter container already exists (running or stopped)
    existing=$(docker ps -a -q --filter "name=^/${DCGM_CONTAINER_NAME}$")
    if [ -n "$existing" ]; then
        # Container exists -- ensure it is running
        if [ "$(docker inspect -f '{{.State.Running}}' "$DCGM_CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
            echo "DCGM Exporter container is already running."
        else
            echo "DCGM Exporter container exists but is stopped. Starting it."
            docker start "$DCGM_CONTAINER_NAME"
        fi
        return 0
    fi

    # Run DCGM Exporter in a new container
    docker run --name "$DCGM_CONTAINER_NAME" \
            -v $SPEC_FILE_ROOT/custom_dcgm_counters.csv:/etc/dcgm-exporter/custom-counters.csv \
            -d --gpus all --cap-add SYS_ADMIN --restart always -p 9400:9400 \
            "$DCGM_IMAGE" -f /etc/dcgm-exporter/custom-counters.csv
}

function add_scraper() {
    # If dcgm_exporter is already configured, do not add it again
    if grep -q "dcgm_exporter" $PROM_CONFIG; then
        echo "DCGM Exporter is already configured in Prometheus"
        return 0
    fi    
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/dcgm_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

install_dcgm_exporter
install_yq
add_scraper
