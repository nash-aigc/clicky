import type { RegionValue } from "../types.ts";
import { type Vec } from "./math.ts";
export type RegionBounds = {
    minX: number;
    minY: number;
    maxX: number;
    maxY: number;
};
export declare function regionBounds(region: RegionValue): RegionBounds | null;
export declare function regionSignedDistance(region: RegionValue, point: Vec): number;
export declare function regionContains(region: RegionValue, point: Vec, tolerance?: number): boolean;
//# sourceMappingURL=regions.d.ts.map