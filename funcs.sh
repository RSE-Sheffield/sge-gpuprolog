QSTAT_GPU_XPATH_QUERY="//detailed_job_info/djob_info/element/JB_hard_resource_list/qstat_l_requests/CE_stringval[../CE_name = 'gpu']/text()"
function get_n_gpus_req_per_slot {
    #
    # Get the number of GPUs requested per slot for this job
    #
    # Arguments: $1 job/task ID e.g. "${JOB_ID}.${SGE_TASK_ID}"
    # Outputs: integer to STDOUT
    #
    [[ "${SGE_TASK_ID}" == "undefined" ]] && SGE_TASK_ID=1
    qstat -j "${JOB_ID}.${SGE_TASK_ID}" -xml | /usr/bin/xmllint --xpath "${QSTAT_GPU_XPATH_QUERY}" -
}


is_pe_single_node() {
    #
    # Is the parallel environment of the current job single-node only i.e. does
    # it use the pe_slots allocation rule?
    # 
    # Arguments: None
    # Output: 0 (success) or 1 (failure)
    #
    if [[ -n ${PE-} ]] && qconf -sp "${PE}" | /usr/bin/grep -qE 'allocation_rule\s+\$pe_slots'; then
        echo 0
    else
        echo 1
    fi
}
