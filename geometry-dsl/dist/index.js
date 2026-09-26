import { parse } from "./language/parser.js";
import { Evaluator } from "./runtime/evaluator.js";
import { renderSvg } from "./render/svg.js";
export * from "./types.js";
export { tokenize } from "./language/lexer.js";
export { parse } from "./language/parser.js";
export { Evaluator } from "./runtime/evaluator.js";
export { renderSvg } from "./render/svg.js";
export function evaluate(sourceOrProgram) {
    return new Evaluator().evaluate(typeof sourceOrProgram === "string" ? parse(sourceOrProgram) : sourceOrProgram);
}
export function compileToSvg(source, options) {
    return renderSvg(evaluate(source), options);
}
//# sourceMappingURL=index.js.map