import type { PathValue, PointValue } from "../types.ts";
import { type Vec } from "./math.ts";
export declare function pathSegmentCount(path: PathValue): number;
/** The normative centripetal Catmull–Rom expression from section 10.4. */
export declare function pathPoint(path: PathValue, segment: number, u: number): Vec;
export type PathSample = {
    point: Vec;
    progress: number;
    segment: number;
    u: number;
};
export declare function samplePath(path: PathValue, smoothSteps?: number): PathSample[];
export declare function pathSvgData(path: PathValue, sx: (x: number) => number, sy: (y: number) => number): string;
export declare function pointFromVec(point: Vec): PointValue;
//# sourceMappingURL=curves.d.ts.map