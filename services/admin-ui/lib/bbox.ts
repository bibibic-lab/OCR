/**
 * bbox 좌표 유틸리티.
 * OcrItem.bbox = [[x,y],[x,y],[x,y],[x,y]] (원본 이미지 픽셀 좌표)
 */

/**
 * bbox 4-point 배열 → SVG polygon의 points 문자열로 변환.
 * 예: "10,20 30,20 30,40 10,40"
 */
export function bboxToPointsStr(bbox: number[][]): string {
  return bbox.map(([x, y]) => `${x},${y}`).join(" ");
}

/**
 * confidence 값에 따라 stroke 색상 반환.
 * - >= 0.9  : green-500  (#10b981)
 * - >= 0.5  : yellow-500 (#eab308)
 * - < 0.5   : red-500    (#ef4444)
 */
export function confidenceColor(conf: number): string {
  if (conf >= 0.9) return "#10b981"; // green-500
  if (conf >= 0.5) return "#eab308"; // yellow-500
  return "#ef4444"; // red-500
}

/**
 * bbox의 중심점(픽셀 좌표) 반환.
 */
export function bboxCenter(bbox: number[][]): { x: number; y: number } {
  const xs = bbox.map((p) => p[0]);
  const ys = bbox.map((p) => p[1]);
  return {
    x: (Math.min(...xs) + Math.max(...xs)) / 2,
    y: (Math.min(...ys) + Math.max(...ys)) / 2,
  };
}

/**
 * bbox의 bounding rect (min-x, min-y, width, height) 반환.
 */
export function bboxRect(bbox: number[][]): {
  x: number;
  y: number;
  w: number;
  h: number;
} {
  const xs = bbox.map((p) => p[0]);
  const ys = bbox.map((p) => p[1]);
  const minX = Math.min(...xs);
  const minY = Math.min(...ys);
  return { x: minX, y: minY, w: Math.max(...xs) - minX, h: Math.max(...ys) - minY };
}
