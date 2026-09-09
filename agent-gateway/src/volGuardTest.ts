/**
 * volGuardTest.ts — Committed fail-path test for the volIsAnnualized guard.
 * Claim A from critic review 2026-09-09.
 * Run: npx tsc && node dist/volGuardTest.js
 */
import { calibrateLambdaFromVaR, computeOptimalTrajectory } from "./QuantEngine.js";

const COMMON = {
  portfolioSize: 100000, spotPrice: 10,
  timeHorizonHours: 2.5, varBudgetDollars: 50000, confidenceInterval: 0.95,
};

let allPassed = true;

function check(label: string, fn: () => void) {
  try {
    fn();
    console.log(`PASS: ${label}`);
  } catch (e: unknown) {
    console.log(`FAIL: ${label} — ${(e as Error).message}`);
    allPassed = false;
  }
}

function checkThrows(label: string, fn: () => void, expectFragment: string) {
  try {
    fn();
    console.log(`FAIL: ${label} — expected throw, got nothing`);
    allPassed = false;
  } catch (e: unknown) {
    const msg = (e as Error).message;
    if (msg.includes(expectFragment)) {
      console.log(`PASS: ${label}`);
      console.log(`  threw: ${msg}`);
    } else {
      console.log(`FAIL: ${label} — threw but wrong message: ${msg}`);
      allPassed = false;
    }
  }
}

console.log("=== CLAIM A: vol-unit guard — committed fail-path tests ===\n");

// TEST 1: vol>2.0 without flag must throw
console.log("--- TEST 1: vol=7.0 without volIsAnnualized=true must throw ---");
checkThrows(
  "calibrateLambdaFromVaR throws on vol=7.0 (no flag, horizon=2.5h)",
  () => calibrateLambdaFromVaR({ ...COMMON, historicalVol: 7.0 }),
  "looks like annualized vol"
);

// TEST 2: same vol with flag must succeed and normalize
console.log("\n--- TEST 2: vol=7.0 with volIsAnnualized=true must succeed and normalize ---");
check("calibrateLambdaFromVaR accepts vol=7.0 with flag", () => {
  const r = calibrateLambdaFromVaR({ ...COMMON, historicalVol: 7.0, volIsAnnualized: true });
  const expectedSigmaH = 7.0 * Math.sqrt(2.5 / 8760);
  const expectedLambda = (2 * Math.log(1 / 0.05) * 50000 * 50000) /
    ((1000000 * 1000000) * (expectedSigmaH * expectedSigmaH) * 2.5);
  const lambdaError = Math.abs(r.lambda - expectedLambda) / expectedLambda;
  console.log(`  sigma_horizon: ${expectedSigmaH.toFixed(6)}, computed lambda: ${r.lambda.toFixed(6)}, expected: ${expectedLambda.toFixed(6)}, error: ${(lambdaError*100).toFixed(4)}%`);
  if (lambdaError > 0.001) throw new Error(`lambda mismatch: ${lambdaError}`);
});

// TEST 3: sensitivity — 5% horizon vs 5% annualized must differ by factor 8760/2.5
console.log("\n--- TEST 3: 5% horizon vs 5% annualized must produce ratio=8760/2.5=3504.0 ---");
check("lambda ratio annualized/horizon equals T_year/T_hour = 8760/2.5", () => {
  const rH = calibrateLambdaFromVaR({ ...COMMON, historicalVol: 0.05 });
  const rA = calibrateLambdaFromVaR({ ...COMMON, historicalVol: 0.05, volIsAnnualized: true });
  const ratio = rA.lambda / rH.lambda;
  const expected = 8760 / 2.5;
  const err = Math.abs(ratio - expected) / expected;
  console.log(`  horizon lambda: ${rH.lambda.toFixed(6)}, annualized lambda: ${rA.lambda.toFixed(6)}`);
  console.log(`  Ratio annualized/horizon: ${ratio.toFixed(1)} (expected ${expected.toFixed(1)}), error: ${(err*100).toFixed(4)}%`);
  if (err > 0.001) throw new Error(`ratio mismatch: ratio=${ratio}, expected=${expected}`);
});

// TEST 4: computeOptimalTrajectory same guard fires
console.log("\n--- TEST 4: computeOptimalTrajectory guard fires on vol=5.0 (no flag) ---");
checkThrows(
  "computeOptimalTrajectory throws on vol=5.0 (no flag, horizon=2.5h)",
  () => computeOptimalTrajectory({ portfolioSize: 100000, timeSteps: 50, lambda: 2.39, historicalVol: 5.0, timeHorizonHours: 2.5 }),
  "looks like annualized vol"
);

// TEST 5: regression — existing callers with horizon vol=0.05 must still work
console.log("\n--- TEST 5: existing callers with horizon vol=0.05 must be unaffected ---");
check("calibrateLambdaFromVaR accepts vol=0.05 (below threshold)", () => {
  const r = calibrateLambdaFromVaR({ ...COMMON, historicalVol: 0.05 });
  const expected = 2.3966;
  const err = Math.abs(r.lambda - expected) / expected;
  console.log(`  lambda: ${r.lambda.toFixed(6)} (expected ~${expected}), error: ${(err*100).toFixed(4)}%`);
  if (err > 0.01) throw new Error(`regression: lambda=${r.lambda}, expected ~${expected}`);
});

console.log(`\n=== RESULT: ${allPassed ? "ALL TESTS PASSED" : "SOME TESTS FAILED"} ===`);
if (!allPassed) process.exit(1);
