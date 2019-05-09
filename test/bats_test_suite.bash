#load 'helpers/bats-mock/stub'
load 'helpers/bats-support/load'
load 'helpers/bats-assert/load'

source ../funcs.sh

@test "get_n_gpus_req_per_slot correctly extracts gpu count for a job" {
    function qstat() { cat qstat_output_with_1x_gpu.xml; }
    export -f qstat
    result="$(get_n_gpus_req_per_slot)"
    assert_equal "$result" 1
}

@test "is_pe_single_node correctly determines if the current job is multi-node" {
    function qconf() { cat qconf_sp_mpi.txt; }
    export -f qconf
    export PE=mpi
    result=$(is_pe_single_node)
    assert_equal $result 1

    unset qconf
    function qconf() { cat qconf_sp_smp.txt; }
    export -f qconf
    export PE=smp
    result=$(is_pe_single_node)
    assert_equal $result 0

    unset PE
    result=$(is_pe_single_node)
    assert_equal $result 1
}
