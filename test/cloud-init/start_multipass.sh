#!/bin/bash

multipass launch 24.04 \
  --name github-runner \
  --cpus 2 \
  --memory 4G \
  --disk 30G \
  --cloud-init cloud-init.yaml

multipass shell github-runner

#multipass list
multipass stop github-runner
multipass purge
