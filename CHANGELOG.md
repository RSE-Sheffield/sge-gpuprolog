# Changelog

## 0.1

 - GPU locking for 1-core, n-GPU jobs only

## 0.2

 - GPU locking for m-core, n*m-GPU jobs added (needed if using a `smp` parallel environment)

## 0.3

 - Switch from parsing `nvidia-smi -L` to checking `/proc/driver/nvidia/gpus` to determine the number of GPUs (much faster)

## 0.4-dev

 - TODO
