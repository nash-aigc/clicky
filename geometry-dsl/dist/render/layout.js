import { GeometryDslError, } from "../types.js";
import { arcDirection, regionBounds, regionSignedDistance, samplePath } from "../geometry/index.js";
const GAP = 4;
const POINT_POSITIONS = [
    "above_right", "above", "right", "below_right",
    "below", "left", "above_left", "below_left",
];
export function estimateTextDimensions(content, size) {
    let units = 0;
    for (const character of [...content]) {
        const code = character.codePointAt(0);
        if (/\s/u.test(character))
            units += 0.34;
        else if (/[\u0300-\u036f\ufe00-\ufe0f]/u.test(character))
            units += 0;
        else if (code <= 0x7f)
            units += /[ilI1.,'`|!]/u.test(character) ? 0.34 : /[MW@#%&]/u.test(character) ? 0.9 : 0.62;
        else
            units += 1;
    }
    return { width: Math.max(size * 0.5, units * size), height: size * 1.2 };
}
function textWidth(content, size) {
    return estimateTextDimensions(content, size).width;
}
function textBox(center, content, size) {
    const { width, height } = estimateTextDimensions(content, size);
    return {
        left: center.x - width / 2,
        right: center.x + width / 2,
        top: center.y - height / 2,
        bottom: center.y + height / 2,
    };
}
function boxCorners(box) {
    const cx = (box.left + box.right) / 2, cy = (box.top + box.bottom) / 2;
    return [
        { x: box.left, y: box.top }, { x: cx, y: box.top }, { x: box.right, y: box.top },
        { x: box.left, y: cy }, { x: cx, y: cy }, { x: box.right, y: cy },
        { x: box.left, y: box.bottom }, { x: cx, y: box.bottom }, { x: box.right, y: box.bottom },
    ];
}
function pointBoxDistance(point, box) {
    const dx = Math.max(box.left - point.x, 0, point.x - box.right);
    const dy = Math.max(box.top - point.y, 0, point.y - box.bottom);
    if (dx > 0 || dy > 0)
        return Math.hypot(dx, dy);
    return -Math.min(point.x - box.left, box.right - point.x, point.y - box.top, box.bottom - point.y);
}
function boxesClearance(a, b) {
    const dx = Math.max(a.left - b.right, b.left - a.right, 0);
    const dy = Math.max(a.top - b.bottom, b.top - a.bottom, 0);
    if (dx > 0 || dy > 0)
        return Math.hypot(dx, dy);
    return -Math.min(a.right - b.left, b.right - a.left, a.bottom - b.top, b.bottom - a.top);
}
function segmentPointDistance(point, a, b) {
    const dx = b.x - a.x, dy = b.y - a.y;
    const lengthSquared = dx * dx + dy * dy;
    if (lengthSquared === 0)
        return Math.hypot(point.x - a.x, point.y - a.y);
    const t = Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared));
    return Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy));
}
function orientation(a, b, c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}
function onSegment(a, b, point) {
    const epsilon = 1e-9;
    return Math.abs(orientation(a, b, point)) <= epsilon
        && point.x >= Math.min(a.x, b.x) - epsilon
        && point.x <= Math.max(a.x, b.x) + epsilon
        && point.y >= Math.min(a.y, b.y) - epsilon
        && point.y <= Math.max(a.y, b.y) + epsilon;
}
function segmentsIntersect(a, b, c, d) {
    const o1 = orientation(a, b, c), o2 = orientation(a, b, d);
    const o3 = orientation(c, d, a), o4 = orientation(c, d, b);
    if ((o1 > 0) !== (o2 > 0) && (o3 > 0) !== (o4 > 0))
        return true;
    return onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b);
}
function segmentBoxClearance(segment, box) {
    if (pointBoxDistance(segment.a, box) <= 0 || pointBoxDistance(segment.b, box) <= 0)
        return -segment.width / 2;
    const corners = [
        { x: box.left, y: box.top },
        { x: box.right, y: box.top },
        { x: box.right, y: box.bottom },
        { x: box.left, y: box.bottom },
    ];
    for (let index = 0; index < corners.length; index++) {
        if (segmentsIntersect(segment.a, segment.b, corners[index], corners[(index + 1) % corners.length])) {
            return -segment.width / 2;
        }
    }
    let best = Math.min(pointBoxDistance(segment.a, box), pointBoxDistance(segment.b, box));
    for (const corner of corners)
        best = Math.min(best, segmentPointDistance(corner, segment.a, segment.b));
    return best - segment.width / 2;
}
function clipLine(line, bounds) {
    const dx = line.b.x - line.a.x, dy = line.b.y - line.a.y;
    let low = line.kind === "infinite" ? -Infinity : 0;
    let high = line.kind === "segment" ? 1 : Infinity;
    const constraints = [
        [-dx, line.a.x - bounds.minX], [dx, bounds.maxX - line.a.x],
        [-dy, line.a.y - bounds.minY], [dy, bounds.maxY - line.a.y],
    ];
    for (const [p, q] of constraints) {
        if (p === 0) {
            if (q < 0)
                return null;
            continue;
        }
        const ratio = q / p;
        if (p < 0)
            low = Math.max(low, ratio);
        else
            high = Math.min(high, ratio);
    }
    if (low > high)
        return null;
    return [
        { x: line.a.x + low * dx, y: line.a.y + low * dy },
        { x: line.a.x + high * dx, y: line.a.y + high * dy },
    ];
}
function polylineSegments(points, width, ownerId, transform, closed = false) {
    const result = [];
    const count = closed ? points.length : points.length - 1;
    for (let index = 0; index < count; index++) {
        const a = points[index], b = points[(index + 1) % points.length];
        result.push({
            a: { x: transform.sx(a.x), y: transform.sy(a.y) },
            b: { x: transform.sx(b.x), y: transform.sy(b.y) },
            width,
            ownerId,
        });
    }
    return result;
}
function arcPoints(arc, count = 64) {
    const direction = arcDirection(arc);
    const start = Math.atan2(arc.start.y - arc.circle.center.y, arc.start.x - arc.circle.center.x);
    const sign = direction.clockwise ? -1 : 1;
    return Array.from({ length: count + 1 }, (_, index) => {
        const angle = start + sign * direction.amount * index / count;
        return {
            x: arc.circle.center.x + Math.cos(angle) * arc.circle.radius,
            y: arc.circle.center.y + Math.sin(angle) * arc.circle.radius,
        };
    });
}
function centeredBox(center, radius) {
    return {
        left: center.x - radius,
        right: center.x + radius,
        top: center.y - radius,
        bottom: center.y + radius,
    };
}
function markBoxes(mark, transform) {
    const radius = mark.style.size * 3 + mark.style.width / 2;
    if (mark.kind === "right") {
        const vertex = mark.operands[1];
        return [centeredBox({ x: transform.sx(vertex.x), y: transform.sy(vertex.y) }, radius)];
    }
    if (mark.kind === "equal" || mark.kind === "parallel") {
        return mark.operands.map(line => centeredBox({
            x: transform.sx((line.a.x + line.b.x) / 2),
            y: transform.sy((line.a.y + line.b.y) / 2),
        }, radius));
    }
    const points = mark.operands;
    return [points[1], points[4]].map(vertex => centeredBox({ x: transform.sx(vertex.x), y: transform.sy(vertex.y) }, radius));
}
function geometryObstacles(objects, transform) {
    const result = [];
    for (const object of objects) {
        if (!object.style?.visible || object.style.opacity <= 0 || object.type === "Text")
            continue;
        if (object.type === "Point") {
            result.push({
                point: { x: transform.sx(object.x), y: transform.sy(object.y) },
                radius: object.style.size / 2,
                ownerId: object.objectId,
            });
        }
        else if (object.type === "Line") {
            const clipped = clipLine(object, transform.bounds);
            if (clipped)
                result.push(...polylineSegments(clipped, object.style.width, object.objectId, transform));
        }
        else if (object.type === "Circle") {
            const points = Array.from({ length: 96 }, (_, index) => {
                const angle = Math.PI * 2 * index / 96;
                return {
                    x: object.center.x + Math.cos(angle) * object.radius,
                    y: object.center.y + Math.sin(angle) * object.radius,
                };
            });
            result.push(...polylineSegments(points, object.style.width, object.objectId, transform, true));
        }
        else if (object.type === "Arc") {
            result.push(...polylineSegments(arcPoints(object), object.style.width, object.objectId, transform));
        }
        else if (object.type === "Path") {
            const points = object.smooth ? samplePath(object, 32).map(sample => sample.point) : object.points;
            result.push(...polylineSegments(points, object.style.width, object.objectId, transform, object.closed));
        }
        else if (object.type === "Mark") {
            for (const box of markBoxes(object, transform))
                result.push({ box, ownerId: object.objectId });
        }
        else if (object.style.fill !== null) {
            result.push({ region: object, ownerId: object.objectId });
        }
    }
    return result;
}
function obstacleClearance(box, obstacle, request, transform) {
    if (obstacle.ownerId === request.objectId || (request.region && obstacle.ownerId === request.region.objectId))
        return Infinity;
    if ("a" in obstacle)
        return segmentBoxClearance(obstacle, box);
    if ("point" in obstacle)
        return pointBoxDistance(obstacle.point, box) - obstacle.radius;
    if ("box" in obstacle)
        return boxesClearance(box, obstacle.box);
    // A long label must not be treated as a circle with its half-diagonal as
    // radius: that makes horizontal text spuriously collide with far-away
    // horizontal Region boundaries. Sample the box deterministically instead,
    // rejecting it when the signed-distance signs show a boundary crossing.
    let minimum = Infinity, negative = false, positive = false;
    for (let row = 0; row < 5; row++) {
        for (let column = 0; column < 5; column++) {
            const point = {
                x: box.left + (box.right - box.left) * column / 4,
                y: box.top + (box.bottom - box.top) * row / 4,
            };
            const distance = regionSignedDistance(obstacle.region, { x: transform.wx(point.x), y: transform.wy(point.y) }) * transform.scale;
            minimum = Math.min(minimum, Math.abs(distance));
            negative ||= distance < 0;
            positive ||= distance > 0;
        }
    }
    return negative && positive ? -minimum : minimum;
}
function viewportClearance(box, transform) {
    return Math.min(box.left, box.top, transform.width - box.right, transform.height - box.bottom);
}
function targetClearance(box, region, transform) {
    // Validate the complete label rectangle against the actual Region, not its
    // rectangular bounds. A triangle (or any concave Path) can contain the
    // candidate center while one side of the text box crosses its boundary.
    let best = Infinity;
    for (let row = 0; row < 9; row++) {
        for (let column = 0; column < 9; column++) {
            const point = {
                x: box.left + (box.right - box.left) * column / 8,
                y: box.top + (box.bottom - box.top) * row / 8,
            };
            const signed = regionSignedDistance(region, { x: transform.wx(point.x), y: transform.wy(point.y) }) * transform.scale;
            best = Math.min(best, signed);
        }
    }
    return best;
}
function placementScore(center, size, request, obstacles, placed, transform) {
    const box = textBox(center, request.content, size);
    let score = viewportClearance(box, transform);
    if (request.region)
        score = Math.min(score, targetClearance(box, request.region, transform));
    for (const obstacle of obstacles)
        score = Math.min(score, obstacleClearance(box, obstacle, request, transform));
    for (const obstacle of placed)
        score = Math.min(score, boxesClearance(box, obstacle.box));
    return score - GAP;
}
function anchorForPoint(point, position, content, size, transform) {
    const origin = { x: transform.sx(point.x), y: transform.sy(point.y) };
    const halfWidth = textWidth(content, size) / 2, halfHeight = size * 0.6;
    const horizontal = point.style.size / 2 + GAP + halfWidth;
    const vertical = point.style.size / 2 + GAP + halfHeight;
    const dx = position.includes("left") ? -horizontal : position.includes("right") ? horizontal : 0;
    const dy = position.includes("above") ? -vertical : position.includes("below") ? vertical : 0;
    return { x: origin.x + dx, y: origin.y + dy };
}
function sizeCandidates(requested) {
    if (requested < 10)
        return [requested];
    const minimum = Math.max(10, requested * 0.6);
    const values = [1, 0.9, 0.8, 0.7, 0.6]
        .map(factor => Math.max(minimum, requested * factor))
        .filter((value, index, all) => index === 0 || Math.abs(value - all[index - 1]) > 1e-6);
    return values;
}
function nudgeCandidates(anchor, radius, requestedSize) {
    const result = [anchor];
    const step = Math.max(3, requestedSize / 4);
    for (let distance = step; distance <= radius + 1e-6; distance += step) {
        for (let index = 0; index < 16; index++) {
            const angle = Math.PI * 2 * index / 16;
            result.push({ x: anchor.x + Math.cos(angle) * distance, y: anchor.y + Math.sin(angle) * distance });
        }
    }
    return result;
}
function explicitPlacement(request, size, obstacles, placed, transform) {
    const anchors = [];
    if (request.fixed)
        anchors.push(request.fixed);
    else if (request.ownerPoint) {
        const positions = request.pointPosition === "auto" ? POINT_POSITIONS : [request.pointPosition];
        for (const position of positions)
            anchors.push(anchorForPoint(request.ownerPoint, position, request.content, size, transform));
    }
    const maximumNudge = request.requestedSize * 2;
    for (const anchor of anchors) {
        if (placementScore(anchor, size, request, obstacles, placed, transform) >= 0)
            return anchor;
    }
    for (const anchor of anchors) {
        const candidates = nudgeCandidates(anchor, maximumNudge, request.requestedSize).slice(1);
        for (const candidate of candidates) {
            if (placementScore(candidate, size, request, obstacles, placed, transform) >= 0)
                return candidate;
        }
    }
    return null;
}
function screenRegionBounds(region, transform) {
    const bounds = regionBounds(region);
    if (!bounds)
        return null;
    return {
        left: Math.min(transform.sx(bounds.minX), transform.sx(bounds.maxX)),
        right: Math.max(transform.sx(bounds.minX), transform.sx(bounds.maxX)),
        top: Math.min(transform.sy(bounds.minY), transform.sy(bounds.maxY)),
        bottom: Math.max(transform.sy(bounds.minY), transform.sy(bounds.maxY)),
    };
}
function regionPlacement(request, size, obstacles, placed, transform) {
    const bounds = screenRegionBounds(request.region, transform);
    if (!bounds || bounds.right <= bounds.left || bounds.bottom <= bounds.top)
        return null;
    let stepX = (bounds.right - bounds.left) / 24;
    let stepY = (bounds.bottom - bounds.top) / 24;
    let candidates = [];
    for (let row = 0; row < 24; row++) {
        for (let column = 0; column < 24; column++) {
            candidates.push({
                x: bounds.left + (column + 0.5) * stepX,
                y: bounds.top + (row + 0.5) * stepY,
            });
        }
    }
    let best = null;
    for (let round = 0; round < 6; round++) {
        const scored = candidates
            .map(point => ({ point, score: placementScore(point, size, request, obstacles, placed, transform) }))
            .sort((a, b) => b.score - a.score || a.point.x - b.point.x || a.point.y - b.point.y);
        if (scored[0] && (!best || scored[0].score > best.score))
            best = scored[0];
        const seeds = scored.slice(0, 8);
        stepX /= 2;
        stepY /= 2;
        candidates = [];
        for (const seed of seeds) {
            for (const dx of [-stepX, 0, stepX]) {
                for (const dy of [-stepY, 0, stepY])
                    candidates.push({ x: seed.point.x + dx, y: seed.point.y + dy });
            }
        }
    }
    return best && best.score >= 0 ? best.point : null;
}
function requests(objects, labelSize, transform) {
    const result = [];
    for (const object of objects) {
        if (!object.style?.visible || object.style.opacity <= 0 || object.objectId === null || object.created === null)
            continue;
        if (object.type === "Point") {
            const content = object.style.label === "auto" ? object.labelName : object.style.label;
            if (content) {
                result.push({
                    objectId: object.objectId,
                    created: object.created,
                    layer: object.style.layer,
                    content,
                    requestedSize: labelSize,
                    ownerPoint: object,
                    pointPosition: object.style.label_pos,
                });
            }
        }
        else if (object.type === "Text") {
            const request = {
                objectId: object.objectId,
                created: object.created,
                layer: object.style.layer,
                content: object.content,
                requestedSize: object.style.size ?? labelSize,
            };
            if (object.position.kind === "fixed") {
                request.fixed = { x: transform.sx(object.position.x), y: transform.sy(object.position.y) };
            }
            else
                request.region = object.position.region;
            result.push(request);
        }
    }
    return result.sort((a, b) => b.layer - a.layer || a.created - b.created);
}
export function layoutLabels(objects, labelSize, transform) {
    const obstacles = geometryObstacles(objects, transform);
    const placed = [];
    const resolved = new Map();
    for (const request of requests(objects, labelSize, transform)) {
        let result = null;
        for (const size of sizeCandidates(request.requestedSize)) {
            const point = request.region
                ? regionPlacement(request, size, obstacles, placed, transform)
                : explicitPlacement(request, size, obstacles, placed, transform);
            if (point) {
                result = { point, size };
                break;
            }
        }
        if (!result) {
            throw new GeometryDslError("E_LAYOUT", `无法为文本 "${request.content}" 找到可用位置；请减小 size、调整坐标或扩大区域`);
        }
        const label = {
            objectId: request.objectId,
            content: request.content,
            x: result.point.x,
            y: result.point.y,
            size: result.size,
        };
        resolved.set(request.objectId, label);
        placed.push({ box: textBox(result.point, request.content, result.size), ownerId: request.objectId });
    }
    return resolved;
}
//# sourceMappingURL=layout.js.map