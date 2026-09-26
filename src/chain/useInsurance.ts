import { useReadContracts } from "wagmi";
import { CHAIN_ID } from "./deployment";
import { INSURANCE_ADDRESS, InsuranceStakingABI } from "./insurance";

/** The insurance pool's live size and state: a chain read of the deployed InsuranceStaking. */
export function useInsurancePool() {
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
