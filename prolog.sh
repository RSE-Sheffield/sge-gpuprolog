#!/bin/bash
#
# Authors: Mozhgan Kabiri Chimeh, Paul Richmond, Will Furnass
# Contact: w.furnass@sheffield.ac.uk
#
# Sun Grid Engine prolog script to allocate GPU devices.
# Based on https://github.com/kyamagu/sge-gpuprolog

exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/tmp/prolog.$$.out 2>&1

set -e

# Ensure various SGE env vars are set
source /etc/profile.d/SoGE.sh
# Ensure SGE_GPU_LOCKS_DIR env var is set
source /etc/profile.d/sge_gpu_locks.sh

echo testing > /tmp/test.out

SGE_GROUP="$(/usr/bin/awk -F'=' '/^add_grp_id/{print $2}' "${SGE_JOB_SPOOL_DIR}/config")"

# Query how many gpus to allocate (for serial process or per SMP or MPI slot)
NGPUS="$(qstat -j "$JOB_ID" | sed -n "s/hard resource_list:.*gpu=\([[:digit:]]\+\).*/\1/p")" || true

# Exit if NGPUs is null or <= 0
[[ -z $NGPUS || $NGPUS -le 0 ]] && exit 0

# Scale GPUs with number of requested cores if using the 'smp' Grid Engine Parallel Environment
# (as the current scheduler configuration is for the 'gpu' countable complex consumable 
# to scale with the number of requested slots)
if [[ -n $PE && $PE == 'smp' && -n $NSLOTS && NSLOTS -gt 1 ]]; then
    NGPUS=$(( NGPUS * NSLOTS ))
fi

#CGROUP="/sge/${JOB_ID}.${SGE_TASK_ID/undefined/1}"

# Get a list of all device indexes (minor version of character devices)
# (NB we don't use nvidia-smi as it is slow)
declare -a all_dev_idxs=()
mapfile -t all_dev_idxs < <(stat -c %T /dev/nvidia[0-9]*)

# Allocate and lock GPUs. We will populate claimed_dev_idxs with the device indexes that the job should use.
declare -a claimed_dev_idxs=()

#cgcreate -a sge -t sge -g devices:$CGROUP
#lscgroup | grep $JOB_ID > /tmp/prolog.log

# Loop through the device IDs and check to see if a lock can be obtained for the device
for i in "${all_dev_idxs[@]}"; do
  if [[ ${#claimed_dev_idxs[@]} -ge $NGPUS ]]; then
      #cgset -r devices.deny="c 195:$i rw" $CGROUP
      continue
  fi

  # Lock directory is specific for each ShARC node and each device combination
  lockdir="${SGE_GPU_LOCKS_DIR}/lock_device_${i}"

  # Use 'mkdir' to obtain a lock (will fail if directory exists)
  # provided that we haven't yet locked enough GPUs
      
  if mkdir "$lockdir" &> /dev/null; then 
    # We have obtained a lock so can have exclusive access to this GPU idx.
    claimed_dev_idxs+=("$i")

    # Modify the job-specific cgroup to allow r+w access to the device from this job
    #cgset -r devices.allow="c 195:$i rw" $CGROUP

    # Set group permissions on the device node to allow for access
    # from the SGE group associated with this job
    sudo ./nvchgrp "${SGE_GROUP}" "$i"
  else
    # Deny access from this job
    #cgset -r devices.deny="c 195:$i rw" $CGROUP
    echo
  fi
done

#echo cgclassify -g devices:$CGROUP --sticky $(cat ${SGE_JOB_SPOOL_DIR}/pid) >> /tmp/prolog.log

# If running this script as part of stand-alone tests (without Grid Engine) then
# check if fewer GPUs were reserved than requested.
# If this is true then there were not enough free devices for the job 
# and the (dummy) scheduling should fail.
# This logic is not needed if running this script as a Grid Engine prolog script 
# as by the time this runs the scheduler has already checked 
# that there are a sufficient number of free GPUs to satisfy the request.
if [[ ${#claimed_dev_idxs[@]} -lt $NGPUS ]]; then
  echo "ERROR: Only reserved ${#claimed_dev_idxs[@]} of $NGPUS requested devices."
  exit 100
fi

# Set the cuda devices visible. This will re-enumerate the devices to users. 
# i.e. a job requesting 1 device which locks dev_idx=3 will see this as device 0 in nvidia-smi
#
# First, convert to a comma-delimited list:
CUDA_VISIBLE_DEVICES=$(IFS=, ; echo "${claimed_dev_idxs[*]}")
# Then set the environment (NB cannot just 'export' CUDA_VISIBLE_DEVICES as this script is not 'source'd)
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES" >> "$SGE_JOB_SPOOL_DIR/environment"

#exit 0
