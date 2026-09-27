import { useReadContracts } from "wagmi";
import { Stack5InsuranceStakingABI } from "./contracts.stack5";
import { CHAIN_ID, IS_STACK5 } from "./deployment";
import { INSURANCE_ADDRESS, INSURANCE_V2_ADDRESS, InsuranceStakingABI } from "./insurance";

/** The insurance pool's live size and state: a chain read of the deployed InsuranceStaking. */
export const useInsurancePool: () => { assets: number | null; cap: number | null; drawPending: boolean | null } =
  // STACK 5: the v2 pool once its address is recorded; otherwise v1, as before. A module constant,
  // so the same hook runs on every render.
  IS_STACK5 && INSURANCE_V2_ADDRESS ? useInsurancePoolV2 : useInsurancePoolV1;

function useInsurancePoolV1() {
  const q = useReadContracts({
    contracts: [
      { address: INSURANCE_ADDRESS, abi: InsuranceStakingABI, chainId: CHAIN_ID, functionName: "totalAssets" },
      { address: INSURANCE_ADDRESS, abi: InsuranceStakingABI, chainId: CHAIN_ID, functionName: "depositCap" },
      { address: INSURANCE_ADDRESS, abi: InsuranceStakingABI, chainId: CHAIN_ID, functionName: "drawPending" },
    ],
    query: { refetchInterval: 30_000 },
  });
  const r = q.data;
  const ok = (i: number) => r?.[i]?.status === "success";
  return {
    assets: ok(0) ? Number(r![0].result as bigint) / 1e6 : null,
    cap: ok(1) ? Number(r![1].result as bigint) / 1e6 : null,
    drawPending: ok(2) ? (r![2].result as boolean) : null,
  };
}

/**
 * v2: the same three facts. `depositCap` is now a cap on net principal rather than on assets, and
 * `totalAssets` excludes income still vesting, so both read as what the pool can stand behind.
 */
function useInsurancePoolV2() {
  const pool = INSURANCE_V2_ADDRESS ?? INSURANCE_ADDRESS;
  const q = useReadContracts({
    contracts: [
      { address: pool, abi: Stack5InsuranceStakingABI, chainId: CHAIN_ID, functionName: "totalAssets" },
      { address: pool, abi: Stack5InsuranceStakingABI, chainId: CHAIN_ID, functionName: "depositCap" },
      { address: pool, abi: Stack5InsuranceStakingABI, chainId: CHAIN_ID, functionName: "drawPending" },
    ],
    query: { refetchInterval: 30_000 },
  });
  const r = q.data;
  const ok = (i: number) => r?.[i]?.status === "success";
  return {
    assets: ok(0) ? Number(r![0].result as bigint) / 1e6 : null,
    cap: ok(1) ? Number(r![1].result as bigint) / 1e6 : null,
    drawPending: ok(2) ? (r![2].result as boolean) : null,
  };
}
