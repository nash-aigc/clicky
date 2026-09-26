import { compileToSvg } from "./index.js";
export const geometryMarkdownLanguages = ["geometry", "geometry-dsl", "geom"];
const numericOptions = new Set(["width", "height", "padding", "precision", "labelSize"]);
const optionAliases = {
    "label-size": "labelSize",
    label_size: "labelSize",
};
function escapeHtml(value) {
    return value.replace(/[&<>"']/g, character => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    })[character]);
}
function firstInfoWord(info) {
    return info?.trim().split(/\s+/, 1)[0]?.toLowerCase() ?? "";
}
function parseFenceOptions(info) {
    const words = info?.trim().split(/\s+/).slice(1) ?? [];
    const result = {};
    for (const word of words) {
        const separator = word.indexOf("=");
        if (separator <= 0)
            continue;
        const rawKey = word.slice(0, separator);
        const key = optionAliases[rawKey] ?? rawKey;
        const rawValue = word.slice(separator + 1);
        if (numericOptions.has(key)) {
            const value = Number(rawValue);
            if (Number.isFinite(value) && value > 0)
                result[key] = value;
        }
        else if (key === "background") {
            result.background = rawValue === "none" ? null : rawValue;
        }
    }
    return result;
}
function languageSet(options) {
    return new Set((options.languages ?? geometryMarkdownLanguages).map(language => language.toLowerCase()));
}
export function renderGeometryMarkdownBlock(source, options = {}) {
    try {
        const renderOptions = { ...options };
        delete renderOptions.languages;
        delete renderOptions.onError;
        return `<div class="geometry-dsl-diagram" data-geometry-dsl="true">${compileToSvg(source, renderOptions)}</div>`;
    }
    catch (error) {
        if (options.onError === "throw")
            throw error;
        const message = error instanceof Error ? error.message : String(error);
        return `<div class="geometry-dsl-error" data-geometry-dsl-error="true"><strong>Geometry DSL</strong><pre><code>${escapeHtml(message)}</code></pre></div>`;
    }
}
export function geometryMarkdownPlugin(md, options = {}) {
    const rules = md.renderer.rules;
    const originalFence = rules.fence;
    const languages = languageSet(options);
    rules.fence = (tokens, index, renderOptions, env, self) => {
        const token = tokens[index];
        if (!languages.has(firstInfoWord(token?.info))) {
            if (originalFence)
                return originalFence(tokens, index, renderOptions, env, self);
            const content = token?.content ?? "";
            return `<pre><code>${escapeHtml(content)}</code></pre>`;
        }
        return renderGeometryMarkdownBlock(token?.content ?? "", {
            ...options,
            ...parseFenceOptions(token?.info),
        });
    };
    return md;
}
//# sourceMappingURL=markdown.js.map