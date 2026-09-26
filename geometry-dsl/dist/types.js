export class GeometryDslError extends Error {
    code;
    location;
    constructor(code, message, location) {
        super(`${location ? `${location.line}:${location.column}: ` : ""}${message}`);
        this.name = "GeometryDslError";
        this.code = code;
        this.location = location;
    }
}
//# sourceMappingURL=types.js.map