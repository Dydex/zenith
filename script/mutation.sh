#!/usr/bin/env bash
# Mutation check for Zenith's fee accounting.
#
# Plants one deliberate bug at a time in src/ZenithHook.sol and runs the tests that should catch it: the twin fee
# tests for accounting bugs, the scoring tests for scoring bugs. Each bug must make those tests fail ("killed").
# A bug the tests miss ("survived") means the tests are weaker than they claim.
# The original file is always restored, even if the script is interrupted.
#
# Usage: script/mutation.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=src/ZenithHook.sol
BACKUP=$(mktemp)
cp "$TARGET" "$BACKUP"
SETTLER=src/ZenithSettler.sol
SETTLER_BACKUP=$(mktemp)
cp "$SETTLER" "$SETTLER_BACKUP"
trap 'cp "$BACKUP" "$TARGET"; cp "$SETTLER_BACKUP" "$SETTLER"; rm -f "$BACKUP" "$SETTLER_BACKUP"' EXIT

survived=0

# Applies a sed expression, confirms the file changed, runs the given test contract and reports the outcome.
mutate() {
    local name=$1 expr=$2 suite=${3:-ZenithTwinFeesTest} file=${4:-hook}
    cp "$BACKUP" "$TARGET"
    cp "$SETTLER_BACKUP" "$SETTLER"
    local target=$TARGET original=$BACKUP
    if [ "$file" = settler ]; then target=$SETTLER original=$SETTLER_BACKUP; fi
    sed -i "$expr" "$target"
    if cmp -s "$original" "$target"; then
        echo "ERROR    $name: mutation did not apply (source changed?)"
        exit 2
    fi
    if forge test --match-contract "$suite" >/dev/null 2>&1; then
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

mutate "score against current liquidity instead of period-start liquidity" \
    's/int256 expected = start \* (controlIndex - score.indexLast)/int256 expected = uint256(score.inRange).toInt256() * (controlIndex - score.indexLast)/' \
    ZenithScoringTest
mutate "deposits counted as skill" \
    's/score.held0 += amount0;/score.held0 += 0;/' \
    ZenithScoringTest

mutate "high-water mark never advances (gains paid again)" \
    's/            account.highWater = cumulative;/            account.highWater = account.highWater;/' \
    ZenithSettlerTest settler
mutate "slash kept by the settler instead of reaching depositors" \
    's/hook.settle(sleeveId, int256(slashed), address(0), false);/hook.settle(sleeveId, 0, address(0), false);/' \
    ZenithSettlerTest settler

if [ "$survived" -gt 0 ]; then
    echo "$survived mutant(s) survived"
    exit 1
fi
echo "All mutants killed"
