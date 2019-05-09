#!/bin/bash

set -eu

# Exit states:
SUCCESS=0 # Success
RESHED=99 # Re-queue if FORBID-RESCHEDULE not set
APPERR=100 # Re-queue if FORBID-APPERROR not set
HOSTERR=101 # Other - Set queue to error state and resubmit job

CONF=/etc/sysconfig/cuda.conf

grid_owned='0'

if [[ -f "${CONF}" ]]; then
    source "${CONF}"
fi

DEVMODE=0660
DEVGROUP=root
SMI=/usr/bin/nvidia-smi
LOCKDIR=/var/run/lock/cuda
LOCKGPU=1
MAIL=/usr/bin/mail
ADMIN=w.furnass@sheffield.ac.uk
VARS=''
HOST=$(/usr/bin/hostname -s)

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $DIR/funcs.sh

if [[ "$SGE_TASK_ID" == "undefined" ]]; then
    SGE_TASK_ID=1
fi

mkdir -p ${LOCKDIR}

function mail_admin() {
    echo "$1" | "$MAIL" -s "CUDA Job prolog failure" "$ADMIN"
}

function number_in_list() {
    local number=$1
    shift
    local list=$*

    for i in ${list}; do
        if [[ "${number}" -eq "${i}" ]]; then
            return 1
        fi
    done
    return 0
}

# Query how many gpus to allocate (for serial process or per SMP or MPI slot)
declare -i gpus_needed="$(get_n_gpus_req_per_slot)"

# Exit if NGPUs is null or <= 0
if [[ -z "${gpus_needed}" ]] || [[ "${gpus_needed}" -le 0 ]]; then
    exit 0
fi

# Scale GPUs with number of requested cores if using the 'smp' Grid Engine
# Parallel Environment (as the current scheduler configuration is for the 'gpu'
# countable complex consumable to scale with the number of requested slots)
if is_pe_single_node "${PE}" && [[ -n "${NSLOTS}" ]] && [[ "${NSLOTS}" -gt 1 ]]; then
    gpus_needed=$(( gpus_needed * NSLOTS ))
fi

# Identify CUDA devices
if [[ -x ${SMI} ]]; then
    CUDA=1
    devices=$(${SMI} --query-gpu=uuid --format=csv,noheader)
    DRIVER_FAILED=$?
    if [ ${DRIVER_FAILED} -ne 0 ]; then
        # NVIDIA Driver not functioning correctly
        mail_admin "Unable to run ${SMI} - NVIDIA driver probably not functioning on ${HOST}"
        exit ${HOSTERR}
    fi
else
    CUDA=0
fi

SGE_GROUP="$(/usr/bin/awk -F'=' '/^add_grp_id/{print $2}' "${SGE_JOB_SPOOL_DIR}/config")"

function clean_exit() {
    code=$1
    shift
    gpu_list=$*
    if [[ ${LOCKGPU} -eq 1 ]]; then
        for gpu in ${gpu_list}; do
            /usr/bin/chgrp ${DEVGROUP} "/dev/nvidia${gpu}"
            /usr/bin/chmod ${DEVMODE} "/dev/nvidia${gpu}"
        done
    fi
    /usr/bin/rm -f "${LOCKDIR}/gpu${minor}"
    exit "${code}"
}

if [[ $CUDA -eq 1 ]]; then
    # shellcheck disable=SC2034
    CUDA_DEVICE_ORDER="PCI_BUS_ID"
    OWNED_GPUS=0
    OWNED_GPU_LIST=''
    FAILED_GPU_LIST=''
    # Find next available GPU
    for gpu in ${devices}; do
        minor=$(${SMI} -q -i "${gpu}" | /usr/bin/grep "Minor" | /usr/bin/cut -d: -f2 | /usr/bin/sed 's/ //g')
        number_in_list "${minor}" ${grid_owned}
        if [[ $? -eq 0 ]]; then
            continue
        fi
        TMPFILE=$(/usr/bin/mktemp --tmpdir=${LOCKDIR})
        if [[ $? -ne 0 ]]; then
            echo "Unable to create temporary file"
            mail_admin "Unable to create temporary file for locking GPU $gpu@${HOSTNAME}"
            clean_exit ${HOSTERR} ${OWNED_DEV_LIST}
        fi
        if [[ -z "$(${SMI} --query-compute-apps=pid -i ${gpu} --format=csv,noheader)" ]]; then
            # GPU is currently free - lock it
            /usr/bin/ln "${TMPFILE}" "${LOCKDIR}/gpu${minor}" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                FAILED_GPU_LIST="${FAILED_GPU_LIST} ${gpu}"
                /usr/bin/rm -f "${TMPFILE}"
            else
                if [[ ${LOCKGPU} -eq 1 ]]; then
                    /usr/bin/chmod "${DEVMODE}" "/dev/nvidia${minor}"
                    /usr/bin/chgrp "${SGE_GROUP}" "/dev/nvidia${minor}"
                fi
                OWNED_GPUS=$((OWNED_GPUS+1))
                OWNED_GPU_LIST="${OWNED_GPU_LIST} ${gpu}"
                OWNED_DEV_LIST="${OWNED_DEV_LIST} ${minor}"
                echo "${SGE_O_LOGNAME} ${JOB_ID} ${SGE_TASK_ID} ${minor} ${gpu} ${SGE_GROUP} ${LOCKGPU}" > "${TMPFILE}"
                if [[ ${OWNED_GPUS} -eq "${gpus_needed}" ]]; then
                    /usr/bin/rm -f "${TMPFILE}"
                    break
                fi
            fi
        fi
        /usr/bin/rm -f "${TMPFILE}"
    done
    if [[ ${OWNED_GPUS} -ne "${gpus_needed}" ]]; then
        # Failed to get required GPUs - reshedule the job
        echo "Unable to schedule requested number of GPUs. Lock failed on ${FAILED_GPU_LIST}."
        mail_admin "SGE gpu resource does not match available devices on ${HOSTNAME} - ${FAILED_GPU_LIST} ${SGE_O_LOGNAME} ${JOB_ID} ${SGE_TASK_ID} ${minor} ${gpu} ${SGE_GROUP} ${LOCKGPU}"
        clean_exit ${HOSTERR} "${OWNED_DEV_LIST}"
    fi

    SGE_GPU=$(echo "$OWNED_GPU_LIST" | /usr/bin/tr -s '[:blank:]' ',')
    # shellcheck disable=SC2034
    CUDA_VISIBLE_DEVICES="${SGE_GPU}"
    VARS="${VARS} CUDA_DEVICE_ORDER SGE_GPU CUDA_VISIBLE_DEVICES"
fi

# Set the following Env. Vars
for env in ${VARS}; do
    echo "$env=${!env}" >> "${SGE_JOB_SPOOL_DIR}/environment"
done
