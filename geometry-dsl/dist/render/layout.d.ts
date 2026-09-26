import { type GeometryValue } from "../types.ts";
import { type RegionBounds } from "../geometry/index.ts";
type WorldBounds = RegionBounds;
export type ResolvedLabel = {
    objectId: number;
    content: string;
    x: number;
    y: number;
    size: number;
};
export type LayoutTransform = {
    sx: (x: number) => number;
    sy: (y: number) => number;
    wx: (x: number) => number;
    wy: (y: number) => number;
    scale: number;
    bounds: WorldBounds;
    width: number;
    height: number;
};
export declare function estimateTextDimensions(content: string, size: number): {
    width: number;
    height: number;
};
export declare function layoutLabels(objects: readonly GeometryValue[], labelSize: number, transform: LayoutTransform): ReadonlyMap<number, ResolvedLabel>;
export {};
//# sourceMappingURL=layout.d.ts.map