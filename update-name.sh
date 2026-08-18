#!/bin/bash

new_name=$1

filtered_name="${new_name//[a-z0-9-]/}"

echo "New name = ${new_name}"

if [[ ${#filtered_name} != 0 ]]; then
    echo "Name only allows [a-z0-9-], found ${filtered_name} (length = ${#filtered_name})"
    exit 1
fi

new_name_with_underscore="${new_name//-/_}"

echo "New name with underscore = ${new_name_with_underscore}"

part_name="rust-"
old_name="${part_name}seed"
old_name_with_underscore="${old_name//-/_}"

echo "${old_name_with_underscore}"

rg --hidden --glob '!.git/*' --files-with-matches "${old_name}" | xargs --replace={} sed --in-place "s/${old_name}/${new_name}/g" {}
rg --hidden --glob '!.git/*' --files-with-matches "${old_name_with_underscore}"
rg --hidden --glob '!.git/*' --files-with-matches "${old_name_with_underscore}" | xargs --replace={} sed --in-place "s/${old_name_with_underscore}/${new_name_with_underscore}/g" {}
