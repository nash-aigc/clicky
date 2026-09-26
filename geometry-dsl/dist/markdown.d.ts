import type { RenderOptions } from "./types.ts";
export declare const geometryMarkdownLanguages: readonly ["geometry", "geometry-dsl", "geom"];
export type GeometryMarkdownLanguage = (typeof geometryMarkdownLanguages)[number];
export type MarkdownItToken = {
    info?: string;
    content?: string;
};
export type MarkdownItRendererRule = (tokens: readonly MarkdownItToken[], index: number, options: unknown, env: unknown, self: unknown) => string;
export type MarkdownItLike = {
    renderer: {
        rules: Record<string, unknown>;
    };
};
export type GeometryMarkdownOptions = RenderOptions & {
    languages?: readonly string[];
    onError?: "render" | "throw";
};
export declare function renderGeometryMarkdownBlock(source: string, options?: GeometryMarkdownOptions): string;
export declare function geometryMarkdownPlugin<T extends MarkdownItLike>(md: T, options?: GeometryMarkdownOptions): T;
//# sourceMappingURL=markdown.d.ts.map