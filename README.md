# oci2cw

This is a utility to transform regular OCI images into encrypted
images suitable for being launched as Confidential Workloads with
[libkrun](https://github.com/containers/libkrun).

## Requirements

- podman
- buildah
- libkrun

## Setting it up

### Building the static entry point

```
make
```

### Creating the oci2cw container

```
cd containers/oci2cw
sh build.sh
```

## Usage

```
oci2cw [-t TEE_TYPE] [-c TEE_CONFIG] [-C TEE_CERT_CHAIN] [-p CW_PASSWORD ] OCI_IMAGE CW_IMAGE
```
