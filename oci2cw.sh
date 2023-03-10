#!/bin/bash

BASE_DIR=`dirname $0`
POSITIONAL_ARGS=()

print_usage() {
	echo "Usage: $0 -c TEE_CONFIG [-C TEE_CERT_CHAIN] [-p CW_PASSWORD ] OCI_IMAGE CW_IMAGE"
	exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -C|--tee-cert-chain)
            TEE_CERT_CHAIN="$2"
            shift
            shift
            ;;
        -c|--tee-config)
            TEE_CONFIG="$2"
            shift
            shift
            ;;
        -h|--help)
            print_usage
            ;;
        -p|--password)
            CW_PASSWORD="$2"
            shift
            shift
            ;;
        -t|--tee)
            TEE_TYPE="$2"
            shift
            shift
            ;;
        -*|--*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1") # save positional arg
            shift # past argument
            ;;
    esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

OCI_IMAGE=$1
CW_IMAGE=$2

if [ -z "${OCI_IMAGE}" ] || [ -z "${CW_IMAGE}" ]; then
	print_usage
fi

if [ -z "${TEE_CONFIG}" ]; then
    echo "Missing \"-c|--tee-config\" argument"
    exit 1
elif [ ! -e "${TEE_CONFIG}" ]; then
    echo "Can't find TEE_CONFIG file: ${TEE_CONFIG}"
    exit 1
fi

TEE_TYPE=`grep tee\" ${TEE_CONFIG} | sed -E "s/.*: \"(.*)\",/\1/g"`
WORKLOAD_ID=`grep workload_id ${TEE_CONFIG} | sed -E "s/.*: \"(.*)\",/\1/g"`
CPUS=`grep cpus ${TEE_CONFIG} | sed -E "s/.*: (.*),/\1/g"`
RAM_MIB=`grep ram_mib ${TEE_CONFIG} | sed -E "s/.*: (.*),/\1/g"`
ATTESTATION_URL=`grep attestation_url ${TEE_CONFIG} | sed -E "s/.*: \"(.*)\"/\1/g"`

case ${TEE_TYPE} in
    "sev")
        if [ -z "${TEE_CERT_CHAIN}" ]; then
            echo "TEE type \"sev\" requires the \"-C|--tee-cert-chain\" argument"
            exit 1
        elif [ ! -e "${TEE_CERT_CHAIN}" ]; then
            echo "Can't find TEE_CERT_CHAIN file: ${TEE_CERT_CHAIN}"
            exit 1
        fi
        ;&
    "snp")
        if [ -z "${CW_PASSWORD}" ]; then
            CW_PASSWORD=`tr -dc A-Za-z0-9 </dev/urandom | head -c 64`
        fi
        ;;
    *)
        echo "Unknown TEE type ${TEE_TYPE}"
        exit 1
        ;;    
esac

if [ ${TEE_TYPE} == "sev" ]; then
	KRUNFW_MEASUREMENT=`krunfw_measurement -c $CPUS -m $RAM_MIB /usr/lib64/libkrunfw-sev.so | grep SEV-ES | sed -e "s/SEV-ES:\s//g"`
elif [ ${TEE_TYPE} == "snp" ]; then
	KRUNFW_MEASUREMENT=`krunfw_measurement -c $CPUS -m $RAM_MIB /usr/lib64/libkrunfw-sev.so | grep SNP | sed -e "s/SNP:\s//g"`
else
	echo "Can't generate a launch measurement for this TEE type: ${TEE_TYPE}"
fi

if [ $? != 0 ] || [ -z "${KRUNFW_MEASUREMENT}" ]; then
    echo "Couldn't generate launch measurement for /usr/lib64/libkrunfw-sev.so"
    exit 1
fi

if [ -z "${WORKLOAD_ID}" ]; then
    echo "Empty workload_id field in TEE_CONFIG"
    exit 1
fi

if [ -z "${ATTESTATION_URL}" ]; then
    echo "Empty attestation_url field in TEE_CONFIG"
    exit 1
fi

if [ -z "${BUILDAH_ISOLATION}" ]; then
    echo "Please re-run this command inside a \"buildah unshare\" session"
    exit 1
fi

CONT=cwtemp-$RANDOM
TMPDIR=`mktemp -d`
OCI_TARBALL=$TMPDIR/oci.tar

out=`buildah from --name $CONT $OCI_IMAGE`
if [ $? != 0 ]; then
    echo "buildah from failed:\n$out"
    exit 1
fi

dir=$(buildah mount $CONT)
if [ $? != 0 ]; then
    echo "buildah mount failed"
	buildah rm $CONT
    exit 1
fi

cd ${dir}
rm -fr dev
buildah inspect $OCI_IMAGE > .krun_config.json

tar cpf $OCI_TARBALL .
if [ $? != 0 ]; then
    echo "tarball creation failed"
	buildah umount $CONT
	buildah rm $CONT
    exit 1
fi

cd ${OLDPWD}

out=`buildah umount $CONT`
out=`buildah rm $CONT`

echo "Creating encrypted disk image"
podman run --runtime /usr/bin/krun -v $TMPDIR:/work:Z -e PASSWORD=$CW_PASSWORD --rm -ti oci2cw

if [ ! -e ${TMPDIR}/disk.img ]; then
	echo "encrypted disk creation failed:\n$out"
	rm -r ${TMPDIR}
	exit 1
fi

# We need to attach the TEE config file at the end of the encrypted disk
# image so it can be read by the guest in plain text.
DISKSIZE=`stat --printf="%s" ${TMPDIR}/disk.img`
CONFSIZE=`stat --printf="%s" ${TEE_CONFIG}`
let EXTSIZE=($CONFSIZE/512+1)*512
let PADDING=$EXTSIZE-$CONFSIZE-12
dd if=/dev/zero of=${TMPDIR}/disk.img bs=1 seek=$DISKSIZE count=$PADDING
cat ${TEE_CONFIG} >> ${TMPDIR}/disk.img
echo -n "KRUN" >> ${TMPDIR}/disk.img
perl -e "print pack("Q",(${CONFSIZE}))" >> ${TMPDIR}/disk.img

mkdir -p ${TMPDIR}/tmp
cp ${BASE_DIR}/entrypoint/entrypoint ${TMPDIR}/entrypoint
chmod +x ${TMPDIR}/entrypoint
cp ${TEE_CONFIG} $TMPDIR/krun-sev.json
if [ ${TEE_TYPE} == "sev" ]; then
	cp ${TEE_CERT_CHAIN} $TMPDIR/sev.chain
else
	touch $TMPDIR/sev.chain
fi

cat << EOF > $TMPDIR/Containerfile
FROM scratch

COPY tmp /tmp
COPY disk.img /disk.img
COPY entrypoint /entrypoint
COPY krun-sev.json /krun-sev.json
COPY sev.chain /sev.chain

ENTRYPOINT ["/entrypoint"]
EOF

podman image build -f ${TMPDIR}/Containerfile -t localhost/${CW_IMAGE}


sed -e "s/OCI2CW_WORKLOAD_ID/${WORKLOAD_ID}/" -e "s/OCI2CW_LAUNCH_MEASUREMENT/${KRUNFW_MEASUREMENT}/" -e "s/OCI2CW_PASSPHRASE/${CW_PASSWORD}/" ${BASE_DIR}/templates/register_workload.json > ${TMPDIR}/register_workload.json

curl -d "@${TMPDIR}/register_workload.json" -X POST -H "Content-Type: application/json" ${ATTESTATION_URL}/kbs/v0/register_workload
if [ $? != 0 ]; then
    echo "Error registering workload"
fi

rm -r ${TMPDIR}
