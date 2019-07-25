Grid Engine + GPU prolog and epilog scripts
===========================================

Scripts to manage NVIDIA GPU devices in Grid Engine (tested with Son of Grid Engine 8.1.9).

Background
----------

It is increasingly common for nodes in High-Performance Computing (HPC) clusters to be equipped with more than one GPU. 
When users submit (interactive or batch) jobs to the scheduler software that manages resources on HPC clusters, 
the scheduler must be able to satisfy requests for 0 to $n$ GPUs, 
where $n$ is the most GPUs available on any node in the cluster. 

The [(Son of) Grid Engine](https://arc.liv.ac.uk/SGE/) (SoGE) scheduler 
that we use on the University of Sheffield's [ShARC](https://docs.hpc.sheffield.ac.uk/en/latest/sharc/index.html) cluster 
is very good at tracking the number of countable, consumable resources (e.g. GPUs) that are free on nodes 
but has no in-built mechanism for assigning particular resources to particular jobs. 
The resulting effect is that multiple users/jobs may end up using the same GPU (in a time-sliced manner) 
even though other GPUs in the same node are unused.

For example, say that only one node in a cluster contains GPUs (four of them) and 
that we define within SoGE's configuration a countable resource called `gpu` 
then define maximum values for it per node. 
If Alice submits a job where she requests one GPU 
and then Bob requests a GPU 
then the scheduler knows that two out of four GPUs have been allocated. 
However, neither user has been told _which_ to use 
so, potentially without realising it, both could use the GPU with 'index' 0 
(the first using an invariant means of enumeration).

By probing each GPU (by index) in turn Alice and Bob could try to identify GPUs that are not busy 
but this a horribly ad-hoc and unreliable approach. 
What is required here is a mechanism by which Alice and Bob could be forced or instructed to use particular GPUs. 
Other schedulers have suitable in-built mechanisms for managing mappings between jobs and countable, consumable resources: 
[SLURM][SLURM] does, 
as does Univa's version of Grid Engine (thanks to the [RSMAP complex][RSMAP]).

This approach
-------------

At the University of Sheffield we use these SoGE [queue **prolog** and **epilog**][sge_conf-man] scripts 
to maintain a mapping between jobs and allocated NVIDIA GPUs. 
This works as follows:

 1. A user submits a job where he/she requests between 0 and $n$ GPUs. 
    This job is explicitly or implicitly assigned to an SoGE queue (e.g. `gpu.q`).
 1. Just before the job is started on a node the queue's custom **prolog** program runs **on that node**. 
    This:
     1. Determines the GID of an ephemeral POSIX group created by SoGE for tracking resources associated with just this job.
     1. Queries the scheduler to determine the number of GPUs requested (then exits if that is <=0)
     1. Scales this number by the number of slots requested if using a [SMP][SMP] parallel environment called `smp`.
     1. Generates an array of GPU indexes (0..N-1) by expanding the glob `/dev/nvidia[0-9]*`.
     1. For all (integer) elements in that array: 
         1. If we've locked as many GPUs as we need then take no action.
         1. Otherwise try to create a lock by using `mkdir` to create a directory containing the GPU index in its name 
            (`mkdir` is one of the operations that [UNIX/POSIX can do atomically](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html)).
         1. If this suceeds then append the index to an array of claimed GPU indexes 
            and change the group of the character device for that GPU to the SoGE job-specific ephemeral group.
     1. If after the loop we've locked fewer GPUs than we originally wanted 
        then put the job in an error state 
        (**TODO**: after releasing all locks aquired within the 'for' loop).
     1. Convert the array of claimed GPU indexes into a comma-separated string.
     1. Writes `CUDA_VISIBLE_DEVICES=<that string>` into the `environment` file 
        in the node-specific spool directory of the job.
 1. This file is then used to instantiate the environment of the resulting interactive (`qsh` or `qrshx`) or batch (`qsub`) session.
 1. The CUDA library will then only be able to see the GPUs whose indexes are in the comma-separated list in `$CUDA_VISIBLE_DEVICES`. 

When the job finishes, the complementary **epilog** script 
iterates over the indexes in the `$CUDA_VISIBLE_DEVICES` list, 
removes all the corresponding lock directories
and sets the group of the corresponding block devices to `root`,
allowing those  GPUs to be used by queued/future jobs.

This approach is based on [https://github.com/kyamagu/sge-gpuprolog](https://github.com/kyamagu/sge-gpuprolog).

Limitations
-----------

  * No mechanism to enable **over-subscription** (the sharing of a GPU resource between jobs).
  * GPUs tied to a job for the job's entire duration, 
    which may or may not be an efficient use of resources depending on the workload.
  * Locks may need to be manually removed and character device group ownership changed if anything goes wrong but
      * Writing lock directories to a temporary filesystem ([`tmpfs`][tmpfs]) 
        will ensure they do not persist across reboots.
      * There are mechanisms (e.g. [`systemd-tmpfiles`][systemd-tmpfiles]) 
        that allow locks older than the maximum SoGE job run time to be automatically removed.
  * Does not presently work for multi-slot jobs on a single host 
    (where the number of GPUs is configured to scale with the number of slots).
  * Does not presently work for [MPI][MPI] jobs or hybrid MPI+SMP jobs.

Compatible versions
-------------------

Tested with Son of Grid Engine 8.1.9 but will most likely work with other versions.

Installation
------------

 1. Ensure the three scripts in this repository, 
    `prolog.sh` and `epilog.sh` and `nvchgrp`,
    are accessible on all worker nodes within the SoGE system (e.g. are on a shared filesystem)
    and are readable and executable by the `sge` user. 

 1. Ensure the permissions of all `/dev/nvidia[0-9]*` character devices are set to 0660 at boot time
    and the owner and group are both `root` are both `root` by default.

 1. Ensure that the `nvchgrp` separate script (for changing the group of NVIDIA character devices) 
    can be run by sge as root.
    Create `/etc/sudoers.d/sge` containing:

    ```
    sge ALL= (root) NOPASSWD: /path/to/nvchgrp
    ```

 1. Ensure that the directory that will contain the lock files is present on all nodes. 
    This needs to be readable and writable by the `sge` user. 
    The prolog and epilog scripts learn of this path via the `SGE_GPU_LOCKS_DIR` environment variable. 
    On the University of Sheffield's ShARC cluster this is set in `/etc/profile.d/sge_gpu_locks.sh` on all nodes.

 1. To ensure that locks are cleared after reboots and after a set duration 
    (just longer than the longest possible job; 4 days at the time of writing) 
    the `$SGE_GPU_LOCKS_DIR` is created with appropriate permissions at boot time 
    by the [systemd-tmpfiles][systemd-tmpfiles] mechanism. 
    This is set up on all GPU-equipped nodes by creating `/etc/tmpfiles.d/sge-gpu.conf` containing:

    ```
    D /tmp/sge-gpu 0755 sge users 5d
    ```

 1. Start configuring SoGE to use the prolog and epilog scripts: set up a SoGE consumable complex `gpu`:

    ```
    $ qconf -mc
    ```

    then within an editor:

    ```
    #name               shortcut   type        relop   requestable consumable default  urgency
    #----------------------------------------------------------------------------------------------
    gpu                 gpu        INT         <=      YES         YES        0        0
    ```


 1. Add the `gpu` resource complex on each execution host in the cluster, 
    specifying the number of GPUs available. 
    For example:
    
    ```
    $ qconf -aattr exechost complex_values gpu=1 node001
    ```

 1. Set up `prolog` and `epilog` scripts for the relevant scheduler queue(s). 
    For example, for the `gpu.q` queue:
    
    ```
    $ qconf -mq gpu.q
    ```

    then within an editor ensure the `prolog` and `epilog` lines read:

    ```
    prolog                sge@/path/to/prolog.sh
    epilog                sge@/path/to/epilog.sh
    ```

    The `sge@` is important: it means that the prolog and epilog scripts will be run as the `sge` user, not as the end-user, so:

      * the prolog script has the permissions to append to `$SGE_JOB_SPOOL_DIR/environment` and
      * the epilog script has the permissions to remove the lock directories created by the prolog script.

Usage
-----

Request a `gpu` resource when you submit your job 
(explicitly selecting a queue that uses these prolog and epilog scripts 
 if an appropriate queue is not automatically selected by the scheduler by the user simply requesting a `gpu` resource).

```
qsub -q gpu.q -l gpu=1 gpujob.sh
```

The `CUDA_VISIBLE_DEVICES` environment variable should then be defined in the environment of the job, 
which contains a comma-delimited string of device indexes, such as `0` or `0,1,2`. 

The CUDA library will then only be able to see the devices with these indexes, 
which, from the API have been reindexed from 0. 
For example, if within a `qrshx` session `CUDA_VISIBLE_DEVICES=3,7` 
then one can call the `cudaSetDevice(0)` C function to use the first of the two assigned GPUs (original index of 3) 
or `cudaSetDevice(1)` to use the second (original index of 7).

CUDA will then use to identify the subset of devices to be used.

TODO: update this section.


[MPI]: https://en.wikipedia.org/wiki/Message_Passing_Interface
[RSMAP]: http://gridengine.eu/grid-engine-internals/102-univa-grid-engine-810-features-part-2-better-resource-management-with-the-rsmap-complex-2012-05-25
[SLURM]: https://slurm.schedmd.com/
[SMP]: https://en.wikipedia.org/wiki/Symmetric_multiprocessing
[sge_conf-man]: http://gridscheduler.sourceforge.net/htmlman/htmlman5/sge_conf.html
[systemd-tmpfiles]: https://www.freedesktop.org/software/systemd/man/systemd-tmpfiles.html
[tmpfs]: https://en.wikipedia.org/wiki/Tmpfs
