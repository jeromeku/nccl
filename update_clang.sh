#!/bin/bash

set -euo pipefail

VERSION=22

for tool in clang clang++ clangd clang-format clang-tidy opt lld lldb llvm-as llvm-dis llvm-link llvm-config; do
    if [ -f "/usr/bin/${tool}-${VERSION}" ]; then
        sudo update-alternatives --install "/usr/bin/${tool}" "$tool" "/usr/bin/${tool}-${VERSION}" 100
    fi
done