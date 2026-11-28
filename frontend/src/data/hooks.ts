import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";

import { eventLog } from "../lib/events";
import { readLasna, readState, readUser } from "./state";

export const useZenith = () =>
  useQuery({ queryKey: ["zenith"], queryFn: readState, refetchInterval: 4000, staleTime: 2000 });

export const useLasna = () =>
  useQuery({ queryKey: ["lasna"], queryFn: readLasna, refetchInterval: 8000, staleTime: 4000 });

export const useEvents = () =>
  useQuery({ queryKey: ["events"], queryFn: () => eventLog.update(), refetchInterval: 6000, staleTime: 3000 });

export function useUser(user: Address | undefined, sleeveCount: number | undefined) {
  return useQuery({
    queryKey: ["user", user, sleeveCount],
    queryFn: () => readUser(user!, sleeveCount!),
    enabled: user !== undefined && sleeveCount !== undefined,
    refetchInterval: 6000,
  });
}
