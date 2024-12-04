#!/bin/bash
for patch_file in ./patches/*.yaml
do
    deployment_name=$(basename "$patch_file" .yaml)
    kubectl patch deployment $deployment_name --patch-file $patch_file
done
