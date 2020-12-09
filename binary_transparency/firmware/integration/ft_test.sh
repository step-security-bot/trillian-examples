#!/bin/bash
set -e
. $(go list -f '{{.Dir}}' github.com/google/trillian)/integration/functions.sh
INTEGRATION_DIR="$( cd "$( dirname "$0" )" && pwd )"
. "${INTEGRATION_DIR}"/ft_functions.sh

COMMON_FLAGS="-v 2 --alsologtostderr"

ft_prep_test

function cleanup {
banner "Cleaning up"
ft_stop_test ${TO_KILL}
TO_KILL=()
}

trap cleanup EXIT

DEVICE_STATE=$(mktemp -d /tmp/dummy-XXXXX)
UPDATE_FILE=$(mktemp /tmp/update-XXXXX.json)
MALWARE_UPDATE_FILE=$(mktemp /tmp/malware-update-XXXXX.json)


# Cleanup for the Trillian components
TO_DELETE="${TO_DELETE} ${ETCD_DB_DIR}"
TO_KILL+=(${LOG_SIGNER_PIDS[@]})
TO_KILL+=(${RPC_SERVER_PIDS[@]})
TO_KILL+=(${ETCD_PID})

# Cleanup for the personality
TO_DELETE="${TO_DELETE} ${FT_CAS_DB} ${DEVICE_STATE} ${UPDATE_FILE} ${MALWARE_UPDATE_FILE} ${FT_MONITOR_LOG}"
TO_KILL+=(${FT_SERVER_PID})
TO_KILL+=(${FT_MONITOR_PID})

echo "Running test(s)"
pushd "${INTEGRATION_DIR}"

PUBLISH_TIMESTAMP_1="2020-11-24 10:00:00+00:00"
PUBLISH_TIMESTAMP_2="2020-11-24 10:15:00+00:00"
PUBLISH_MALWARE_TIMESTAMP="2020-11-24 10:30:00+00:00"

####################
banner "Logging initial firmware"
go run ../cmd/publisher/ \
    --log_url="http://${FT_SERVER}" \
    --device="dummy" \
    --binary_path="../testdata/firmware/dummy_device/example.wasm"  \
    --timestamp="${PUBLISH_TIMESTAMP_1}" \
    --revision=1 \
    --output_path="${UPDATE_FILE}" \
    ${COMMON_FLAGS}

####################
banner "Force flashing device (init)"
go run ../cmd/flash_tool/ \
    --log_url="http://${FT_SERVER}" \
    --update_file="${UPDATE_FILE}" \
    --dummy_storage_dir="${DEVICE_STATE}" \
    --force \
    ${COMMON_FLAGS}

####################
banner "Booting device with initial firmware"
go run ../cmd/emulator/dummy/ \
    --dummy_storage_dir="${DEVICE_STATE}" \
    ${COMMON_FLAGS}

####################
banner "Logging update firmware"
go run ../cmd/publisher/ \
    --log_url="http://${FT_SERVER}" \
    --device="dummy" \
    --binary_path="../testdata/firmware/dummy_device/example.wasm" \
    --timestamp="${PUBLISH_TIMESTAMP_2}" \
    --revision=2 \
    --output_path="${UPDATE_FILE}" \
    ${COMMON_FLAGS}

####################
banner "Flashing device (update)"
go run ../cmd/flash_tool/ \
    --log_url="http://${FT_SERVER}" \
    --update_file="${UPDATE_FILE}" \
    --dummy_storage_dir="${DEVICE_STATE}" \
    ${COMMON_FLAGS}

####################
banner "Booting updated device"
go run ../cmd/emulator/dummy/ \
    --dummy_storage_dir="${DEVICE_STATE}" \
    ${COMMON_FLAGS}

####################
banner "Fiddle with installed firmware and try to boot device"
cp -v ../testdata/firmware/dummy_device/hacked.wasm ${DEVICE_STATE}/firmware.bin
EXPECT_FAIL "firmware measurement does not match" \
    go run ../cmd/emulator/dummy/ \
        --dummy_storage_dir="${DEVICE_STATE}" \
        ${COMMON_FLAGS}

####################
banner "Fiddle with installed firmware & manifest and try to boot device"
HACKED_FIRMWARE=../testdata/firmware/dummy_device/hacked.wasm
cp -v ${HACKED_FIRMWARE} ${DEVICE_STATE}/firmware.bin
malware_hash=$(sha512sum ${DEVICE_STATE}/firmware.bin | awk '{print $1}' | xxd -r -p | base64 -w 0 )
echo "new hash ${malware_hash}"
mv ${DEVICE_STATE}/bundle.json ${DEVICE_STATE}/bundle.json.orig
# This beastly jq command unpacks the nested json structures and replaces just the fimware measurement with the one from our hacked firmware:
jq --arg hacked ${malware_hash} -c '.ManifestStatement=(.ManifestStatement|@base64d|fromjson|.Metadata=(.Metadata|@base64d|fromjson|.ExpectedFirmwareMeasurement=$hacked|tojson|@base64)|tojson|@base64)' ${DEVICE_STATE}/bundle.json.orig > ${DEVICE_STATE}/bundle.json
EXPECT_FAIL "invalid inclusion proof in bundle" \
    go run ../cmd/emulator/dummy/ \
        --dummy_storage_dir="${DEVICE_STATE}" \
        ${COMMON_FLAGS}


####################
banner "Log malware, device boots, but monitor sees all!"
go run ../cmd/publisher/ \
    --log_url="http://${FT_SERVER}" \
    --device="dummy" \
    --binary_path="${HACKED_FIRMWARE}"  \
    --timestamp="${PUBLISH_MALWARE_TIMESTAMP}" \
    --revision=1 \
    --output_path="${MALWARE_UPDATE_FILE}" \
    ${COMMON_FLAGS}

go run ../cmd/flash_tool/ \
    --log_url="http://${FT_SERVER}" \
    --update_file="${MALWARE_UPDATE_FILE}" \
    --dummy_storage_dir="${DEVICE_STATE}" \
    ${COMMON_FLAGS}

set +e # hacked firmware exits with status 0x1337
go run ../cmd/emulator/dummy/ \
    --dummy_storage_dir="${DEVICE_STATE}" \
    ${COMMON_FLAGS}
set -e

# Wait for the monitor to spot the malware
echo
echo "Monitor looking for malware in log..."
W=0
until [ "${W}" -eq 5 ] || grep --colour "Malware detected matched pattern" ${FT_MONITOR_LOG}; do
  sleep $(( W++ ))
done
cp ${FT_MONITOR_LOG} /tmp/mon.txt
[ $W -lt 5 ]

echo "PASS"

####################
banner "DONE"

popd

exit ${RESULT}