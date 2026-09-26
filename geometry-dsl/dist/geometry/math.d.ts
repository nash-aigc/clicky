import type { PointValue } from "../types.ts";
export type Vec = Readonly<{
    x: number;
    y: number;
}>;
export declare const TAU: number;
export declare const deg: (degrees: number) => number;
export declare const degrees: (radians: number) => number;
export declare const add: (a: Vec, b: Vec) => Vec;
export declare const sub: (a: Vec, b: Vec) => Vec;
export declare const mul: (a: Vec, scalar: number) => Vec;
export declare const dot: (a: Vec, b: Vec) => number;
export declare const cross: (a: Vec, b: Vec) => number;
export declare const length: (a: Vec) => number;
export declare const distance: (a: Vec, b: Vec) => number;
export declare const normalize: (a: Vec) => Vec;
export declare const rotate: (a: Vec, radians: number) => Vec;
export declare const lerp: (a: Vec, b: Vec, t: number) => Vec;
export declare const clamp: (n: number, min: number, max: number) => number;
export declare const normalizeAngle: (angle: number) => number;
export declare const ccwDelta: (start: number, end: number) => number;
export declare const cwDelta: (start: number, end: number) => number;
export declare const pointAngle: (center: Vec, point: Vec) => number;
export declare function epsilon(points: readonly Vec[], lengths?: readonly number[]): number;
export declare function barePoint(x: number, y: number): PointValue;
export declare const angleBetween: (a: Vec, b: Vec) => number;
export declare function assertFinite(...numbers: number[]): void;
//# sourceMappingURL=math.d.ts.map