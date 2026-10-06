#!/bin/bash

set -eu -o pipefail

read -r -a cargo_features <<< "${CARGO_FEATURES:---all-features}"
grcov_output_types="${GRCOV_OUTPUT_TYPES:-lcov,html,markdown}"

host_tuple=$(rustc --print host-tuple)
host_tuple=${host_tuple//-/_}

# `RUSTFLAGS` replaces the rustflags in `.cargo/config.toml`, so it cannot be used here
# https://doc.rust-lang.org/cargo/reference/config.html#buildrustflags
target_rustflags="CARGO_TARGET_${host_tuple^^}_RUSTFLAGS"
declare -x "${target_rustflags}=${!target_rustflags:-} --allow=warnings -Cinstrument-coverage"

build() {
    # build-* ones are not parsed by grcov
    LLVM_PROFILE_FILE="profiling/build-%p-%m.profraw" \
        cargo build "${cargo_features[@]}" --all-targets --locked --workspace
}

run_tests() {
    # cleanup old values
    find . -name '*.profraw' -delete

    # different from the `cargo build` ones
    LLVM_PROFILE_FILE="profiling/profile-%p-%m.profraw" \
        cargo nextest run --profile ci --no-fail-fast "${cargo_features[@]}" --all-targets --workspace
}

report() {
    mapfile -d '' profraw_files < <(find . -name "profile-*.profraw" -print0)

    grcov "${profraw_files[@]}" \
        --binary-path ./target/debug/ \
        --branch \
        --excl-br-line "^\s*((debug_)?assert(_eq|_ne)?!)" \
        --excl-br-start "mod tests \{" \
        --excl-br-stop "^}$" \
        --excl-line "(#\\[derive\\()|(^\s*.await[;,]?$)" \
        --excl-start "mod tests \{" \
        --excl-stop "^}$" \
        --ignore-not-existing \
        --keep-only "src/**" \
        --llvm \
        --output-path ./reports/ \
        --output-type "${grcov_output_types}" \
        --source-dir .
}

case "${1:-all}" in
    build)
        build
        ;;
    test)
        run_tests
        ;;
    report)
        report
        ;;
    all)
        build

        test_exit_code=0
        run_tests || test_exit_code=$?

        report

        exit "${test_exit_code}"
        ;;
    *)
        echo "usage: $0 [build|test|report]" >&2
        exit 1
        ;;
esac
