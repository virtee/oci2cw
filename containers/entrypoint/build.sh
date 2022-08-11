#!/bin/bash

CTR=entrypoint-build

podman run -d --name $CTR -v .:/work:Z alpine /bin/sleep 5m
podman exec $CTR apk add gcc libc-dev
podman exec $CTR gcc -static -o /work/entrypoint /work/entrypoint.c
podman exec $CTR strip /work/entrypoint
podman kill $CTR 
podman rm $CTR
