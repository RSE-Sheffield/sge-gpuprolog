#!/bin/bash

pushd test >/dev/null
helpers/bats-core/bin/bats bats_test_suite.bash
