#!/bin/bash


# The Rust linker provides it's own C runtime, so strip
# the one provided by Zig

# Attempt to detect a Rust build with `rules_rust`
is_rust=false
for value in "$@"
do
    [[ $value == *lib/rustlib* ]] && is_rust=true
done


stripped_args=()
for value in "$@"
do
    if [[ "$is_rust" = false ]] || [[ $value != *self-contained/*crt* ]]; then 
        stripped_args+=($value)
    fi;
done

# Invoke the `zig-wrapper` binary by overriding `argv[0]`
exec -a $0 {ZIG_WRAPPER} "${stripped_args[@]}"
