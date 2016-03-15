#!/bin/bash
#
# This script runs Go language unit tests for the Origin repository. Arguments to this script
# are parsed as a list of packages to test until the first argument starting with '-' or '--' is
# found. That argument and all following arguments are interpreted as flags to be passed directly
# to `go test`. If no arguments are given, then "all" packages are tested.
#
# Coverage reports and jUnit XML reports can be generated by this script as well, but both cannot
# be generated at once.
#
# This script consumes the following parameters as environment variables:
#  - DRY_RUN:             prints all packages that would be tested with the args that would be used and exits
#  - TEST_KUBE:           toggles testing of non-essential Kubernetes unit tests
#  - TIMEOUT:             the timeout for any one unit test (default '60s')
#  - DETECT_RACES:        toggles the 'go test' race detector (defaults '-race')
#  - COVERAGE_OUTPUT_DIR: locates the directory in which coverage output files will be placed
#  - COVERAGE_SPEC:       a set of flags for 'go test' that specify the coverage behavior (default '-cover -covermode=atomic')
#  - GOTEST_FLAGS:        any other flags to be sent to 'go test'
#  - JUNIT_REPORT:        toggles the creation of jUnit XML from the test output and changes this script's output behavior
#                         to use the 'junitreport' tool for summarizing the tests.

set -o errexit
set -o nounset
set -o pipefail

function exit_trap() {
    local return_code=$?
    echo "[DEBUG] Exit trap handler got return code ${return_code}"

    end_time=$(date +%s)

    if [[ "${return_code}" -eq "0" ]]; then
        verb="succeeded"
    else
        verb="failed"
    fi

    echo "$0 ${verb} after $((${end_time} - ${start_time})) seconds"
    exit "${return_code}"
}

trap exit_trap EXIT

start_time=$(date +%s)
OS_ROOT=$(dirname "${BASH_SOURCE}")/..
source "${OS_ROOT}/hack/common.sh"
source "${OS_ROOT}/hack/util.sh"
source "${OS_ROOT}/hack/lib/util/environment.sh"
cd "${OS_ROOT}"
os::log::install_errexit
os::build::setup_env
os::util::environment::setup_tmpdir_vars "test-go"

# TODO(skuznets): remove these once we've migrated all tools to the new vars
if [[ -n "${KUBE_TIMEOUT+x}" ]]; then
    TIMEOUT="${KUBE_TIMEOUT}"
    echo "[WARNING] The flag \$KUBE_TIMEOUT for $0 is deprecated, use \$TIMEOUT instead."
fi

if [[ -n "${KUBE_COVER+x}" ]]; then
    COVERAGE_SPEC="${KUBE_COVER}"
    echo "[WARNING] The flag \$KUBE_COVER for $0 is deprecated, use \$COVERAGE_SPEC instead."
fi

if [[ -n "${OUTPUT_COVERAGE+x}" ]]; then
    COVERAGE_OUTPUT_DIR="${OUTPUT_COVERAGE}"
    echo "[WARNING] The flag \$OUTPUT_COVERAGE for $0 is deprecated, use \$COVERAGE_OUTPUT_DIR instead."
fi

if [[ -n "${KUBE_RACE+x}" ]]; then
    DETECT_RACES="${KUBE_RACE}"
    echo "[WARNING] The flag \$KUBE_RACE for $0 is deprecated, use \$DETECT_RACES instead."
fi

if [[ -n "${PRINT_PACKAGES+x}" ]]; then
    DRY_RUN="${PRINT_PACKAGES}"
    echo "[WARNING] The flag \$PRINT_PACKAGES for $0 is deprecated, use \$DRY_RUN instead."
fi

# Internalize environment variables we consume and default if they're not set
dry_run="${DRY_RUN:-}"
test_kube="${TEST_KUBE:-}"
test_timeout="${TIMEOUT:-60s}"
detect_races="${DETECT_RACES:-true}"
coverage_output_dir="${COVERAGE_OUTPUT_DIR:-}"
coverage_spec="${COVERAGE_SPEC:--cover -covermode atomic}"
gotest_flags="${GOTEST_FLAGS:-}"
junit_report="${JUNIT_REPORT:-}"

if [[ -n "${junit_report}" && -n "${coverage_output_dir}" ]]; then
    echo "$0 cannot create jUnit XML reports and coverage reports at the same time."
    exit 1
fi

# determine if user wanted verbosity
verbose=
if [[ "${gotest_flags}" =~ -v( |$) ]]; then
    verbose=true
fi

# Build arguments for 'go test'
if [[ -z "${verbose}" && -n "${junit_report}" ]]; then
    # verbosity can be set explicitly by the user or set implicitly by asking for the jUnit
    # XML report, so we only want to add the flag if it hasn't been added by a user already
    # and is being implicitly set by jUnit report generation
    gotest_flags+=" -v"
fi

if [[ "${detect_races}" == "true" ]]; then
    gotest_flags+=" -race"
fi

# check to see if user has not disabled coverage mode
if [[ -n "${coverage_spec}" ]]; then
    # if we have a coverage spec set, we add it. '-race' implies '-cover -covermode atomic'
    # but specifying both at the same time does not lead to an error so we can add both specs
    gotest_flags+=" ${coverage_spec}"
fi

# check to see if user has not disabled test timeouts
if [[ -n "${test_timeout}" ]]; then
    gotest_flags+=" -timeout ${test_timeout}"
fi

# list_test_packages_under lists all packages containing Golang test files that we want to run as unit tests
# under the given base dir in the OpenShift Origin tree
function list_test_packages_under() {
    local basedir=$@

    # we do not quote ${basedir} to allow for multiple arguments to be passed in as well as to allow for
    # arguments that use expansion, e.g. paths containing brace expansion or wildcards
    find ${basedir} -not \(                   \
        \(                                    \
              -path 'Godeps'                  \
              -o -path '*_output'             \
              -o -path '*_tools'              \
              -o -path '*.git'                \
              -o -path '*openshift.local.*'   \
              -o -path '*Godeps/*'            \
              -o -path '*assets/node_modules' \
              -o -path '*test/*'              \
        \) -prune                             \
    \) -name '*_test.go' | xargs -n1 dirname | sort -u | xargs -n1 printf "${OS_GO_PACKAGE}/%s\n"
}

# Break up the positional arguments into packages that need to be tested and arguments that need to be passed to `go test`
package_args=
for arg in "$@"; do
    if [[ "${arg}" =~ -.* ]]; then
        # we found an arg that begins with a dash, so we stop interpreting arguments
        # henceforth as packages and instead interpret them as flags to give to `go test`
        break
    fi
    # an arg found before the first flag is a package
    package_args+=" ${arg}"
    shift
done
gotest_flags+=" $*"

# Determine packages to test
test_packages=
if [[ -n "${package_args}" ]]; then
    for package in ${package_args}; do
        test_packages="${test_packages} ${OS_GO_PACKAGE}/${package}"
    done
else
    # If no packages are given to test, we need to generate a list of all packages with unit tests
    openshift_test_packages="$(list_test_packages_under '*')"

    kubernetes_path="Godeps/_workspace/src/k8s.io/kubernetes"
    mandatory_kubernetes_packages="${OS_GO_PACKAGE}/${kubernetes_path}/pkg/api ${OS_GO_PACKAGE}/${kubernetes_path}/pkg/api/v1"

    test_packages="${openshift_test_packages} ${mandatory_kubernetes_packages}"

    if [[ -n "${test_kube}" ]]; then
        # we need to find all of the kubernetes test suites, excluding those we directly whitelisted before, the end-to-end suite, and
        # the go2idl tests which we currently do not support
        optional_kubernetes_packages="$(find "${kubernetes_path}" -not \(                             \
          \(                                                                                          \
            -path "${kubernetes_path}/pkg/api"                                                        \
            -o -path "${kubernetes_path}/pkg/api/v1"                                                  \
            -o -path "${kubernetes_path}/test/e2e"                                                    \
            -o -path "${kubernetes_path}/cmd/libs/go2idl/client-gen/testoutput/testgroup/unversioned" \
          \) -prune                                                                                   \
        \) -name '*_test.go' | xargs -n1 dirname | sort -u | xargs -n1 printf "${OS_GO_PACKAGE}/%s\n")"

        test_packages="${test_packages} ${optional_kubernetes_packages}"
    fi
fi

if [[ -n "${dry_run}" ]]; then
    echo "The following base flags for \`go test\` will be used by $0:"
    echo "go test ${gotest_flags}"
    echo "The following packages will be tested by $0:"
    for package in ${test_packages}; do
        echo "${package}"
    done
    exit 0
fi

# Run 'go test' with the accumulated arguments and packages:
if [[ -n "${junit_report}" ]]; then
    # we need to generate jUnit xml
    hack/build-go.sh tools/junitreport
    junitreport="$(os::build::find-binary junitreport)"

    if [[ -z "${junitreport}" ]]; then
        echo "It looks as if you don't have a compiled junitreport binary"
        echo
        echo "If you are running from a clone of the git repo, please run"
        echo "'./hack/build-go.sh tools/junitreport'."
        exit 1
    fi

    test_output_file="${LOG_DIR}/test-go.log"
    junit_report_file="${ARTIFACT_DIR}/report.xml"

    echo "[INFO] Running \`go test\`..."
    # we don't care if the `go test` fails in this pipe, as we want to generate the report and summarize the output anyway
    set +o pipefail

    go test ${gotest_flags} ${test_packages} 2>&1              \
        | tee ${test_output_file}                              \
        | "${junitreport}" --type gotest                       \
                           --suites nested                     \
                           --roots github.com/openshift/origin \
                           --stream                            \
                           --output "${junit_report_file}"

    return_code="${PIPESTATUS[0]}"
    echo "[DEBUG] Found return code of \`go test\` to be ${return_code}"
    set -o pipefail

    echo
    cat "${junit_report_file}" | "${junitreport}" summarize
    echo "[INFO] Full output from \`go test\` logged at ${test_output_file}"
    echo "[INFO] jUnit XML report placed at ${junit_report_file}"

    echo "[DEBUG] Exiting with return code ${return_code}"
    exit "${return_code}"

elif [[ -n "${coverage_output_dir}" ]]; then
    # we need to generate coverage reports
    for test_package in ${test_packages}; do
        mkdir -p "${coverage_output_dir}/${test_package}"
        local_gotest_flags="${gotest_flags} -coverprofile=${coverage_output_dir}/${test_package}/profile.out"

        go test ${local_gotest_flags} ${test_package}
    done

    # assemble all profiles and generate a coverage report
    echo 'mode: atomic' > "${coverage_output_dir}/profiles.out"
    find "${coverage_output_dir}" -name profile.out | xargs sed '/^mode: atomic$/d' >> "${coverage_output_dir}/profiles.out"

    go tool cover "-html=${coverage_output_dir}/profiles.out" -o "${coverage_output_dir}/coverage.html"
    echo "[INFO] Coverage profile written to ${coverage_output_dir}/coverage.html"

    # clean up all of the individual coverage reports as they have been subsumed into the report at ${coverage_output_dir}/coverage.html
    # we can clean up all of the coverage reports at once as they all exist in subdirectories of ${coverage_output_dir}/${OS_GO_PACKAGE}
    # and they are the only files found in those subdirectories
    rm -rf "${coverage_output_dir}/${OS_GO_PACKAGE}"
else
    # we need to generate neither jUnit XML nor coverage reports
    go test ${gotest_flags} ${test_packages}
fi