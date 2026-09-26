import type { Program, RenderOptions, Scene } from "./types.ts";
export * from "./types.ts";
export { tokenize } from "./language/lexer.ts";
export { parse } from "./language/parser.ts";
export { Evaluator } from "./runtime/evaluator.ts";
export { renderSvg } from "./render/svg.ts";
export declare function evaluate(sourceOrProgram: string | Program): Scene;
export declare function compileToSvg(source: string, options?: RenderOptions): string;
//# sourceMappingURL=index.d.ts.map