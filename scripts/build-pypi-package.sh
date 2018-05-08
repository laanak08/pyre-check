#!/bin/bash

# Copyright (c) 2018-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e

# global constants
PACKAGE_NAME="pyre-check"
PACKAGE_VERSION="0.0.3"
AUTHOR='Facebook'
AUTHOR_EMAIL='pyre@fb.com'
MAINTAINER='Facebook'
MAINTAINER_EMAIL='pyre@fb.com'
URL='https://github.com/facebook/pyre-check'
# https://www.python.org/dev/peps/pep-0008/#package-and-module-names
MODULE_NAME="pyre_check"
RUNTIME_DEPENDENCIES="'typeshed'"

# helpers
die() {
  printf '\n%s: %s, exiting.\n' "$(basename "$0")" "$*" >&2
  exit 1
}
error_trap () {
  die "Command '${BASH_COMMAND}' failed at ${BASH_SOURCE[0]}:${BASH_LINENO[0]}"
}

trap error_trap ERR

# Compatibility settings with MacOS.
if [[ "${MACHTYPE}" = *apple* ]]; then
  READLINK=greadlink
  HAS_PIP_GREATER_THAN_1_5=no
  WHEEL_DISTRIBUTION_PLATFORM=macosx_10_13_x86_64
else
  READLINK=readlink
  HAS_PIP_GREATER_THAN_1_5=yes
  WHEEL_DISTRIBUTION_PLATFORM=manylinux1_x86_64
fi

# Parse arguments.
while [[ $# -gt 0 ]]; do
  case "${1}" in
    "--bundle-typeshed")
      shift 1
      if [[ -n "$1" && -d "$1" ]]; then
        echo "Selected typeshed location for bundling: ${1}"
        BUNDLE_TYPESHED="${1}"
        RUNTIME_DEPENDENCIES=""

        # Attempt a basic validation of the provided directory.
        if [[ ! -d "${BUNDLE_TYPESHED}/stdlib" ]]; then
          echo
          echo 'The provided typeshed directory is not in the expected format:'
          echo '  it does not contain a "stdlib" subdirectory.'
          die 'Invalid typeshed directory'
        fi
      else
        die "Not a valid location to bundle typeshed from: '${1}'"
      fi
      ;;
    *)
      echo "Unrecognized parameter: ${1}"
      ;;
  esac
  shift
done

# Create build tree.
SCRIPTS_DIRECTORY="$(dirname "$("${READLINK}" -f "$0")")"
cd "${SCRIPTS_DIRECTORY}/"
BUILD_ROOT="$(mktemp -d)"
cd "${BUILD_ROOT}"
echo "Using build root: ${BUILD_ROOT}"

# Copy source files.
mkdir "${MODULE_NAME}"
# i.e. copy all *.py files from all directories, except "tests"
rsync -avm --filter='- tests/' --filter='+ */' --filter='-! *.py' "${SCRIPTS_DIRECTORY}/" "${BUILD_ROOT}/${MODULE_NAME}"

# Copy binary files.
BINARY_FILE="${SCRIPTS_DIRECTORY}/../_build/all/main.native"
if [[ ! -f "${BINARY_FILE}" ]]; then
  echo "The binary file ${BINARY_FILE} does not exist."
  echo "Have you run 'make' in the toplevel directory?"
  exit 1
fi
mkdir -p "${BUILD_ROOT}/bin"
cp "${BINARY_FILE}" "${BUILD_ROOT}/bin/pyre.bin"

# Copy misc files.
cp "${SCRIPTS_DIRECTORY}/../README.md" \
   "${SCRIPTS_DIRECTORY}/../LICENSE" \
   "${BUILD_ROOT}/"

# Optional bundling of typeshed.
if [[ -n "${BUNDLE_TYPESHED}" ]]; then
  mkdir -p "${BUILD_ROOT}/typeshed/"
  rsync -rvm --chmod="+w" --include="stdlib/***" --exclude="*" "${BUNDLE_TYPESHED}/" "${BUILD_ROOT}/typeshed/"
fi

# Create setup.py file.
cat > "${BUILD_ROOT}/setup.py" <<HEREDOC
import glob
import os
from setuptools import setup, find_packages

def find_typeshed_files(base):
    if not os.path.isdir(base):
       return []
    typeshed_root = os.path.join(base, 'typeshed')
    if not os.path.isdir(typeshed_root):
       return []
    result = []
    for absolute_directory, _, _ in os.walk(typeshed_root):
        relative_directory = os.path.relpath(absolute_directory, base)
        files = glob.glob(os.path.join(relative_directory, '*.pyi'))
        if not files:
            continue
        target = os.path.join('lib', '${MODULE_NAME}', relative_directory)
        result.append((target, files))
    return result

with open('README.md') as f:
    long_description = f.read()

setup(
    name='${PACKAGE_NAME}',
    version='${PACKAGE_VERSION}',
    description='A performant type checker for Python',
    long_description=long_description,
    long_description_content_type='text/markdown',

    url='${URL}',
    author='${AUTHOR}',
    author_email='${AUTHOR_EMAIL}',
    maintainer='${MAINTAINER}',
    maintainer_email='${MAINTAINER_EMAIL}',
    license='MIT',

    classifiers=[
        'Development Status :: 3 - Alpha',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: MIT License',
        'Operating System :: MacOS',
        'Operating System :: POSIX :: Linux',
        'Programming Language :: Python',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.6',
        'Topic :: Software Development',
    ],
    keywords='typechecker development',

    packages=find_packages(exclude=['tests']),
    data_files=[('bin', ['bin/pyre.bin'])] + find_typeshed_files("${BUILD_ROOT}/"),
    python_requires='>=3',
    install_requires=[${RUNTIME_DEPENDENCIES}],
    entry_points={
        'console_scripts': [
            'pyre = ${MODULE_NAME}.pyre:main',
        ],
    }
)
HEREDOC

# Create setup.cfg file.
cat > "${BUILD_ROOT}/setup.cfg" <<HEREDOC
[metadata]
license_file = LICENSE
HEREDOC

# Test descriptions before building:
# https://github.com/pypa/readme_renderer
if [[ "${HAS_PIP_GREATER_THAN_1_5}" == 'yes' ]]; then
  python3 setup.py check -r -s
fi

# Build.
python3 setup.py bdist_wheel

# Move artifact outside the build directory.
mkdir -p "${SCRIPTS_DIRECTORY}/dist"
files_count="$(find "${BUILD_ROOT}/dist/" -type f | wc -l | tr -d ' ')"
[[ "${files_count}" == '1' ]] || \
  die "${files_count} files created in ${BUILD_ROOT}/dist, but only one was expected"
source_file="$(find "${BUILD_ROOT}/dist/" -type f)"
destination="$(basename "${source_file}")"
destination="${destination/%-any.whl/-${WHEEL_DISTRIBUTION_PLATFORM}.whl}"
mv "${source_file}" "${SCRIPTS_DIRECTORY}/dist/${destination}"

# Cleanup.
cd "${SCRIPTS_DIRECTORY}"
rm -rf "${BUILD_ROOT}"

printf '\nAll done. Build artifact available at:\n  %s\n' "${SCRIPTS_DIRECTORY}/dist/${destination}"
exit 0
