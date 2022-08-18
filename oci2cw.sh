#!/bin/bash

BASE_DIR=`dirname $0`
POSITIONAL_ARGS=()

print_usage() {
	echo "Usage: $0 [-t TEE_TYPE] [-c TEE_CONFIG] [-C TEE_CERT_CHAIN] [-p CW_PASSWORD ] OCI_IMAGE CW_IMAGE"
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

if [ -z ${OCI_IMAGE} ] || [ -z ${CW_IMAGE} ]; then
	print_usage
fi

if [ -z ${TEE_TYPE} ]; then
    TEE_TYPE="sev"
fi

case ${TEE_TYPE} in
    "sev")
        if [ -z ${TEE_CERT_CHAIN} ]; then
            echo "TEE type \"sev\" requires the \"-C|--tee-cert-chain\" argument"
            exit 1
        elif [ ! -e ${TEE_CERT_CHAIN} ]; then
            echo "Can't find TEE_CERT_CHAIN file: ${TEE_CERT_CHAIN}"
            exit 1
        fi
        if [ -z ${TEE_CONFIG} ]; then
            echo "TEE type \"sev\" requires the \"-c|--tee-config\" argument"
            exit 1
        elif [ ! -e ${TEE_CONFIG} ]; then
            echo "Can't find TEE_CONFIG file: ${TEE_CONFIG}"
            exit 1
        fi
        if [ -z ${CW_PASSWORD} ]; then
            echo "TEE type \"sev\" requires the \"-p|--password\" argument"
            exit 1
        fi
        ;;
    *)
        echo "Unknown TEE type ${TEE_TYPE}"
        exit 1
        ;;    
esac

if [ -z ${BUILDAH_ISOLATION} ]; then
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

mkdir -p ${TMPDIR}/tmp
cp ${BASE_DIR}/containers/entrypoint/entrypoint ${TMPDIR}/entrypoint
chmod +x ${TMPDIR}/entrypoint
cp ${TEE_CONFIG} $TMPDIR/krun-sev.json
cp ${TEE_CERT_CHAIN} $TMPDIR/sev.chain

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

rm -r ${TMPDIR}

