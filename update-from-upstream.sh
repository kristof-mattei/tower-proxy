#!/bin/bash

# fetch so we can merge in without first
# having to checkout & pull the branches
git fetch origin
git fetch upstream

# delete existing branch
git branch -D update-from-upstream

# delete remote update-from-upstream
git push origin :update-from-upstream

# we create a new branch from the origin's main (=HEAD, because we fetched)
git checkout -b update-from-upstream origin/main

git push --set-upstream origin update-from-upstream

# merge in the changes from upstream
git merge upstream/main --no-edit

# the merged Dockerfile's entrypoint path ends in the seed's name, rewrite it to this repo's
application_name=$(basename --suffix=.git "$(git remote get-url origin)")

# split so update-name.sh does not rewrite this line
part_name="rust-"
seed_name="${part_name}seed"

sed --in-place "s#/app/${seed_name}#/app/${application_name,,}#g" Dockerfile

# fix stuff and ...
# git push
