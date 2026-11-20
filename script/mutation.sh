#!/usr/bin/env bash
# Mutation check for Zenith's fee accounting.
#
# Plants one deliberate bug at a time in src/ZenithHook.sol and runs the twin fee tests. Each bug must make
# the tests fail ("killed"). A bug the tests miss ("survived") means the tests are weaker than they claim.
# The original file is always restored, even if the script is interrupted.
#
# Usage: script/mutation.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=src/ZenithHook.sol
BACKUP=$(mktemp)
cp "$TARGET" "$BACKUP"
trap 'cp "$BACKUP" "$TARGET"; rm -f "$BACKUP"' EXIT

survived=0

# Applies a sed expression, confirms the file changed, runs the twin tests and reports the outcome.
mutate() {
    local name=$1 expr=$2
    cp "$BACKUP" "$TARGET"
    sed -i "$expr" "$TARGET"
    if cmp -s "$BACKUP" "$TARGET"; then
        echo "ERROR    $name: mutation did not apply (source changed?)"
        exit 2
    fi
    if forge test --match-contract ZenithTwinFeesTest >/dev/null 2>&1; then
        echo "SURVIVED $name"
        survived=$((survived + 1))
    else
        echo "KILLED   $name"
    fi
}

mutate "all sleeves share one position salt" \
    's/return bytes32(sleeveId);/return bytes32(0);/'
mutate "collected fees are not counted" \
    's/sleeve.fees0 += fees0.toUint128();/sleeve.fees0 += 0;/'
mutate "one wei skimmed on every collection" \
    's/uint256 received = net.toUint256();/uint256 received = net.toUint256() - (net > 1 ? 1 : 0);/'

# The fee-collection loop in _poke skips its last range.
poke_loop=$(awk '/function _poke\(/{f=1} f && /for \(uint256 i; i < current.length; \+\+i\)/{print NR; exit}' "$BACKUP")
mutate "fee collection skips the last range" \
    "${poke_loop}s/i < current.length/i + 1 < current.length/"

if [ "$survived" -gt 0 ]; then
    echo "$survived mutant(s) survived"
    exit 1
fi
echo "All mutants killed"
