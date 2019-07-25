#!/bin/bash
#
# Authors: Will Furnass, Mozhgan Kabiri Chimeh, Paul Richmond, 
# Contact: w.furnass@sheffield.ac.uk
#
# Sun Grid Engine Epilog script to free GPU lock directories for devices used by a job.
# Based on https://github.com/kyamagu/sge-gpuprolog

# Ensure SGE_GPU_LOCKS_DIR env var is set
source /etc/profile.d/sge_gpu_locks.sh

# Read the comma-delimited list of device idxs used by the job into an array
declare -a device_idxs
IFS=, device_idxs=("$CUDA_VISIBLE_DEVICES")

# Loop through through the device IDs and free the lockdir
for i in "${device_idxs[@]}"; do
  # Lock directory is specific for each ShARC node and each device combination
  lockdir="${SGE_GPU_LOCKS_DIR}/lock_device_${i}"

  # Check dir exists then remove the lockdir
  [[ -d "$lockdir" ]] && /usr/bin/rmdir "$lockdir"

  # Reset group on /dev/nvidia${i} character device 
  /usr/bin/sudo ./nvchgrp root "${i}"
done

#exit 0
