load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_user_netrc", "use_netrc")
load("@bazel-zig-cc//toolchain/private:defs.bzl", "target_structs", "zig_tool_path")

# Directories that `zig c++` includes behind the scenes.
_DEFAULT_INCLUDE_DIRECTORIES = [
    "libcxx/include",
    "libcxxabi/include",
    "libunwind/include",
]

_fcntl_map = """
GLIBC_2.2.5 {
   fcntl;
};
"""
_fcntl_h = """
#ifdef __ASSEMBLER__
.symver fcntl64, fcntl@GLIBC_2.2.5
#else
__asm__(".symver fcntl64, fcntl@GLIBC_2.2.5");
#endif
"""

# Official recommended version. Should use this when we have a usable release.
URL_FORMAT_RELEASE = "https://ziglang.org/download/{version}/zig-{host_platform}-{version}.{_ext}"

# Caution: nightly releases are purged from ziglang.org after ~90 days. A real
# solution would be to allow the downstream project specify their own mirrors.
# This is explained in
# https://sr.ht/~motiejus/bazel-zig-cc/#alternative-download-urls and is
# awaiting my attention or your contribution.
URL_FORMAT_NIGHTLY = "https://ziglang.org/builds/zig-{host_platform}-{version}.{_ext}"

# Author's mirror that doesn't purge the nightlies so aggressively. I will be
# cleaning those up manually only after the artifacts are not in use for many
# months in bazel-zig-cc. dl.jakstys.lt is a small x86_64 server with an NVMe
# drive sitting in my home closet on a 1GB/s symmetric residential connection,
# which, as of writing, has been quite reliable.
URL_FORMAT_JAKSTYS = "https://dl.jakstys.lt/zig/zig-{host_platform}-{version}.{_ext}"

_VERSION = "0.10.0-dev.4301+uber1"

_HOST_PLATFORM_SHA256 = {
    "linux-aarch64": "67c81abc575e0fec27be3a49008e2d7cdf70cc8b33606ee1cf6837cc90300690",
    "linux-x86_64": "e6e2e8de6c96b20470a1b9f42df54abecd33a5d5da0e33e643f410b362ed999c",
    "macos-aarch64": "f553944a47ff27954acfd8cc41dc28dc71253e3598812e8b9c69e48e48ea5965",
    "macos-x86_64": "7e8a54c5592566df1da25d61ee2eae1fc5a89ae4dcbbf816ce6051001e53538b",
    "windows-x86_64": "f9f41cfa573db25925506ca4c96d7b23b97f4111aac322e66a23b686b63f669f",
}

_HOST_PLATFORM_EXT = {
    "linux-aarch64": "tar.xz",
    "linux-x86_64": "tar.xz",
    "macos-aarch64": "tar.xz",
    "macos-x86_64": "tar.xz",
    "windows-x86_64": "zip",
}

def toolchains(
        version = _VERSION,
        url_formats = [URL_FORMAT_NIGHTLY, URL_FORMAT_JAKSTYS],
        host_platform_sha256 = _HOST_PLATFORM_SHA256,
        host_platform_ext = _HOST_PLATFORM_EXT):
    """
        Download zig toolchain and declare bazel toolchains.
        The platforms are not registered automatically, that should be done by
        the user with register_toolchains() in the WORKSPACE file. See README
        for possible choices.
    """
    zig_repository(
        name = "zig_sdk",
        version = version,
        url_formats = url_formats,
        host_platform_sha256 = host_platform_sha256,
        host_platform_ext = host_platform_ext,
        host_platform_include_root = {
            "linux-aarch64": "lib/zig/",
            "linux-x86_64": "lib/",
            "macos-aarch64": "lib/",
            "macos-x86_64": "lib/zig/",
            "windows-x86_64": "lib/",
        },
    )

_ZIG_TOOLS = [
    "c++",
    "cc",
    "ar",
    "ld.lld",  # ELF
    "ld64.lld",  # Mach-O
    "lld-link",  # COFF
    "wasm-ld",  # WebAssembly
]

_ZIG_TOOL_WRAPPER_WINDOWS_CACHE_KNOWN = """@echo off
if exist "external\\zig_sdk\\lib\\*" goto :have_external_zig_sdk_lib
set ZIG_LIB_DIR=%~dp0\\..\\..\\lib
goto :set_zig_lib_dir
:have_external_zig_sdk_lib
set ZIG_LIB_DIR=external\\zig_sdk\\lib
:set_zig_lib_dir
set ZIG_LOCAL_CACHE_DIR={cache_prefix}\\bazel-zig-cc
set ZIG_GLOBAL_CACHE_DIR=%ZIG_LOCAL_CACHE_DIR%
"{zig}" "{zig_tool}" {maybe_target} %*
"""

_ZIG_TOOL_WRAPPER_WINDOWS_CACHE_GUESS = """@echo off
if exist "external\\zig_sdk\\lib\\*" goto :have_external_zig_sdk_lib
set ZIG_LIB_DIR=%~dp0\\..\\..\\lib
goto :set_zig_lib_dir
:have_external_zig_sdk_lib
set ZIG_LIB_DIR=external\\zig_sdk\\lib
:set_zig_lib_dir
if exist "%TMP%\\*" goto :usertmp
set ZIG_LOCAL_CACHE_DIR=C:\\Temp\\bazel-zig-cc
goto zig
:usertmp
set ZIG_LOCAL_CACHE_DIR=%TMP%\\bazel-zig-cc
:zig
set ZIG_GLOBAL_CACHE_DIR=%ZIG_LOCAL_CACHE_DIR%
"{zig}" "{zig_tool}" {maybe_target} %*
"""

_ZIG_TOOL_WRAPPER_CACHE_KNOWN = """#!/bin/sh
set -e
if [ -d external/zig_sdk/lib ]; then
    ZIG_LIB_DIR=external/zig_sdk/{zig_include_root}
else
    ZIG_LIB_DIR="$(dirname "$0")/../../{zig_include_root}"
fi
export ZIG_LIB_DIR
export ZIG_LOCAL_CACHE_DIR="{cache_prefix}/bazel-zig-cc"
export ZIG_GLOBAL_CACHE_DIR="{cache_prefix}/bazel-zig-cc"
{maybe_gohack}
exec "{zig}" "{zig_tool}" {maybe_target} "$@"
"""

_ZIG_TOOL_WRAPPER_CACHE_GUESS = """#!/bin/sh
set -e
if [ -d external/zig_sdk/lib ]; then
    ZIG_LIB_DIR=external/zig_sdk/{zig_include_root}
else
    ZIG_LIB_DIR="$(dirname "$0")/../../{zig_include_root}"
fi
if [ -n "$TMPDIR" ]; then
    _cache_prefix=$TMPDIR
elif [ -n "$HOME" ]; then
    if [ "$(uname)" = Darwin ]; then
        _cache_prefix="$HOME/Library/Caches"
    else
        _cache_prefix="$HOME/.cache"
    fi
else
    _cache_prefix=/tmp
fi
export ZIG_LIB_DIR
export ZIG_LOCAL_CACHE_DIR="$_cache_prefix/bazel-zig-cc"
export ZIG_GLOBAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR
{maybe_gohack}
exec "{zig}" "{zig_tool}" {maybe_target} "$@"
"""

# The abomination below adds "-O2" to Go's link-prober command. Saves around
# 25s for the first compilation for a particular architecture. Can be deleted
# if/after https://go-review.googlesource.com/c/go/+/436884 is merged.
# Shell hackery taken from
# https://web.archive.org/web/20100129154217/http://www.seanius.net/blog/2009/03/saving-and-restoring-positional-params
_ZIG_TOOL_GOHACK = """
quote(){ echo "$1" | sed -e "s,','\\\\'',g"; }
for arg in "$@"; do saved="${saved:+$saved }'$(quote "$arg")'"; done
while [ "$#" -gt 6 ]; do shift; done
if [ "$*" = "-Wl,--no-gc-sections -x c - -o /dev/null" ]; then
  # This command probes if `--no-gc-sections` is accepted by the linker.
  # Since it is executed in /tmp, the ZIG_LIB_DIR is absolute,
  # glibc stubs and libc++ cannot be shared with other invocations (which use
  # a relative ZIG_LIB_DIR).
  exit 0;
fi
eval set -- "$saved"
"""

def _zig_tool_wrapper(zig_tool, zig, is_windows, cache_prefix, zigtarget, zig_include_root):
    kwargs = dict(
        zig = str(zig).replace("/", "\\") + ".exe" if is_windows else zig,
        zig_tool = zig_tool,
        cache_prefix = cache_prefix,
        maybe_gohack = _ZIG_TOOL_GOHACK if (zig_tool == "c++" and not is_windows) else "",
        maybe_target = "-target {}".format(zigtarget) if zig_tool == "c++" else "",
        zig_include_root = zig_include_root,
    )

    if is_windows:
        if cache_prefix:
            return _ZIG_TOOL_WRAPPER_WINDOWS_CACHE_KNOWN.format(**kwargs)
        else:
            return _ZIG_TOOL_WRAPPER_WINDOWS_CACHE_GUESS.format(**kwargs)
    else:  # keep this comment to shut up buildifier.
        if cache_prefix:
            return _ZIG_TOOL_WRAPPER_CACHE_KNOWN.format(**kwargs)
        else:
            return _ZIG_TOOL_WRAPPER_CACHE_GUESS.format(**kwargs)

def _quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _zig_repository_impl(repository_ctx):
    arch = repository_ctx.os.arch
    if arch == "amd64":
        arch = "x86_64"

    os = repository_ctx.os.name.lower()
    if os.startswith("mac os"):
        os = "macos"

    if os.startswith("windows"):
        os = "windows"

    host_platform = "{}-{}".format(os, arch)

    zig_include_root = repository_ctx.attr.host_platform_include_root[host_platform]
    zig_sha256 = repository_ctx.attr.host_platform_sha256[host_platform]
    zig_ext = repository_ctx.attr.host_platform_ext[host_platform]
    format_vars = {
        "_ext": zig_ext,
        "version": repository_ctx.attr.version,
        "host_platform": host_platform,
    }

    # Fetch Label dependencies before doing download/extract.
    # The Bazel docs are not very clear about this behavior but see:
    # https://bazel.build/extending/repo#when_is_the_implementation_function_executed
    # and a related rules_go PR:
    # https://github.com/bazelbuild/bazel-gazelle/pull/1206
    for dest, src in {
        "platform/BUILD": "//toolchain/platform:BUILD",
        "toolchain/BUILD": "//toolchain/toolchain:BUILD",
        "libc/BUILD": "//toolchain/libc:BUILD",
        "libc_aware/platform/BUILD": "//toolchain/libc_aware/platform:BUILD",
        "libc_aware/toolchain/BUILD": "//toolchain/libc_aware/toolchain:BUILD",
    }.items():
        repository_ctx.symlink(Label(src), dest)

    for dest, src in {
        "BUILD": "//toolchain:BUILD.sdk.bazel",
        # "private/BUILD": "//toolchain/private:BUILD.sdk.bazel",
    }.items():
        repository_ctx.template(
            dest,
            Label(src),
            executable = False,
            substitutions = {
                "{zig_sdk_path}": _quote("external/zig_sdk"),
                "{os}": _quote(os),
                "{zig_include_root}": _quote(zig_include_root),
            },
        )

    urls = [uf.format(**format_vars) for uf in repository_ctx.attr.url_formats]
    repository_ctx.download_and_extract(
        auth = use_netrc(read_user_netrc(repository_ctx), urls, {}),
        url = urls,
        stripPrefix = "zig-{host_platform}-{version}/".format(**format_vars),
        sha256 = zig_sha256,
    )

    for zig_tool in _ZIG_TOOLS:
        for target_config in target_structs():
            zig_tool_wrapper = _zig_tool_wrapper(
                zig_tool,
                str(repository_ctx.path("zig")),
                os == "windows",
                repository_ctx.os.environ.get("BAZEL_ZIG_CC_CACHE_PREFIX", ""),
                zigtarget = target_config.zigtarget,
                zig_include_root = zig_include_root,
            )

            repository_ctx.file(
                zig_tool_path(os).format(
                    zig_tool = zig_tool,
                    zigtarget = target_config.zigtarget,
                ),
                zig_tool_wrapper,
            )

    repository_ctx.file(
        "glibc-hacks/fcntl.map",
        content = _fcntl_map,
    )
    repository_ctx.file(
        "glibc-hacks/glibchack-fcntl.h",
        content = _fcntl_h,
    )

zig_repository = repository_rule(
    attrs = {
        "version": attr.string(),
        "host_platform_sha256": attr.string_dict(),
        "url_formats": attr.string_list(allow_empty = False),
        "host_platform_include_root": attr.string_dict(),
        "host_platform_ext": attr.string_dict(),
    },
    environ = ["BAZEL_ZIG_CC_CACHE_PREFIX"],
    implementation = _zig_repository_impl,
)

def filegroup(name, **kwargs):
    native.filegroup(name = name, **kwargs)
    return ":" + name

def declare_files(os, zig_include_root):
    filegroup(name = "all", srcs = native.glob(["**"]))
    filegroup(name = "empty")
    if os == "windows":
        native.exports_files(["zig.exe"], visibility = ["//visibility:public"])
        native.alias(name = "zig", actual = ":zig.exe")
    else:
        native.exports_files(["zig"], visibility = ["//visibility:public"])
    filegroup(name = "lib/std", srcs = native.glob(["lib/std/**"]))

    lazy_filegroups = {}

    for target_config in target_structs():
        for d in _DEFAULT_INCLUDE_DIRECTORIES + target_config.includes:
            d = zig_include_root + d
            if d not in lazy_filegroups:
                lazy_filegroups[d] = filegroup(name = d, srcs = native.glob([d + "/**"]))
