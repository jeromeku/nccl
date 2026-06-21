#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$root/build"
jobs="8"
# Set by --llvm-ir to request LLVM bitcode emission from the CMake build.
llvm_ir=0
# Set by --with-mpi to enable MPI-gated contrib samples/tests.
with_mpi=0
# Set by --dry-run so run() prints commands without executing them.
dry_run=0
# Set by --cuda-home, or inherited from CUDA_HOME when available.
export CUDA_HOME="/usr/local/cuda-13.1"
cuda_home="${CUDA_HOME:-"/usr/local/cuda-13.1"}"
# Set by --cuda-archs and forwarded to CMAKE_CUDA_ARCHITECTURES.
cuda_archs="90"
# Set by --python, or auto-detected for UB-X when needed.
python_exe="${PYTHON:-}"
# Set by --ubx-arch-list, or inherited from TORCH_CUDA_ARCH_LIST.
ubx_arch_list="${TORCH_CUDA_ARCH_LIST:-"9.0a"}"
# Populated by --contrib/--all-contrib; keys are selected contrib targets.
declare -A contrib=()
# Populated by repeatable --cmake-arg values and appended to configure_cmd.
declare -a cmake_args=()
# Populated by repeatable --make-arg values and forwarded to contrib Makefiles.
declare -a make_args=()
supported_contrib=(nccl_ep nccl_m2n nccl_checkpoint custom_algos nccl_ubx)

# Print command-line help and keep option descriptions in one place.
usage() {
  cat <<'EOF'
Build NCCL from source with CMake RelWithDebInfo.

Usage:
  ./nccl_relwithdebinfo_build.sh [options]

Core options:
  --build-dir DIR          Build directory (default: ./build-relwithdebinfo)
  -j, --jobs N             Parallel jobs (default: nproc)
  --cuda-home DIR          CUDA toolkit root; also forwarded to contrib Makefiles
  --cuda-archs LIST        CMake CUDA arch list, for example "90;100;120"
  --llvm-ir                Build bindings/ir/libnccl_device.bc
  --cmake-arg ARG          Extra CMake configure argument; repeatable

Contrib options:
  --contrib NAME           Build one contrib: nccl_ep, nccl_m2n,
                           nccl_checkpoint, custom_algos, nccl_ubx, or all
  --all-contrib            Build all supported contrib entries
  --with-mpi               Pass MPI=1 for MPI-gated contrib samples/tests
  --make-arg ARG           Extra Make variable/argument for contrib builds
  --python EXE             Python for UB-X (default: ./.venv/bin/python if present,
                           else python3)
  --ubx-arch-list LIST     TORCH_CUDA_ARCH_LIST for UB-X

Other:
  --dry-run                Print commands without executing them
  -h, --help               Show this help

Examples:
  ./nccl_relwithdebinfo_build.sh --llvm-ir
  ./nccl_relwithdebinfo_build.sh --all-contrib --with-mpi --llvm-ir
  ./nccl_relwithdebinfo_build.sh --contrib nccl_m2n --contrib nccl_ubx
EOF
}

# Print a fatal error and stop the script.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Echo the command in shell-escaped form, then execute it unless --dry-run was set.
run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$dry_run" == 0 ]]; then
    "$@"
  fi
}

# Mark a contrib package for later build, validating against supported_contrib.
select_contrib() {
  local name="$1"
  if [[ "$name" == all ]]; then
    for item in "${supported_contrib[@]}"; do contrib["$item"]=1; done
    return
  fi
  for item in "${supported_contrib[@]}"; do
    if [[ "$name" == "$item" ]]; then contrib["$name"]=1; return; fi
  done
  die "unknown contrib '$name'"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    # --build-dir chooses where CMake configures and writes build artifacts.
    --build-dir) [[ $# -ge 2 ]] || die "$1 needs a value"; build_dir="$2"; shift 2 ;;
    # -j/--jobs controls CMake and Make parallelism.
    -j|--jobs) [[ $# -ge 2 ]] || die "$1 needs a value"; jobs="$2"; shift 2 ;;
    # --cuda-home points both CMake and contrib Makefiles at a CUDA toolkit.
    --cuda-home) [[ $# -ge 2 ]] || die "$1 needs a value"; cuda_home="$2"; shift 2 ;;
    # --cuda-archs forwards an explicit architecture list to CMake.
    --cuda-archs) [[ $# -ge 2 ]] || die "$1 needs a value"; cuda_archs="$2"; shift 2 ;;
    # --llvm-ir enables generation of bindings/ir/libnccl_device.bc.
    --llvm-ir) llvm_ir=1; shift ;;
    # --cmake-arg appends one raw argument to the CMake configure command.
    --cmake-arg) [[ $# -ge 2 ]] || die "$1 needs a value"; cmake_args+=("$2"); shift 2 ;;
    # --contrib selects one contrib package, or all when the value is "all".
    --contrib) [[ $# -ge 2 ]] || die "$1 needs a value"; select_contrib "$2"; shift 2 ;;
    # --all-contrib selects every supported contrib package.
    --all-contrib) select_contrib all; shift ;;
    # --with-mpi passes MPI=1 to contrib builds that gate MPI examples/tests.
    --with-mpi) with_mpi=1; shift ;;
    # --make-arg appends one raw variable/argument to contrib Make invocations.
    --make-arg) [[ $# -ge 2 ]] || die "$1 needs a value"; make_args+=("$2"); shift 2 ;;
    # --python chooses the interpreter used for the UB-X editable install.
    --python) [[ $# -ge 2 ]] || die "$1 needs a value"; python_exe="$2"; shift 2 ;;
    # --ubx-arch-list sets TORCH_CUDA_ARCH_LIST for UB-X compilation.
    --ubx-arch-list) [[ $# -ge 2 ]] || die "$1 needs a value"; ubx_arch_list="$2"; shift 2 ;;
    # --dry-run switches run() into print-only mode for command inspection.
    --dry-run) dry_run=1; shift ;;
    # -h/--help prints usage and exits successfully without building.
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[[ "$jobs" =~ ^[0-9]+$ ]] || die "--jobs must be an integer"
[[ "$jobs" -gt 0 ]] || die "--jobs must be positive"

emit_ir=OFF
build_nccl_ep=OFF
[[ "$llvm_ir" == 1 ]] && emit_ir=ON
[[ -n "${contrib[nccl_ep]+x}" ]] && build_nccl_ep=ON

configure_cmd=(
  cmake -S "$root" -B "$build_dir"
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  -DEMIT_LLVM_IR="$emit_ir"
  -DBUILD_NCCL_EP="$build_nccl_ep"
  -DCMAKE_VERBOSE_MAKEFILE=ON
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
)
[[ -n "$cuda_home" ]] && configure_cmd+=(-DCUDAToolkit_ROOT="$cuda_home")
[[ -n "$cuda_archs" ]] && configure_cmd+=(-DCMAKE_CUDA_ARCHITECTURES="$cuda_archs")
configure_cmd+=("${cmake_args[@]}")

# run "${configure_cmd[@]}"

run cmake --build "$build_dir" --config RelWithDebInfo --parallel "$jobs" 2>&1 | tee cmake.build.log

# common_make=(BUILDDIR="$build_dir")
# [[ -n "$cuda_home" ]] && common_make+=(CUDA_HOME="$cuda_home")
# common_make+=("${make_args[@]}")

# if [[ -n "${contrib[nccl_m2n]+x}" ]]; then
#   run make -C "$root/contrib/nccl_m2n" -j "$jobs" lib \
#     NCCL_HOME="$build_dir" "${common_make[@]}"
# fi

# if [[ -n "${contrib[nccl_checkpoint]+x}" ]]; then
#   run make -C "$root/contrib/nccl_checkpoint" -j "$jobs" all \
#     NCCL_SRC="$root/src" "${common_make[@]}"
# fi

# if [[ -n "${contrib[custom_algos]+x}" ]]; then
#   custom_make=("${common_make[@]}")
#   [[ "$with_mpi" == 1 ]] && custom_make+=(MPI=1)
#   run make -C "$root/contrib/custom_algos/allreduce" -j "$jobs" "${custom_make[@]}"
#   run make -C "$root/contrib/custom_algos/alltoall" -j "$jobs" "${custom_make[@]}"
# fi

# if [[ -n "${contrib[nccl_ubx]+x}" ]]; then
#   if [[ -z "$python_exe" ]]; then
#     if [[ -x "$root/.venv/bin/python" ]]; then
#       python_exe="$root/.venv/bin/python"
#     else
#       python_exe=python3
#     fi
#   fi
#   if [[ "$dry_run" == 0 ]]; then
#     "$python_exe" -c 'import torch' >/dev/null 2>&1 || \
#       die "UB-X requires PyTorch in $python_exe; create/activate a venv or pass --python"
#   fi
#   ubx_env=(NCCL_HOME="$build_dir" NCCL_INCLUDE_DIR="$build_dir/include"
#            NCCL_LIBRARY_DIR="$build_dir/lib" MAX_JOBS="$jobs")
#   [[ -n "$ubx_arch_list" ]] && ubx_env+=(TORCH_CUDA_ARCH_LIST="$ubx_arch_list")
#   run env "${ubx_env[@]}" "$python_exe" -m pip install -e "$root/contrib/nccl_ubx"
# fi

# printf 'Done. NCCL artifacts are under: %s\n' "$build_dir"
