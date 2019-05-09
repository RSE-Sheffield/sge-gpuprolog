# University of Sheffield GridEngine prolog/epilog for locking GPUs to jobs 

**Acknowledgements: derived from https://git.fmrib.ox.ac.uk/fmribitprojects/gridengine-scripts**

To aid with the correct allocation of CUDA cards to jobs several tasks need to be carried out. 
These are handled by the `fmrib_cuda_prolog.sh` and `fmrib_cuda_epilog.sh` scripts 
which should be configured as pro/epilog scripts for GPU queues.
These scripts should be put in a place visible to all cluster nodes 
(e.g. `/opt/sge/default/common`) and made executable.
The pro/epilogs should be added to GridEngine Queue definitions as:

```bash
root@/usr/local/sge/live/default/common/prolog.sh
root@/usr/local/sge/live/default/common/epilog.sh
```

It is essential they are run as root as only root can change the device special file permissions.

Their mode of action is to enumerate all CUDA devices on the system then attempt to create a lock file for that device. 
Assuming the lock file can be created then 
the permissions on the CUDA device special file are set to group write/other no access and 
the group is changed to the Grid Engine supplied job group such that 
only jobs running under this shepherd can access the device. 
CUDA is configured to enumerate devices in PCI address order and 
then the `CUDA_VISIBLE_DEVICES` and `SGE_GPU` environment variables are set to contain 
the comma-separated list of UUIDs for the cards available to the CUDA environment.

To allow sharing of system resources between queue'd and non-queued tasks 
it is possible to specify which GPUs will be used by the queues 
in the file `/etc/sysconfig/cuda.conf` using the variable `grid_owned`. 
Set this to a double-quoted string containing the space separated list of GPU minor numbers to use with the cluster, e.g. `grid_owned="0 1"`. 
These are liable to change at reboot so care should be taken to ensure the appropriate numbers are given if GPUs are currently in use outside of the queues 
(ideally reboot the system as the CUDA configuration script described below manages the ownership of these device special files).

Should any of this setup fail the job will be rescheduled and the queue will be put into the error state.
Post-job the device special files are left as group read/write, other hidden and group root such that non-queue controlled tasks cannot use them in the interim.

For the device special file ownership mechanism to operate the NVIDIA kernel module must be instructed to not manage the permissions on these files. This is achieved by creating the file `/etc/modprobe.d/nvidia.conf` with the contents:

```
options nvidia NVreg_ModifyDeviceFiles=0
```

The module must then be reloaded (or the machine rebooted), this can be done with:

```sh
modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
modprobe nvidia nvidia_uvm nvidia_drm nvidia_modeset
```

If you can't unload the `nvidia` module check that you don't have any monitoring system (e.g. Ganglia) that is utilising the module.

In this mode the NVIDIA driver does not create the device special files needed to access the GPUs - it is necessary to create these on boot. 
See https://git.fmrib.ox.ac.uk/ansible/cuda_configuration for an appropriate start-up script which does the equivalent of:

```sh
mknod -Z -m 0660 /dev/nvidiax c 195 x
mknod -Z -m 0666 /dev/nvidiactl c 195 255
mknod -Z -m 0666 /dev/nvidia-uvm c 242 0
mknod -Z -m 0666 /dev/nvidia-uvm-tools c 242 1
```

(where `x` is 0,1..., one for each GPU in system). If cards are to be made available to non-grid controlled processes then those that are dedicated to Grid Engine are hidden:

```sh
chmod 0660 /dev/nvidiax
```

The designation of which GPUs are for cluster use is defined in `/etc/sysconfig/cuda.conf` using the variable `grid_owned` to a double-quoted string containing the space separated list of GPU minor numbers to use with the cluster, e.g. `grid_owned="0 1"`

In addition to this a Grid Engine complex should be created:

|Name   |Shortcut   |Type   |Relation   |Requestable    |Consumable |Default    |Urgency|
|-------|-----------|-------|-----------|---------------|-----------|-----------|-------|
|gpu    |gpu    |INT    |<= |YES    |JOB    |0  |0  |

Then each CUDA node should be configured with this complex, holding a value equal to the number of GPU cards you wish to allocate to Grid managment.
Once this is in place the CUDA tasks should request this complex.

## Testing

These scripts can be (partly) unit tested using a [BATS](https://github.com/bats-core/bats-core) test suite.
You do not need to run these tests on a Grid Engine cluster

```sh
git clone --recurse-submodules git@github.com:RSE-Sheffield/sge-gpuprolog.git
cd sge-gpuprolog
bash test.sh
```
