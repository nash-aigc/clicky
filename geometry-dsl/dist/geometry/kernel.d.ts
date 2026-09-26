import type { ArcValue, CircleValue, LineValue, PathValue, PointValue } from "../types.ts";
export type Curve = LineValue | CircleValue | ArcValue | PathValue;
export declare function arcDirection(arc: ArcValue): {
    clockwise: boolean;
    amount: number;
};
export declare function intersections(first: Curve, second: Curve): PointValue[];
export declare function projectPoint(point: PointValue, target: Curve): PointValue;
export declare function definingPoints(object: Curve): PointValue[];
export declare function circumcircle(a: PointValue, b: PointValue, c: PointValue): {
    center: PointValue;
    radius: number;
};
export declare const geometryAngle: (a: PointValue, vertex: PointValue, b: PointValue) => number;
//# sourceMappingURL=kernel.d.ts.map