"""Local LLVM module extension using third_party/llvm-project submodule."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:local.bzl", "new_local_repository")

# ── llvm_configure (inlined from third_party/llvm-project/utils/bazel/configure.bzl) ──

_MAX_TRAVERSAL_STEPS = 1000000

def _overlay_directories(repository_ctx):
    third_party_dir = repository_ctx.path(Label("//third_party:BUILD.bazel")).dirname
    src_root = third_party_dir.get_child("llvm-project")
    overlay_root = src_root.get_child("utils/bazel/llvm-project-overlay")
    target_root = repository_ctx.path(".")

    stack = ["."]
    for _ in range(_MAX_TRAVERSAL_STEPS):
        rel_dir = stack.pop()

        overlay_dirs = {}

        for entry in overlay_root.get_child(rel_dir).readdir():
            name = entry.basename
            full_rel_path = rel_dir + "/" + name

            if entry.is_dir:
                stack.append(full_rel_path)
                overlay_dirs[name] = None
            else:
                src_path = overlay_root.get_child(full_rel_path)
                dst_path = target_root.get_child(full_rel_path)
                repository_ctx.symlink(src_path, dst_path)

        for src_entry in src_root.get_child(rel_dir).readdir():
            name = src_entry.basename
            if name in overlay_dirs.keys():
                continue

            repository_ctx.symlink(src_entry, target_root.get_child(rel_dir + "/" + name))

        if not stack:
            return

    fail("overlay_directories: exceeded MAX_TRAVERSAL_STEPS ({}). " +
         "Tree too large or a cycle in the filesystem?".format(
             _MAX_TRAVERSAL_STEPS,
         ))

def _extract_cmake_settings(repository_ctx, llvm_cmake):
    c = {
        "CMAKE_CXX_STANDARD": None,
        "LLVM_VERSION_MAJOR": None,
        "LLVM_VERSION_MINOR": None,
        "LLVM_VERSION_PATCH": None,
        "LLVM_VERSION_SUFFIX": None,
    }

    llvm_cmake_path = repository_ctx.path(llvm_cmake)
    for line in repository_ctx.read(llvm_cmake_path).splitlines():
        setfoo = line.partition("(")
        if setfoo[1] != "(":
            continue
        if setfoo[0].strip().lower() != "set":
            continue

        kv = setfoo[2].strip()
        i = kv.find(" ")
        if i < 0:
            continue
        k = kv[:i]

        if k == "LLVM_REQUIRED_CXX_STANDARD":
            k = "CMAKE_CXX_STANDARD"
            c[k] = None
        if k not in c:
            continue

        if c[k] != None:
            continue

        v = kv[i:].strip().partition(")")[0].partition(" ")[0]
        c[k] = v

    c["LLVM_VERSION"] = "{}.{}.{}".format(
        c["LLVM_VERSION_MAJOR"],
        c["LLVM_VERSION_MINOR"],
        c["LLVM_VERSION_PATCH"],
    )

    c["PACKAGE_VERSION"] = "{}.{}.{}{}".format(
        c["LLVM_VERSION_MAJOR"],
        c["LLVM_VERSION_MINOR"],
        c["LLVM_VERSION_PATCH"],
        c["LLVM_VERSION_SUFFIX"],
    )

    return c

def _write_dict_to_file(repository_ctx, filepath, header, vars):
    fci = header
    fcd = "\nllvm_vars={\n"
    fct = "}\n"

    for k, v in vars.items():
        fci += '{} = "{}"\n'.format(k, v)
        fcd += '    "{}": "{}",\n'.format(k, v)

    repository_ctx.file(filepath, content = fci + fcd + fct)

def _llvm_configure_impl(repository_ctx):
    _overlay_directories(repository_ctx)

    llvm_cmake = "llvm/CMakeLists.txt"
    vars = _extract_cmake_settings(
        repository_ctx,
        llvm_cmake,
    )

    version = _extract_cmake_settings(
        repository_ctx,
        "cmake/Modules/LLVMVersion.cmake",
    )
    version = {k: v for k, v in version.items() if v != None}
    vars.update(version)

    _write_dict_to_file(
        repository_ctx,
        filepath = "vars.bzl",
        header = "# Generated from {}\n\n".format(llvm_cmake),
        vars = vars,
    )

    repository_ctx.file(
        "BUILD.bazel",
        content = "",
        executable = False,
    )

    llvm_targets = repository_ctx.attr.targets
    repository_ctx.file(
        "llvm/targets.bzl",
        content = "llvm_targets = " + str(llvm_targets),
        executable = False,
    )

    bolt_targets = ["AArch64", "X86", "RISCV"]
    bolt_targets = [t for t in llvm_targets if t in bolt_targets]
    repository_ctx.file(
        "bolt/targets.bzl",
        content = "bolt_targets = " + str(bolt_targets),
        executable = False,
    )

_llvm_configure = repository_rule(
    implementation = _llvm_configure_impl,
    local = True,
    configure = True,
    attrs = {
        "targets": attr.string_list(default = ["X86"]),
    },
)

# ── llvm_config (version constants) ──

def _llvm_config_repository_impl(rctx):
    version = rctx.attr.llvm_version
    parts = version.split(".")
    if len(parts) != 3:
        fail("Invalid LLVM version '{}': expected '<major>.<minor>.<patch>[suffix]'".format(version))

    major = int(parts[0])
    minor = int(parts[1])
    patch = int(parts[2])

    rctx.file("BUILD.bazel", """\
load("@bazel_lib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "version",
    srcs = ["version.bzl"],
    visibility = ["//visibility:public"],
)
""")

    rctx.file("version.bzl", """\
LLVM_VERSION_MAJOR = "{major}"
LLVM_VERSION_MINOR = "{minor}"
LLVM_VERSION_PATCH = "{patch}"
LLVM_VERSION = "{version}"

llvm_vars = {{
    "LLVM_VERSION_MAJOR": "{major}",
    "LLVM_VERSION_MINOR": "{minor}",
    "LLVM_VERSION_PATCH": "{patch}",
    "LLVM_VERSION": "{version}",
}}
""".format(
        major = major,
        minor = minor,
        patch = patch,
        version = version,
    ))

    return rctx.repo_metadata(reproducible = True)

_llvm_config_repository = repository_rule(
    implementation = _llvm_config_repository_impl,
    attrs = {
        "llvm_version": attr.string(mandatory = True),
    },
)

# ── Module extension ──

LLVM_RAW_PATH = "third_party/llvm-project"

def _llvm_extension_impl(mctx):
    new_local_repository(
        name = "llvm-raw",
        build_file_content = "# EMPTY",
        path = LLVM_RAW_PATH,
    )

    _llvm_config_repository(
        name = "llvm_config",
        llvm_version = "23.0.0",
    )

    http_archive(
        name = "llvm_zlib",
        build_file = "@llvm-raw//utils/bazel/third_party_build:zlib-ng.BUILD",
        sha256 = "e36bb346c00472a1f9ff2a0a4643e590a254be6379da7cddd9daeb9a7f296731",
        strip_prefix = "zlib-ng-2.0.7",
        urls = ["https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.0.7.zip"],
    )

    http_archive(
        name = "llvm_zstd",
        build_file = "@llvm-raw//utils/bazel/third_party_build:zstd.BUILD",
        sha256 = "7c42d56fac126929a6a85dbc73ff1db2411d04f104fae9bdea51305663a83fd0",
        strip_prefix = "zstd-1.5.2",
        urls = ["https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz"],
    )

    _llvm_configure(
        name = "llvm-project",
        targets = ["X86"],
    )

    return mctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = "all",
        root_module_direct_dev_deps = [],
    )

llvm = module_extension(
    implementation = _llvm_extension_impl,
)
