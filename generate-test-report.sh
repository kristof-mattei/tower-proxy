#!/bin/bash

base_rustflags=""
cargo_features="--all-features"

export RUSTFLAGS="${base_rustflags} --allow=warnings -Cinstrument-coverage"

# build-* ones are not parsed by grcov
export LLVM_PROFILE_FILE="profiling/build-%p-%m.profraw"
cargo build ${cargo_features} --all-targets --locked --workspace

# cleanup old values
find . -name '*.profraw' -delete

# different from the `cargo build` ones
LLVM_PROFILE_FILE="profiling/profile-%p-%m.profraw"
cargo nextest run --profile ci --no-fail-fast ${cargo_features} --all-targets --workspace

mapfile -d '' profraw_files < <(find . -name "profile-*.profraw" -print0)

grcov "${profraw_files[@]}" \
    --binary-path ./target/debug/ \
    --branch \
    --excl-br-line "^\s*((debug_)?assert(_eq|_ne)?!)" \
    --excl-br-start "mod tests \{" \
    --excl-line "(#\\[derive\\()|(^\s*.await[;,]?$)" \
    --excl-start "mod tests \{" \
    --ignore-not-existing \
    --keep-only "src/**" \
    --llvm \
    --output-path ./reports/ \
    --output-type lcov,html,markdown \
    --source-dir .
