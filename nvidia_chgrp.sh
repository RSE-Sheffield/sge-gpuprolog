#!/bin/bash
declare -r dev_grp="$1"
declare -i nv_dev_idx="$2"
declare -r dev_node="/dev/nvidia${nv_dev_idx}"
declare -r DEFAULT_GROUP=root
declare -r DEFAULT_MODE=0660

function die {
    echo "$@" 1>&2
    exit 1
}
function usage { 
    echo "Usage: $0 <dev_grp> <nv_dev_idx>"
}

if [[ $# -ne 2 ]]; then
    die $(usage)
fi

# If the group is numeric
if [[ ${dev_grp} =~ ^[0-9]+$ ]]; then
    read -r min_gid max_gid <<<$(qconf -sconf | awk '/gid_range/ {print $2}' | tr '-' ' ')
    if [[ ${dev_grp} -lt ${min_gid} ]] || [[ ${dev_grp} -gt ${max_gid} ]]; then
        die "Error: SGE job group GID ${dev_grp} outside valid range (${min_gid}-${max_gid})"
    fi
elif [[ ${dev_grp} != ${DEFAULT_GROUP} ]]; then
    die "Error: SGE job is not numeric or '${DEFAULT_GROUP}'"
fi

if ! [[ -c ${dev_node} ]]; then
    die "Error: character device node ${dev_node} does not exist"
fi

echo chgrp "${dev_grp}" "${dev_node}"
echo chmod "${DEFAULT_MODE}" "${dev_node}"
