import { type GeometryValue, type RuntimeValue } from "../types.ts";
export declare const namedColors: Record<string, string>;
export declare const styleKeys: Set<string>;
export declare function defaultStyle(type: GeometryValue["type"]): Record<string, unknown>;
export declare function normalizeColor(value: RuntimeValue, key: string): string | null;
export declare function applyStyles(type: GeometryValue["type"], base: Record<string, unknown>, overrides: ReadonlyMap<string, RuntimeValue>): Record<string, unknown>;
//# sourceMappingURL=styles.d.ts.map