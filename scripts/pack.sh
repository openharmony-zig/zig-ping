#!/bin/bash

ROOT_DIR=$(cd $(dirname $0); pwd)

pushd $ROOT_DIR/../
rm -rf dist
cp -r zig-out dist
ohrs artifact
popd